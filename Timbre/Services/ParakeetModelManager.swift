import FluidAudio
import Foundation

/// Owns Parakeet v2 download/verification and the optional retained ASR actor.
///
/// Disk readiness remains `installed` while a cached model is loaded into memory.
/// The private load flight is the source of truth for in-flight memory work.
@MainActor
@Observable
final class ParakeetModelManager: ParakeetModelManaging {
    private static let modelVersion: AsrModelVersion = .v2
    /// v2 download loops one ModelHub pass per Core ML package (preprocessor/encoder/decoder/joint).
    private static let expectedDownloadPasses = 4
    private static let downloadStageWeight = 0.85
    private static let userFacingFailure =
        "Something went wrong while getting Timbre ready."

    private(set) var state: ModelPreparationState = .checking
    private(set) var progress: ModelPreparationProgress = .idle

    private let loader: any ParakeetModelLoading
    private var asrManager: (any ParakeetASRManaging)?
    private var installTask: Task<Void, Error>?
    private var loadFlight: LoadFlight?
    private var nextLoadFlightID = 0

    private var progressStartedAt: Date?
    private var downloadPassIndex = 0
    private var lastRawFraction = 0.0
    private var peakOverallFraction = 0.0
    private var progressStage: ProgressStage = .download

    private enum ProgressStage {
        case download
        case load
    }

    private enum LoadCapability: Equatable {
        case installedOnly
        case downloadIfMissing

        var logName: String {
            switch self {
            case .installedOnly: return "installed-only"
            case .downloadIfMissing: return "download-capable"
            }
        }
    }

    private struct LoadFlight {
        let id: Int
        let capability: LoadCapability
        let task: Task<any ParakeetASRManaging, Error>
    }

    /// Identifies which operation failed so one canonical owner can classify the result.
    private enum LoadAttemptError: Error {
        case cached(Error)
        case download(Error)
        case downloadedCache(Error)
    }

    private enum LoadFailureResolution {
        case recovered(any ParakeetASRManaging)
        case failed(Error)
    }

    init(loader: (any ParakeetModelLoading)? = nil) {
        self.loader = loader ?? FluidAudioParakeetModelLoader(version: Self.modelVersion)
        refreshAvailability()
    }

    func refreshAvailability() {
        switch state {
        case .downloading, .loading, .loaded:
            return
        case .checking, .notInstalled, .installed, .failed:
            break
        }

        let exists = loader.cacheExists()
        state = exists ? .installed : .notInstalled
        progress = .idle
        TimbreLog.line("Timbre model: refresh cacheExists=\(exists) state=\(state)")
    }

    func ensureInstalled() async throws {
        if state.isLoaded {
            unload()
            return
        }
        if state.isInstalled, asrManager == nil, installTask == nil, loadFlight == nil {
            return
        }

        if let loadFlight {
            TimbreLog.line("Timbre model: ensureInstalled joining in-flight load, then releasing.")
            _ = try? await loadFlight.task.value
            if asrManager != nil {
                unload()
                return
            }
        }

        if let installTask {
            TimbreLog.line("Timbre model: awaiting in-flight ensureInstalled.")
            try await installTask.value
            return
        }

        let task = Task<Void, Error> { @MainActor [self] in
            try await installAndVerify()
        }
        installTask = task

        do {
            try await task.value
            installTask = nil
        } catch {
            installTask = nil
            throw TranscriptionError.recognitionFailed(Self.userFacingFailure)
        }
    }

