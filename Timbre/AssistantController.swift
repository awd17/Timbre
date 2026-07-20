import AppKit
import Foundation

@MainActor
@Observable
final class AssistantController {
    private(set) var sessionState: SessionState = .idle
    private(set) var lastCompletedTranscript: String?
    private(set) var activeSession: DictationSessionContext?

    private let transcription: TranscriptionServicing
    private let clipboard: ClipboardServicing
    private let delivery: TranscriptDeliveryServicing
    private let targetProvider: any DictationTargetProviding

    init(
        transcription: TranscriptionServicing,
        clipboard: ClipboardServicing = ClipboardService(),
        delivery: TranscriptDeliveryServicing,
        targetProvider: any DictationTargetProviding
    ) {
        self.transcription = transcription
        self.clipboard = clipboard
        self.delivery = delivery
        self.targetProvider = targetProvider
    }

    var liveTranscript: String { sessionState.displayedTranscript }
    var statusMessage: String { sessionState.statusMessage }
    var canStart: Bool { sessionState.canStart }
    var canStop: Bool { sessionState.canStop }
    var canCopyAgain: Bool { lastCompletedTranscript != nil }

    func startDictation() async {
        guard canStart else { return }

        let session = DictationSessionContext(target: targetProvider.captureTarget())
        activeSession = session
        sessionState = .preparing

        do {
            try await transcription.prepare()
            guard activeSession?.id == session.id else { return }

            try await transcription.start { [weak self] partial in
                guard let self else { return }
                guard self.activeSession?.id == session.id else { return }
                self.sessionState = self.sessionState.updatingTranscript(partial)
            }
            guard activeSession?.id == session.id else { return }
            // Stop is only available after start succeeds.
            sessionState = .listening(transcript: sessionState.displayedTranscript)
        } catch {
            guard activeSession?.id == session.id else { return }
            await transcription.cancel()
            activeSession = nil
            sessionState = .failed(message: error.localizedDescription, transcript: "")
        }
    }

    /// Releases microphone resources synchronously before the process exits.
    func prepareForTermination() {
        activeSession = nil
        (transcription as? TerminationHandling)?.shutdownForTermination()
    }

    func stopDictation() async {
        guard case .listening(let currentTranscript) = sessionState else { return }
        guard let session = activeSession else { return }

        sessionState = .finishing(transcript: currentTranscript)

        do {
            let finalText = try await transcription.stop()
            guard activeSession?.id == session.id else { return }

            let trimmed = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                activeSession = nil
                sessionState = .failed(
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
            sessionState = .failed(
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

    func quit() {
        NSApplication.shared.terminate(nil)
    }
}
