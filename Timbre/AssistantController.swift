import AppKit
import Foundation

@MainActor
@Observable
final class AssistantController {
    private(set) var sessionState: SessionState = .idle
    private(set) var lastCompletedTranscript: String?

    private let transcription: TranscriptionServicing
    private let clipboard: ClipboardServicing

    init(
        transcription: TranscriptionServicing,
        clipboard: ClipboardServicing = ClipboardService()
    ) {
        self.transcription = transcription
        self.clipboard = clipboard
    }

    var liveTranscript: String { sessionState.displayedTranscript }
    var statusMessage: String { sessionState.statusMessage }
    var canStart: Bool { sessionState.canStart }
    var canStop: Bool { sessionState.canStop }
    var canCopyAgain: Bool { lastCompletedTranscript != nil }

    func startDictation() async {
        guard canStart else { return }

        sessionState = .preparing

        do {
            try await transcription.prepare()
            try await transcription.start { [weak self] partial in
                guard let self else { return }
                self.sessionState = self.sessionState.updatingTranscript(partial)
            }
            // Stop is only available after start succeeds.
            sessionState = .listening(transcript: sessionState.displayedTranscript)
        } catch {
            await transcription.cancel()
            sessionState = .failed(message: error.localizedDescription, transcript: "")
        }
    }

    /// Releases microphone resources synchronously before the process exits.
    func prepareForTermination() {
        (transcription as? TerminationHandling)?.shutdownForTermination()
    }

    func stopDictation() async {
        guard case .listening(let currentTranscript) = sessionState else { return }

        sessionState = .finishing(transcript: currentTranscript)

        do {
            let finalText = try await transcription.stop()
            let trimmed = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                sessionState = .failed(
                    message: TranscriptionError.emptyResult.localizedDescription,
                    transcript: currentTranscript
                )
                return
            }

            lastCompletedTranscript = finalText
            clipboard.copy(finalText)
            sessionState = .completed(transcript: finalText)
        } catch {
            sessionState = .failed(
                message: error.localizedDescription,
                transcript: sessionState.displayedTranscript
            )
        }
    }

    func copyLastTranscript() {
        guard let text = lastCompletedTranscript, !text.isEmpty else { return }
        clipboard.copy(text)
        sessionState = .completed(transcript: text)
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }
}
