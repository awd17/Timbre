import FluidAudio
import Foundation

/// Production Parakeet v2 batch transcription via FluidAudio.
@MainActor
final class ParakeetTranscriptionService: TranscriptionServicing, TerminationHandling {
    private static let targetSampleRate = 16_000.0

    private let audioSource: any ParakeetAudioSource
    private let modelManager: ParakeetModelManager
    private var session: TranscriptionSession?
    private var inferenceTask: Task<ASRResult, Error>?

    init(audioSource: any ParakeetAudioSource, modelManager: ParakeetModelManager) {
        self.audioSource = audioSource
        self.modelManager = modelManager
    }

    convenience init(fixtureURL: URL, modelManager: ParakeetModelManager) {
        self.init(
            audioSource: ParakeetFixtureAudioSource(url: fixtureURL),
            modelManager: modelManager
        )
    }

    static func defaultFixtureURL() -> URL? {
        Bundle.main.url(forResource: "parakeet-smoke-test", withExtension: "wav")
    }

    func prepare() async throws {
#if arch(arm64)
        try await audioSource.prepareAccess()
        _ = try await modelManager.ensureLoaded()
#else
        throw TranscriptionError.recognitionFailed("Parakeet models require Apple Silicon.")
#endif
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

        let manager = try await modelManager.ensureLoaded()
        let transcriptionStarted = Date()
        let task = Task<ASRResult, Error> {
            var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
            return try await manager.transcribe(
                samples,
                decoderState: &decoderState,
                language: nil
            )
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

    // MARK: - Teardown

    private func tearDownSession(invalidateSession: Bool) {
        if invalidateSession {
            session?.invalidate(resumeWithCancellation: true)
            session = nil
        }
        audioSource.teardown()
    }
}
