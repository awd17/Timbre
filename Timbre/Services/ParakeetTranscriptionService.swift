#if DEBUG
import FluidAudio
import Foundation

/// DEBUG-only Parakeet v2 batch transcription via FluidAudio.
@MainActor
final class ParakeetTranscriptionService: TranscriptionServicing, TerminationHandling {
    private static let modelVersion: AsrModelVersion = .v2
    private static let targetSampleRate = 16_000.0

    private let audioSource: any ParakeetAudioSource
    private var session: TranscriptionSession?
    private var asrManager: AsrManager?
    private var preparationTask: Task<AsrManager, Error>?
    private var inferenceTask: Task<ASRResult, Error>?

    init(audioSource: any ParakeetAudioSource) {
        self.audioSource = audioSource
    }

    convenience init(fixtureURL: URL) {
        self.init(audioSource: ParakeetFixtureAudioSource(url: fixtureURL))
    }

    static func defaultFixtureURL() -> URL? {
        Bundle.main.url(forResource: "parakeet-smoke-test", withExtension: "wav")
    }

    func prepare() async throws {
#if !arch(arm64)
        throw TranscriptionError.recognitionFailed("Parakeet models require Apple Silicon.")
#endif
        try await audioSource.prepareAccess()
        _ = try await ensureAsrManager()
    }

    func start(onPartialResult: @escaping @MainActor (String) -> Void) async throws {
        if session != nil {
            throw TranscriptionError.alreadyRunning
        }

        tearDownSession(invalidateSession: true)
        session = TranscriptionSession(onPartialResult: onPartialResult)

        do {
            try audioSource.begin()
        } catch {
            tearDownSession(invalidateSession: true)
            throw error
        }
    }

    func stop() async throws -> String {
        guard let activeSession = session, !activeSession.isInvalidated else {
            throw TranscriptionError.notRunning
        }
        let sessionID = activeSession.id

        do {
            let samples = try audioSource.finish()
            let text = try await transcribe(samples: samples, sessionID: sessionID)
            tearDownSession(invalidateSession: true)
            return text
        } catch {
            tearDownSession(invalidateSession: true)
            throw error
        }
    }

    func cancel() async {
        // Do not cancel shared model preparation.
        inferenceTask?.cancel()
        inferenceTask = nil
        tearDownSession(invalidateSession: true)
        TimbreLog.line("Timbre Parakeet: session cancelled (shared model preparation left running).")
    }

    func shutdownForTermination() {
        TimbreLog.line("Timbre Parakeet: synchronous termination shutdown.")
        inferenceTask?.cancel()
        inferenceTask = nil
        tearDownSession(invalidateSession: true)
        // Shared model preparation is intentionally not cancelled.
    }

    // MARK: - Transcription

    private func transcribe(samples: [Float], sessionID: UUID) async throws -> String {
        let durationSeconds = Double(samples.count) / Self.targetSampleRate
        TimbreLog.line(
            "Timbre Parakeet: source=\(audioSource.diagnosticLabel) samples=\(samples.count) duration=\(String(format: "%.3f", durationSeconds))s"
        )

        // FluidAudio 0.15.5: ASRConstants.minimumAudioDurationSeconds (0.3s @ 16 kHz).
        let minimumSamples = ASRConstants.minimumRequiredSamples(
            forSampleRate: Int(Self.targetSampleRate)
        )
        if samples.count < minimumSamples {
            TimbreLog.line(
                "Timbre Parakeet: audio below FluidAudio minimum (\(minimumSamples) samples / \(ASRConstants.minimumAudioDurationSeconds)s)."
            )
            throw TranscriptionError.emptyResult
        }

        let manager = try await ensureAsrManager()
        let transcriptionStarted = Date()
        let task = Task<ASRResult, Error> {
            var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
            return try await manager.transcribe(samples, decoderState: &decoderState)
        }
        inferenceTask = task

        let result: ASRResult
        do {
            result = try await task.value
        } catch is CancellationError {
            inferenceTask = nil
            throw CancellationError()
        } catch {
            inferenceTask = nil
            if case ASRError.invalidAudioData = error {
                throw TranscriptionError.emptyResult
            }
            throw TranscriptionError.recognitionFailed(error.localizedDescription)
        }
        inferenceTask = nil

        let wall = Date().timeIntervalSince(transcriptionStarted)
        TimbreLog.line(
            "Timbre Parakeet: transcript=\"\(result.text)\" confidence=\(result.confidence) audioDuration=\(result.duration) processingTime=\(result.processingTime) wall=\(String(format: "%.3f", wall))s"
        )

        guard let current = session, current.id == sessionID, !current.isInvalidated else {
            throw CancellationError()
        }

        let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TranscriptionError.emptyResult
        }
        return trimmed
    }

    // MARK: - Model lifecycle

    private func ensureAsrManager() async throws -> AsrManager {
        if let asrManager {
            TimbreLog.line("Timbre Parakeet: reusing loaded AsrManager.")
            return asrManager
        }

        if let preparationTask {
            TimbreLog.line("Timbre Parakeet: awaiting in-flight model preparation.")
            do {
                let manager = try await preparationTask.value
                asrManager = manager
                return manager
            } catch {
                TimbreLog.line(
                    "Timbre Parakeet: in-flight model preparation failed, retrying — \(error.localizedDescription)"
                )
                self.preparationTask = nil
                asrManager = nil
            }
        }

        let cacheDirectory = AsrModels.defaultCacheDirectory(for: Self.modelVersion)
        let modelsAvailable = AsrModels.modelsExist(at: cacheDirectory, version: Self.modelVersion)
        TimbreLog.line(
            "Timbre Parakeet: preparing models version=v2 cache=\(cacheDirectory.path) exists=\(modelsAvailable)"
        )

        let started = Date()
        let task = Task<AsrManager, Error> {
            let models = try await AsrModels.downloadAndLoad(version: Self.modelVersion)
            return AsrManager(config: .default, models: models)
        }
        preparationTask = task

        do {
            let manager = try await task.value
            asrManager = manager
            let duration = Date().timeIntervalSince(started)
            TimbreLog.line("Timbre Parakeet: model ready in \(String(format: "%.3f", duration))s")
            return manager
        } catch {
            preparationTask = nil
            asrManager = nil
            throw TranscriptionError.recognitionFailed(
                "Parakeet model preparation failed: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Teardown

    private func tearDownSession(invalidateSession: Bool) {
        if invalidateSession {
            session?.invalidate(resumeWithCancellation: true)
            session = nil
        }
        audioSource.teardown()
    }
}
#endif
