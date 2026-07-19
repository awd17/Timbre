import FluidAudio
import Foundation

/// Owns Parakeet v2 download/verify and optional in-memory `AsrManager`.
///
/// - `ensureInstalled()` downloads, verifies load, then releases memory (state → `installed`).
/// - `ensureLoaded()` loads (and downloads if needed) and retains `AsrManager` (state → `loaded`).
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

    private var asrManager: AsrManager?
    private var installTask: Task<Void, Error>?
    private var loadTask: Task<AsrManager, Error>?

    private var progressStartedAt: Date?
    private var downloadPassIndex = 0
    private var lastRawFraction = 0.0
    private var peakOverallFraction = 0.0
    private var progressStage: ProgressStage = .download

    private enum ProgressStage {
        case download
        case load
    }

    init() {
        refreshAvailability()
    }

    func refreshAvailability() {
        switch state {
        case .downloading, .loading, .loaded:
            return
        case .checking, .notInstalled, .installed, .failed:
            break
        }

        let cacheDirectory = AsrModels.defaultCacheDirectory(for: Self.modelVersion)
        let exists = AsrModels.modelsExist(at: cacheDirectory, version: Self.modelVersion)
        state = exists ? .installed : .notInstalled
        progress = .idle
        TimbreLog.line(
            "Timbre model: refresh cache=\(cacheDirectory.path) exists=\(exists) state=\(state)"
        )
    }

    func ensureInstalled() async throws {
        if case .loaded = state {
            unload()
            return
        }
        if case .installed = state, asrManager == nil, installTask == nil, loadTask == nil {
            return
        }

        if let loadTask {
            TimbreLog.line("Timbre model: ensureInstalled joining in-flight load, then releasing.")
            do {
                _ = try await loadTask.value
                self.loadTask = nil
            } catch {
                self.loadTask = nil
            }
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

        let cacheDirectory = AsrModels.defaultCacheDirectory(for: Self.modelVersion)
        let alreadyPresent = AsrModels.modelsExist(at: cacheDirectory, version: Self.modelVersion)

        let task = Task<Void, Error> { @MainActor in
            do {
                self.beginProgressTracking()
                if alreadyPresent {
                    self.state = .loading
                    self.progressStage = .load
                    TimbreLog.line("Timbre model: verifying existing install.")
                    _ = try await self.downloadOrLoadModels(forceDownloadPhase: false)
                } else {
                    self.state = .downloading
                    self.progressStage = .download
                    TimbreLog.line("Timbre model: downloading and verifying.")
                    _ = try await self.downloadOrLoadModels(forceDownloadPhase: true)
                }
                self.asrManager = nil
                self.state = .installed
                self.progress = ModelPreparationProgress(
                    fraction: 1,
                    detail: nil,
                    estimatedSecondsRemaining: nil
                )
                TimbreLog.line("Timbre model: installed (manager released).")
                self.progress = .idle
            } catch {
                self.asrManager = nil
                self.state = .failed(message: Self.userFacingFailure)
                self.progress = .idle
                TimbreLog.line(
                    "Timbre model: ensureInstalled failed — \(error.localizedDescription)"
                )
                throw error
            }
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

    /// Single-flight load (download if missing). Retains `AsrManager` for dictation.
    func ensureLoaded() async throws -> AsrManager {
        if let asrManager {
            TimbreLog.line("Timbre model: reusing loaded AsrManager.")
            state = .loaded
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
            if let asrManager {
                state = .loaded
                return asrManager
            }
        }

        if let loadTask {
            TimbreLog.line("Timbre model: awaiting in-flight ensureLoaded.")
            do {
                let manager = try await loadTask.value
                asrManager = manager
                state = .loaded
                return manager
            } catch {
                self.loadTask = nil
                TimbreLog.line(
                    "Timbre model: in-flight ensureLoaded failed, will retry — \(error.localizedDescription)"
                )
            }
        }

        if let asrManager {
            state = .loaded
            return asrManager
        }

        let task = Task<AsrManager, Error> { @MainActor in
            self.beginProgressTracking()
            let cacheDirectory = AsrModels.defaultCacheDirectory(for: Self.modelVersion)
            let exists = AsrModels.modelsExist(at: cacheDirectory, version: Self.modelVersion)
            self.state = exists ? .loading : .downloading
            self.progressStage = exists ? .load : .download
            let models = try await self.downloadOrLoadModels(forceDownloadPhase: !exists)
            let manager = AsrManager(config: .default, models: models)
            self.asrManager = manager
            self.state = .loaded
            self.progress = .idle
            TimbreLog.line("Timbre model: loaded AsrManager retained.")
            return manager
        }
        loadTask = task

        do {
            let manager = try await task.value
            loadTask = nil
            return manager
        } catch {
            loadTask = nil
            asrManager = nil
            state = .failed(message: Self.userFacingFailure)
            progress = .idle
            TimbreLog.line(
                "Timbre model: ensureLoaded failed — \(error.localizedDescription)"
            )
            throw TranscriptionError.recognitionFailed(
                "Parakeet model preparation failed: \(error.localizedDescription)"
            )
        }
    }

    func unload() {
        asrManager = nil
        switch state {
        case .loaded, .loading:
            let cacheDirectory = AsrModels.defaultCacheDirectory(for: Self.modelVersion)
            let exists = AsrModels.modelsExist(at: cacheDirectory, version: Self.modelVersion)
            state = exists ? .installed : .notInstalled
            progress = .idle
            TimbreLog.line("Timbre model: unloaded → \(state)")
        case .checking, .notInstalled, .downloading, .installed, .failed:
            break
        }
    }

    // MARK: - FluidAudio

    private func downloadOrLoadModels(forceDownloadPhase: Bool) async throws -> AsrModels {
#if !arch(arm64)
        throw TranscriptionError.recognitionFailed("Parakeet models require Apple Silicon.")
#else
        let handler: ProgressHandler = { [weak self] downloadProgress in
            Task { @MainActor in
                self?.applyFluidAudioProgress(downloadProgress)
            }
        }

        if forceDownloadPhase {
            progressStage = .download
            state = .downloading
            let directory = try await AsrModels.download(
                version: Self.modelVersion,
                progressHandler: handler
            )
            progressStage = .load
            state = .loading
            downloadPassIndex = 0
            lastRawFraction = 0
            return try await AsrModels.load(
                from: directory,
                version: Self.modelVersion,
                progressHandler: handler
            )
        }

        progressStage = .load
        state = .loading
        return try await AsrModels.downloadAndLoad(
            version: Self.modelVersion,
            progressHandler: handler
        )
#endif
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
            state = .downloading
        case .load:
            overall = Self.downloadStageWeight + (1 - Self.downloadStageWeight) * raw
            state = .loading
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