    /// Single-flight load that downloads only when no usable cache remains.
    func ensureLoaded() async throws -> any ParakeetASRManaging {
        if let asrManager {
            state = .loaded
            TimbreLog.line("Timbre model: reusing loaded ASR manager.")
            return asrManager
        }

        if let installTask {
            TimbreLog.line("Timbre model: waiting for install before ensureLoaded.")
            do {
                try await installTask.value
            } catch {
                TimbreLog.line(
                    "Timbre model: install failed before load — \(error.localizedDescription)"
                )
            }
        }

        var hasAttemptedRepair = false
        while true {
            if let asrManager {
                state = .loaded
                return asrManager
            }

            let flight: LoadFlight
            if let current = loadFlight {
                TimbreLog.line(
                    "Timbre model: joining \(current.capability.logName) load flight."
                )
                flight = current
            } else {
                flight = startLoadFlight(capability: .downloadIfMissing)
            }

            do {
                return try await flight.task.value
            } catch ParakeetModelError.modelNotInstalled where !hasAttemptedRepair {
                // Either a joined prewarm flight or ensureLoaded's own flight can discover
                // and invalidate an existing corrupt cache. Allow exactly one clean-download
                // flight after that transition; a second modelNotInstalled error is terminal.
                hasAttemptedRepair = true
                TimbreLog.line("Timbre model: retrying with a clean download after invalid cache.")
            } catch {
                throw error
            }
        }
    }

    func loadInstalledAndRetain() async throws {
        if asrManager != nil {
            state = .loaded
            TimbreLog.line("Timbre model: prewarm skipped; ASR manager already loaded.")
            return
        }

        if let loadFlight {
            TimbreLog.line("Timbre model: prewarm joining in-flight load.")
            _ = try await loadFlight.task.value
            return
        }

        if let installTask {
            TimbreLog.line("Timbre model: prewarm waiting for in-flight install.")
            try? await installTask.value
        }

        // The install wait is an actor suspension; Start may have loaded the manager
        // or created a flight while prewarm was waiting.
        if asrManager != nil {
            state = .loaded
            TimbreLog.line("Timbre model: prewarm found manager loaded during install wait.")
            return
        }

        if let loadFlight {
            TimbreLog.line("Timbre model: prewarm joining load started during install wait.")
            _ = try await loadFlight.task.value
            return
        }

        guard loader.cacheExists() else {
            state = .notInstalled
            progress = .idle
            TimbreLog.line("Timbre model: prewarm skipped; installed cache missing.")
            throw ParakeetModelError.modelNotInstalled
        }

        let flight = startLoadFlight(capability: .installedOnly)
        _ = try await flight.task.value
    }

    func unload() {
        asrManager = nil
        switch state {
        case .loaded, .loading:
            let exists = loader.cacheExists()
            state = exists ? .installed : .notInstalled
            progress = .idle
            TimbreLog.line("Timbre model: unloaded → \(state)")
        case .checking, .notInstalled, .downloading, .installed, .failed:
            break
        }
    }

    // MARK: - Install

    private func installAndVerify() async throws {
        do {
            beginProgressTracking()

            if loader.cacheExists() {
                state = .loading
                progressStage = .load
                TimbreLog.line("Timbre model: verifying existing install.")
                do {
                    _ = try await loader.loadCached(progressHandler: makeProgressHandler())
                    finishInstallation()
                    return
                } catch {
                    // ensureInstalled proves disk readiness only; unlike a retained load
                    // flight, it deliberately releases the manager created by validation.
                    if await loader.loadValidatedCache() != nil {
                        TimbreLog.line(
                            "Timbre model: existing install verified on retry after a transient load failure."
                        )
                        finishInstallation()
                        return
                    }
                    try invalidateCache(after: error)
                    TimbreLog.line("Timbre model: invalid install removed; downloading replacement.")
                }
            }

            state = .downloading
            progressStage = .download
            try await loader.download(progressHandler: makeProgressHandler())

            state = .loading
            progressStage = .load
            resetProgressForLoadStage()
            do {
                _ = try await loader.loadCached(progressHandler: makeProgressHandler())
            } catch {
                // Keep ensureInstalled's disk-only memory contract on validation retry.
                if await validatedCacheManager() != nil {
                    TimbreLog.line(
                        "Timbre model: downloaded install verified on retry after a transient load failure."
                    )
                    finishInstallation()
                    return
                }
                try? loader.invalidateCache()
                throw error
            }

            finishInstallation()
        } catch {
            asrManager = nil
            if state != .notInstalled {
                state = .failed(message: Self.userFacingFailure)
            }
            progress = .idle
            TimbreLog.line(
                "Timbre model: ensureInstalled failed — \(error.localizedDescription)"
            )
            throw error
        }
    }

