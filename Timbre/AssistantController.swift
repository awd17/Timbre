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
    private var playbackSessionID: UUID?
    private var transcriptionCleanupTask: Task<Void, Never>?
    private var deliveryCancellation: TranscriptDeliveryCancellationToken?
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
    var canCancel: Bool { activeSession != nil }
    var canCopyLastTranscript: Bool { lastCompletedTranscript != nil }

    func setSessionStateHandler(_ handler: ((SessionState) -> Void)?) {
        sessionStateHandler = handler
    }

    /// Starts the visible session synchronously, then performs preparation asynchronously.
    /// This programmatic entry point intentionally leaves other playback unchanged.
    @discardableResult
    func beginDictation() -> Task<Void, Never>? {
        beginDictation(adjustsPlayback: false)
    }

    /// Starts dictation from Timbre's global hotkey.
    ///
    /// Playback attenuation is deliberately scoped to this path so unrelated
    /// microphone activity and non-hotkey diagnostic flows cannot trigger it.
    @discardableResult
    func beginDictationFromShortcut() -> Task<Void, Never>? {
        beginDictation(adjustsPlayback: true)
    }

    private func beginDictation(
        adjustsPlayback: Bool
    ) -> Task<Void, Never>? {
        guard canStart else { return nil }

        let session = DictationSessionContext(target: targetProvider.captureTarget())
        activeSession = session
        playbackSessionID = adjustsPlayback ? session.id : nil
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

    func startDictationFromShortcut() async {
        guard let task = beginDictationFromShortcut() else { return }
        await task.value
    }

    private func prepareAndStart(_ session: DictationSessionContext) async {
        // The transcription service owns one shared microphone session. A
        // replacement session must not enter it until every earlier
        // cancellation has finished tearing down that shared state.
        if let transcriptionCleanupTask {
            await transcriptionCleanupTask.value
        }
        guard activeSession?.id == session.id else { return }

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
            if playbackSessionID == session.id {
                playback.beginListening()
            }
            // Stop is only available after start succeeds.
            sessionState = .listening(transcript: sessionState.displayedTranscript)
        } catch {
            guard activeSession?.id == session.id else { return }
            endPlayback(for: session)
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
        deliveryCancellation?.cancel()
        deliveryCancellation = nil
        activeSession = nil
        playbackSessionID = nil
        audioLevel = 0
        playback.shutdownForTermination()
        (transcription as? TerminationHandling)?.shutdownForTermination()
    }

    func stopDictation() async {
        guard case .listening(let currentTranscript) = sessionState else { return }
        guard let session = activeSession else { return }

        audioLevel = 0
        endPlayback(for: session)
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

            let deliveryCancellation = TranscriptDeliveryCancellationToken()
            self.deliveryCancellation = deliveryCancellation
            let result = await delivery.deliver(
                finalText,
                to: session.target,
                cancellation: deliveryCancellation
            )
            if self.deliveryCancellation === deliveryCancellation {
                self.deliveryCancellation = nil
            }
            guard activeSession?.id == session.id else { return }
            guard result != .cancelled else {
                activeSession = nil
                sessionState = .idle
                return
            }

            lastCompletedTranscript = finalText
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

    /// Immediately abandons the active recording without transcription or delivery.
    ///
    /// Session identity is invalidated before asynchronous microphone cleanup
    /// begins, so late partials, final text, and stop results cannot be inserted.
    @discardableResult
    func cancelDictation() -> Task<Void, Never>? {
        guard let session = activeSession else { return nil }

        let previousCleanupTask = transcriptionCleanupTask
        let cleanupTask = Task { [transcription] in
            await previousCleanupTask?.value
            await transcription.cancel()
        }
        transcriptionCleanupTask = cleanupTask

        deliveryCancellation?.cancel()
        deliveryCancellation = nil
        activeSession = nil
        audioLevel = 0
        endPlayback(for: session)
        sessionState = .idle
        TimbreLog.line("Timbre dictation: cancelled.")

        return cleanupTask
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
        case .cancelled:
            return .deliveryFailed
        }
    }

    private func endPlayback(for session: DictationSessionContext) {
        guard playbackSessionID == session.id else { return }
        playbackSessionID = nil
        playback.endListening()
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
