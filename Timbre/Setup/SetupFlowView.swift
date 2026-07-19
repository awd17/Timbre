import SwiftUI

struct SetupFlowView: View {
    @Bindable var coordinator: SetupCoordinator
    var onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch coordinator.step {
            case .welcome:
                welcome
            case .microphone:
                microphone
            case .microphoneDenied:
                microphoneDenied
            case .preparing:
                preparing
            case .ready:
                ready
            case .failed:
                failed
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Timbre", systemImage: "waveform")
                .font(.title2.weight(.semibold))
            Text("Voice dictation from the menu bar.")
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Continue") {
                    coordinator.continueFromWelcome()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var microphone: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Microphone Access")
                .font(.title3.weight(.semibold))
            Text("Timbre needs the microphone to hear your dictation.")
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            ProgressView()
                .controlSize(.small)
        }
    }

    private var microphoneDenied: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Microphone Access")
                .font(.title3.weight(.semibold))
            Text("Microphone access is turned off. Enable it in System Settings to continue.")
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            HStack {
                Button("Open System Settings") {
                    coordinator.openMicrophoneSettings()
                }
                Spacer()
                Button("Try Again") {
                    coordinator.retryMicrophone()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var preparing: some View {
        let progress = coordinator.preparationProgress
        return VStack(alignment: .leading, spacing: 16) {
            Text("Getting Timbre ready…")
                .font(.title3.weight(.semibold))
            Text("An additional download is required. This may take a few minutes.")
                .foregroundStyle(.secondary)
            Text("You can close this window while Timbre finishes getting ready.")
                .font(.callout)
                .foregroundStyle(.secondary)

            if let detail = progress.detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let fraction = progress.fraction {
                ProgressView(value: fraction, total: 1)
                    .progressViewStyle(.linear)
                    .accessibilityIdentifier("setupProgress")
                HStack {
                    if let percent = progress.percentText {
                        Text(percent)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .accessibilityIdentifier("setupProgressPercent")
                    }
                    Spacer()
                    if let eta = progress.estimatedTimeRemainingText {
                        Text(eta)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("setupProgressETA")
                    }
                }
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }

            Spacer(minLength: 0)
        }
    }

    private var ready: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Timbre is ready.", systemImage: "checkmark.circle.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Done") {
                    onDone()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var failed: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Something went wrong while getting Timbre ready.")
                .font(.title3.weight(.semibold))
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Try Again") {
                    coordinator.retryAfterFailure()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}
