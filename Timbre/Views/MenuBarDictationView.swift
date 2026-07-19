import SwiftUI

struct MenuBarDictationView: View {
    var controller: AssistantController
    var setupCoordinator: SetupCoordinator?
    var shortcutCoordinator: DictationShortcutCoordinator?
    var onOpenSetup: (() -> Void)?

    var body: some View {
        Group {
            if let setupCoordinator, setupCoordinator.blocksDictationUI {
                setupBlockedContent(setupCoordinator)
            } else {
                dictationContent
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    @ViewBuilder
    private func setupBlockedContent(_ setupCoordinator: SetupCoordinator) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Timbre")
                .font(.headline)

            Text(setupCoordinator.menuStatusText ?? "Setup required")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("setupStatusMessage")

            if setupCoordinator.modelState.isInstalling {
                preparationProgressViews(setupCoordinator.preparationProgress)
            } else {
                Text("Finish setup to start dictation.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }

            if let hint = shortcutCoordinator?.menuHintText() {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("shortcutHint")
            }

            if let title = setupCoordinator.menuActionTitle {
                Button(title) {
                    onOpenSetup?()
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("setupMenuButton")
            }

            HStack {
                Spacer()
                Button("Quit") {
                    controller.quit()
                }
                .accessibilityIdentifier("quitButton")
            }
        }
    }

    private var dictationContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Timbre")
                .font(.headline)

            if let setupCoordinator, let status = setupCoordinator.menuStatusText {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("setupStatusMessage")
            }

            Text(controller.statusMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("statusMessage")
                .accessibilityLabel(controller.statusMessage)

            if let hint = shortcutCoordinator?.menuHintText() {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("shortcutHint")
            }

            Text(controller.liveTranscript.isEmpty ? "—" : controller.liveTranscript)
                .font(.body)
                .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .accessibilityIdentifier("transcriptText")

            if let setupCoordinator, let title = setupCoordinator.menuActionTitle {
                Button(title) {
                    onOpenSetup?()
                }
                .accessibilityIdentifier("setupMenuButton")
            }

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
                    .disabled(!controller.canStart || !(setupCoordinator?.allowsDictation ?? true))
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
    }

    @ViewBuilder
    private func preparationProgressViews(_ progress: ModelPreparationProgress) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let detail = progress.detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let fraction = progress.fraction {
                ProgressView(value: fraction, total: 1)
                    .progressViewStyle(.linear)
                    .accessibilityIdentifier("menuSetupProgress")
                HStack {
                    if let percent = progress.percentText {
                        Text(percent)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Spacer()
                    if let eta = progress.estimatedTimeRemainingText {
                        Text(eta)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }
        }
    }
}