    private func finishInstallation() {
        asrManager = nil
        state = .installed
        progress = ModelPreparationProgress(
            fraction: 1,
            detail: nil,
            estimatedSecondsRemaining: nil
        )
        TimbreLog.line("Timbre model: installed (verification manager released).")
        progress = .idle
    }

    // MARK: - Retained load flight

    private func startLoadFlight(capability: LoadCapability) -> LoadFlight {
        precondition(loadFlight == nil)
        nextLoadFlightID += 1
        let id = nextLoadFlightID

        let task = Task<any ParakeetASRManaging, Error> { @MainActor [self] in
            do {
                let manager = try await performRetainedLoad(capability: capability)
                completeLoadFlight(id: id, manager: manager)
                return manager
            } catch {
                switch await normalizeLoadFailure(error) {
                case .recovered(let manager):
                    completeLoadFlight(id: id, manager: manager)
                    return manager
                case .failed(let normalized):
                    completeFailedLoadFlight(id: id)
                    throw normalized
                }
            }
        }

        let flight = LoadFlight(id: id, capability: capability, task: task)
        loadFlight = flight
        return flight
    }

    private func performRetainedLoad(
        capability: LoadCapability
    ) async throws -> any ParakeetASRManaging {
        beginProgressTracking()

        if loader.cacheExists() {
            // Loading into memory does not make an installed cache temporarily unready.
            state = .installed
            progressStage = .load
            TimbreLog.line("Timbre model: loading installed cache into memory.")
            do {
                return try await loader.loadCached(progressHandler: makeProgressHandler())
            } catch {
                throw LoadAttemptError.cached(error)
            }
        }

        guard capability == .downloadIfMissing else {
            throw ParakeetModelError.modelNotInstalled
        }

        state = .downloading
        progressStage = .download
        TimbreLog.line("Timbre model: cache missing; downloading before load.")
        do {
            try await loader.download(progressHandler: makeProgressHandler())
        } catch {
            throw LoadAttemptError.download(error)
        }

        state = .loading
        progressStage = .load
        resetProgressForLoadStage()
        do {
            return try await loader.loadCached(progressHandler: makeProgressHandler())
        } catch {
            throw LoadAttemptError.downloadedCache(error)
        }
    }

    private func completeLoadFlight(
        id: Int,
        manager: any ParakeetASRManaging
    ) {
        guard loadFlight?.id == id else { return }
        asrManager = manager
        state = .loaded
        progress = .idle
        loadFlight = nil
        TimbreLog.line("Timbre model: loaded ASR manager retained.")
    }

    private func completeFailedLoadFlight(id: Int) {
        guard loadFlight?.id == id else { return }
        asrManager = nil
        progress = .idle
        loadFlight = nil
    }

    private func normalizeLoadFailure(_ error: Error) async -> LoadFailureResolution {
        if let modelError = error as? ParakeetModelError {
            switch modelError {
            case .modelNotInstalled:
                state = .notInstalled
            case .transientLoadFailed:
                state = .installed
            }
            return .failed(modelError)
        }

        switch error {
        case LoadAttemptError.cached(let underlying):
            return await normalizeCachedLoadFailure(underlying)

        case LoadAttemptError.download(let underlying):
            return .failed(downloadFailure(underlying))

        case LoadAttemptError.downloadedCache(let underlying):
            if let manager = await validatedCacheManager() {
                TimbreLog.line(
                    "Timbre model: recovered transient load failure after download with validated manager — \(underlying.localizedDescription)"
                )
                return .recovered(manager)
            }
            try? loader.invalidateCache()
            return .failed(downloadFailure(underlying))

        default:
            return await normalizeCachedLoadFailure(error)
        }
    }

