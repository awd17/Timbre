import SwiftUI

struct MenuBarDictationView: View {
    var controller: AssistantController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Timbre")
                .font(.headline)

            Text(controller.statusMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("statusMessage")
                .accessibilityLabel(controller.statusMessage)

            Text(controller.liveTranscript.isEmpty ? "—" : controller.liveTranscript)
                .font(.body)
                .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .accessibilityIdentifier("transcriptText")

            HStack {
                if controller.canStop {
                    Button("Stop") {
                        Task { await controller.stopDictation() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("stopButton")
                } else {
                    Button("Start") {
                        Task { await controller.startDictation() }
                    }
                    .disabled(!controller.canStart)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("startButton")
                }

                Button("Copy Again") {
                    controller.copyLastTranscript()
                }
                .disabled(!controller.canCopyAgain)
                .accessibilityIdentifier("copyAgainButton")

                Spacer()

                Button("Quit") {
                    controller.quit()
                }
                .accessibilityIdentifier("quitButton")
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}
