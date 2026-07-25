import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class AssistantController {
    private(set) var sessionState: SessionState = .idle {
        didSet {
            sessionStateHandler?(sessionState)
        }
    }
    private(set) var audioLevel: Float = 0
    private(set) var lastCompletedTranscript: String?
    private(set) var activeSession: DictationSessionContext?

    private let transcription: TranscriptionServicing
    private let clipboard: ClipboardServicing
    private let delivery: TranscriptDeliveryServicing
    private let targetProvider: any DictationTargetProviding
    private let playback: any DictationPlaybackControlling
    @ObservationIgnored private var sessionStateHandler: ((SessionState) -> Void)?

    init(
        transcription: TranscriptionServicing,
        clipboard: ClipboardServicing = ClipboardService(),
        delivery: TranscriptDeliveryServicing,
        targetProvider: any DictationTargetProviding,
        playback: (any DictationPlaybackControlling)? = nil
    ) {
        self.transcription = transcription
        self.clipboard = clipboard
        self.delivery = delivery
        self.targetProvider = targetProvider
        self.playback = playback ?? NoOpDictationPlaybackController()
    }

    var liveTranscript: String { sessionState.displayedTranscript }
    var statusMessage: String { sessionState.statusMessage }
    var canStart: Bool { sessionState.canStart }
    var canStop: Bool { sessionState.canStop }
    var canCopyLastTranscript: Bool { lastCompletedTranscript != nil }

    func setSessionStateHandler(_ handler: ((SessionState) -> Void)?) {
        sessionStateHandler = handler
    }

    /// Starts the visible session synchronously, then performs preparation asynchronously.
    /// Shortcut handling uses this entry point so the indicator appears in the same event turn.
    @discardableResult
    func beginDictation() -> Task<Void, Never>? {
        guard canStart else { return nil }

        let session = DictationSessionContext(target: targetProvider.captureTarget())
        activeSession = session
        audioLevel = 0
        sessionState = .preparing

        return Task { [weak self] in
            await self?.prepareAndStart(session)
        }
    }

    func startDictation() async {
        guard let task = beginDictation() else { return }
        await task.value
    }

    private func prepareAndStart(_ session: DictationSessionContext) async {
        do {
            try await transcription.prepare()
            guard activeSession?.id == session.id else { return }

            try await transcription.start(
                onPartialResult: { [weak self] partial in
                    guard let self else { return }
                    guard self.activeSession?.id == session.id else { return }
                    self.sessionState = self.sessionState.updatingTranscript(partial)
                },
                onAudioLevel: { [weak self] level in
                    guard let self else { return }
                    guard self.activeSession?.id == session.id else { return }
                    self.audioLevel = min(max(level, 0), 1)
                }
            )
            guard activeSession?.id == session.id else { return }
            playback.beginListening()
            // Stop is only available after start succeeds.
            sessionState = .listening(transcript: sessionState.displayedTranscript)
        } catch {
            guard activeSession?.id == session.id else { return }
            playback.endListening()
            await transcription.cancel()
            activeSession = nil
            audioLevel = 0
            sessionState = .failed(
                kind: Self.failureKind(for: error),
                message: error.localizedDescription,
                transcript: ""
            )
        }
    }

    /// Releases microphone resources synchronously before the process exits.
    func prepareForTermination() {
        activeSession = nil
        audioLevel = 0
        playback.shutdownForTermination()
        (transcription as? TerminationHandling)?.shutdownForTermination()
    }

    func stopDictation() async {
        guard case .listening(let currentTranscript) = sessionState else { return }
        guard let session = activeSession else { return }

        audioLevel = 0
        playback.endListening()
        sessionState = .finishing(transcript: currentTranscript)

        do {
            let finalText = try await transcription.stop()
            guard activeSession?.id == session.id else { return }

            let trimmed = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                activeSession = nil
                sessionState = .failed(
                    kind: .noSpeech,
                    message: TranscriptionError.emptyResult.localizedDescription,
                    transcript: currentTranscript
                )
                return
            }

            lastCompletedTranscript = finalText
            let result = await delivery.deliver(finalText, to: session.target)
            guard activeSession?.id == session.id else { return }

            activeSession = nil
            sessionState = .completed(
                transcript: finalText,
                outcome: Self.completionOutcome(for: result)
            )
        } catch {
            guard activeSession?.id == session.id else { return }
            activeSession = nil
            audioLevel = 0
            sessionState = .failed(
                kind: Self.failureKind(for: error),
                message: error.localizedDescription,
                transcript: sessionState.displayedTranscript
            )
        }
    }

    func copyLastTranscript() {
        guard let text = lastCompletedTranscript, !text.isEmpty else { return }
        let copied = clipboard.copy(text)
        sessionState = .completed(
            transcript: text,
            outcome: copied ? .copiedByDesign : .deliveryFailed
        )
    }

    private static func completionOutcome(
        for result: TranscriptDeliveryResult
    ) -> TranscriptCompletionOutcome {
        switch result {
        case .pasteEventPosted:
            return .inserted
        case .copiedByDesign:
            return .copiedByDesign
        case .copiedAfterInsertFailure:
            return .copiedAfterInsertFailure
        case .failed:
            return .deliveryFailed
        }
    }

    private static func failureKind(for error: Error) -> SessionFailureKind {
        guard let transcriptionError = error as? TranscriptionError else {
            return .recognition
        }
        switch transcriptionError {
        case .emptyResult:
            return .noSpeech
        case .microphonePermissionDenied, .speechPermissionDenied:
            return .permission
        case .audioEngineFailed:
            return .audio
        case .notAvailable, .alreadyRunning, .notRunning, .recognitionFailed:
            return .recognition
        }
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }
}