    private func normalizeCachedLoadFailure(_ error: Error) async -> LoadFailureResolution {
        guard loader.cacheExists() else {
            state = .notInstalled
            TimbreLog.line("Timbre model: cached load failed because files disappeared.")
            return .failed(ParakeetModelError.modelNotInstalled)
        }

        if let manager = await loader.loadValidatedCache() {
            TimbreLog.line(
                "Timbre model: recovered transient load failure with validated manager — \(error.localizedDescription)"
            )
            return .recovered(manager)
        }

        do {
            try invalidateCache(after: error)
            return .failed(ParakeetModelError.modelNotInstalled)
        } catch {
            state = .failed(message: Self.userFacingFailure)
            return .failed(
                TranscriptionError.recognitionFailed(
                    "Parakeet cache could not be repaired: \(error.localizedDescription)"
                )
            )
        }
    }

    private func validatedCacheManager() async -> (any ParakeetASRManaging)? {
        guard loader.cacheExists() else { return nil }
        return await loader.loadValidatedCache()
    }

    private func invalidateCache(after loadError: Error) throws {
        do {
            try loader.invalidateCache()
            state = .notInstalled
            TimbreLog.line(
                "Timbre model: invalid cache removed — \(loadError.localizedDescription)"
            )
        } catch {
            TimbreLog.line(
                "Timbre model: failed to remove invalid cache — \(error.localizedDescription)"
            )
            throw error
        }
    }

    private func downloadFailure(_ error: Error) -> Error {
        state = .failed(message: Self.userFacingFailure)
        TimbreLog.line("Timbre model: download/load failed — \(error.localizedDescription)")
        return TranscriptionError.recognitionFailed(
            "Parakeet model preparation failed: \(error.localizedDescription)"
        )
    }

    // MARK: - Progress

    private func makeProgressHandler() -> ProgressHandler {
        { [weak self] downloadProgress in
            Task { @MainActor in
                self?.applyFluidAudioProgress(downloadProgress)
            }
        }
    }

    private func resetProgressForLoadStage() {
        downloadPassIndex = 0
        lastRawFraction = 0
    }

    private func beginProgressTracking() {
        progressStartedAt = Date()
        downloadPassIndex = 0
        lastRawFraction = 0
        peakOverallFraction = 0
        progress = ModelPreparationProgress(
            fraction: 0,
            detail: "Starting…",
            estimatedSecondsRemaining: nil
        )
    }

    private func applyFluidAudioProgress(_ downloadProgress: DownloadProgress) {
        let raw = min(max(downloadProgress.fractionCompleted, 0), 1)

        // Each ModelHub pass reports its own 0...1; detect resets to advance pass index.
        if raw + 0.08 < lastRawFraction {
            downloadPassIndex = min(downloadPassIndex + 1, Self.expectedDownloadPasses - 1)
        }
        lastRawFraction = raw

        let overall: Double
        switch progressStage {
        case .download:
            let passCount = Double(Self.expectedDownloadPasses)
            let within = (Double(downloadPassIndex) + raw) / passCount
            overall = Self.downloadStageWeight * min(within, 1)
        case .load:
            overall = Self.downloadStageWeight + (1 - Self.downloadStageWeight) * raw
        }

        peakOverallFraction = max(peakOverallFraction, overall)

        let detail = userFacingDetail(for: downloadProgress.phase)
        let eta = estimatedRemaining(overallFraction: peakOverallFraction)

        progress = ModelPreparationProgress(
            fraction: peakOverallFraction,
            detail: detail,
            estimatedSecondsRemaining: eta
        )
    }

    private func userFacingDetail(for phase: DownloadPhase) -> String {
        switch phase {
        case .listing:
            return "Checking what’s needed…"
        case .downloading(let completed, let total):
            if total > 0 {
                return "Downloading… (\(min(completed + 1, total)) of \(total))"
            }
            return "Downloading…"
        case .compiling:
            return "Preparing…"
        }
    }

    private func estimatedRemaining(overallFraction: Double) -> TimeInterval? {
        guard let started = progressStartedAt else { return nil }
        guard overallFraction >= 0.03 else { return nil }
        let elapsed = Date().timeIntervalSince(started)
        guard elapsed >= 2 else { return nil }
        let remaining = elapsed * (1 - overallFraction) / overallFraction
        guard remaining.isFinite, remaining > 0 else { return nil }
        return remaining
    }
}
