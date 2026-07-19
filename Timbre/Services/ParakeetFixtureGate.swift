import Foundation

#if DEBUG
/// Runs the committed Parakeet WAV through AssistantController + clipboard once at launch.
@MainActor
enum ParakeetFixtureGate {
    static func runIfRequested(
        arguments: [String],
        controller: AssistantController
    ) {
        guard TranscriptionBackendSelection.wantsParakeetFixture(arguments: arguments, isDebug: true)
        else {
            return
        }

        Task { @MainActor in
            TimbreLog.line("Timbre Parakeet fixture: starting app-path transcription…")
            await controller.startDictation()
            await controller.stopDictation()

            let transcript = controller.lastCompletedTranscript ?? ""
            let validation = ParakeetTranscriptValidation.softValidate(transcript: transcript)
            if validation.passed {
                TimbreLog.line("Timbre Parakeet fixture: PASS transcript=\"\(transcript)\"")
            } else {
                TimbreLog.line(
                    "Timbre Parakeet fixture: FAIL transcript=\"\(transcript)\" normalized=\"\(validation.normalizedTranscript)\" state=\(controller.statusMessage)"
                )
            }
        }
    }
}
#endif
