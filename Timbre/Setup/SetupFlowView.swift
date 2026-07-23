import KeyboardShortcuts
import SwiftUI

struct SetupFlowView: View {
    @Bindable var coordinator: SetupCoordinator
    var usesRealShortcutRecorder: Bool = true
    var onContinueInBackground: (() -> Void)?
    var onDone: () -> Void

    var body: some View {
        ZStack {
            Image("OnboardingBackground")
                .resizable()
                .scaledToFill()
                .accessibilityHidden(true)

            LinearGradient(
                colors: [
                    Color.black.opacity(0.55),
                    Color.black.opacity(0.35),
                    Color.black.opacity(0.72),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 0) {
                stepContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(.horizontal, 36)
            .padding(.top, 48)
            .padding(.bottom, 28)
            .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("setupFlowRoot")
    }

    @ViewBuilder
    private var stepContent: some View {
        switch coordinator.step {
        case .welcome:
            welcome
        case .shortcut:
            shortcut
        case .microphone:
            microphone
        case .microphoneDenied:
            microphoneDenied
        case .textInsertion:
            textInsertion
        case .textInsertionDenied:
            textInsertionDenied
        case .preparing:
            preparing
        case .ready:
            ready
        case .failed:
            failed
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Timbre")
                .font(.system(size: 36, weight: .semibold, design: .rounded))
                .accessibilityAddTraits(.isHeader)
            Text("Voice dictation for your Mac.")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.85))
            Text("Set it up once, then dictate anywhere.")
                .font(.body)
                .foregroundStyle(.white.opacity(0.7))
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Continue") {
                    coordinator.continueFromWelcome()
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("setupContinueButton")
            }
        }
    }

    private var shortcut: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose your shortcut")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text("Use this shortcut to start and stop dictation from anywhere.")
                .font(.body)
                .foregroundStyle(.white.opacity(0.75))

            Group {
                if usesRealShortcutRecorder {
                    KeyboardShortcuts.Recorder(for: .toggleDictation) { newShortcut in
                        coordinator.shortcutRecorderDidChange(
                            isAssigned: newShortcut != nil,
                            displayString: newShortcut?.description
                        )
                    }
                    .accessibilityIdentifier("setupShortcutRecorder")
                } else {
                    simulatedShortcutControls
                }
            }
            .padding(.top, 8)

            if !coordinator.canContinueFromShortcut {
                Text("Record a shortcut to continue.")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.65))
                    .accessibilityIdentifier("setupShortcutRequiredHint")
            }

            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Continue") {
                    coordinator.continueFromShortcut()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!coordinator.canContinueFromShortcut)
                .accessibilityIdentifier("setupShortcutContinueButton")
            }
        }
    }

    private var simulatedShortcutControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(coordinator.shortcutDisplayString)
                .font(.title3.monospaced())
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityIdentifier("setupSimulatedShortcutValue")

            HStack(spacing: 12) {
                Button("Clear") {
                    coordinator.shortcutRecorderDidChange(isAssigned: false, displayString: nil)
                }
                .accessibilityIdentifier("setupSimulatedShortcutClear")

                Button("Use ⌃⇧D") {
                    coordinator.shortcutRecorderDidChange(
                        isAssigned: true,
                        displayString: DictationShortcutName.temporaryDefaultDisplayString
                    )
                }
                .accessibilityIdentifier("setupSimulatedShortcutAssign")
            }
        }
    }

    private var microphone: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Microphone Access")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text("Timbre uses your microphone when you start dictating.")
                .font(.body)
                .foregroundStyle(.white.opacity(0.75))
            Spacer(minLength: 0)
            ProgressView()
                .controlSize(.small)
                .tint(.white)
        }
    }

    private var microphoneDenied: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Microphone Access")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text("Microphone access is turned off. Enable it in System Settings to continue.")
                .font(.body)
                .foregroundStyle(.white.opacity(0.75))
            Spacer(minLength: 0)
            HStack {
                Button("Open System Settings") {
                    coordinator.openMicrophoneSettings()
                }
                .accessibilityIdentifier("setupOpenMicSettingsButton")
                Spacer()
                Button("Try Again") {
                    coordinator.retryMicrophone()
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("setupMicRetryButton")
            }
        }
    }

    private var textInsertion: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Text Insertion")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text("Allow Timbre to place your dictation into other apps.")
                .font(.body)
                .foregroundStyle(.white.opacity(0.75))
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Continue") {
                    coordinator.requestTextInsertionAccess()
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("setupTextInsertionContinueButton")
            }
        }
    }

    private var textInsertionDenied: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Text Insertion")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text("Text insertion access is turned off. Enable Timbre in System Settings to continue.")
                .font(.body)
                .foregroundStyle(.white.opacity(0.75))
            Spacer(minLength: 0)
            HStack {
                Button("Open System Settings") {
                    coordinator.openAccessibilitySettings()
                }
                .accessibilityIdentifier("setupOpenAccessibilitySettingsButton")
                Spacer()
                Button("Try Again") {
                    coordinator.requestTextInsertionAccess()
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("setupAccessibilityRetryButton")
            }
        }
    }

    private var preparing: some View {
        let progress = coordinator.preparationProgress
        return VStack(alignment: .leading, spacing: 16) {
            Text("Getting Timbre ready")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text("Timbre needs to download an additional component before you can start dictating.")
                .font(.body)
                .foregroundStyle(.white.opacity(0.75))

            if let detail = progress.detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.65))
            }

            if let fraction = progress.fraction {
                ProgressView(value: fraction, total: 1)
                    .progressViewStyle(.linear)
                    .tint(.white)
                    .accessibilityIdentifier("setupProgress")
                HStack {
                    if let percent = progress.percentText {
                        Text(percent)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.65))
                            .monospacedDigit()
                            .accessibilityIdentifier("setupProgressPercent")
                    }
                    Spacer()
                    if let eta = progress.estimatedTimeRemainingText {
                        Text(eta)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.65))
                            .accessibilityIdentifier("setupProgressETA")
                    }
                }
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(.white)
                    .accessibilityIdentifier("setupProgress")
            }

            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Continue in Background") {
                    onContinueInBackground?()
                }
                .accessibilityIdentifier("setupContinueInBackgroundButton")
            }
        }
    }

    private var ready: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Timbre is ready")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text("Press \(coordinator.shortcutDisplayString) to start dictating anywhere.")
                .font(.body)
                .foregroundStyle(.white.opacity(0.75))
                .accessibilityIdentifier("setupReadyShortcutHint")
                .accessibilityLabel(
                    "Press \(coordinator.shortcutDisplayString) to start dictating anywhere."
                )
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Done") {
                    onDone()
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("setupDoneButton")
            }
        }
    }

    private var failed: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Something went wrong")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text("Timbre couldn’t finish getting ready. You can try again.")
                .font(.body)
                .foregroundStyle(.white.opacity(0.75))
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Try Again") {
                    coordinator.retryAfterFailure()
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("setupRetryButton")
            }
        }
    }
}

#if DEBUG
#Preview("Welcome") {
    SetupFlowView(
        coordinator: SetupPreviewFactory.coordinator(stepSeed: .welcome),
        usesRealShortcutRecorder: false,
        onDone: {}
    )
    .frame(width: 560, height: 440)
}

#Preview("Shortcut") {
    SetupFlowView(
        coordinator: SetupPreviewFactory.coordinator(stepSeed: .shortcut),
        usesRealShortcutRecorder: false,
        onDone: {}
    )
    .frame(width: 560, height: 440)
}

#Preview("Preparing") {
    SetupFlowView(
        coordinator: SetupPreviewFactory.coordinator(stepSeed: .preparing),
        usesRealShortcutRecorder: false,
        onDone: {}
    )
    .frame(width: 560, height: 440)
}

#Preview("Ready") {
    SetupFlowView(
        coordinator: SetupPreviewFactory.coordinator(stepSeed: .ready),
        usesRealShortcutRecorder: false,
        onDone: {}
    )
    .frame(width: 560, height: 440)
}

@MainActor
enum SetupPreviewFactory {
    enum StepSeed {
        case welcome
        case shortcut
        case preparing
        case ready
    }

    static func coordinator(stepSeed: StepSeed) -> SetupCoordinator {
        let preferences: InMemoryOnboardingPreferences
        let model: SimulatedParakeetModelManager
        let mic: SimulatedMicrophonePermission
        let ax: SimulatedAccessibilityPermission
        let shortcut: SimulatedShortcutOnboarding

        switch stepSeed {
        case .welcome:
            preferences = InMemoryOnboardingPreferences()
            model = SimulatedParakeetModelManager(initialState: .notInstalled)
            mic = SimulatedMicrophonePermission(status: .undetermined)
            ax = SimulatedAccessibilityPermission(trustState: .notTrusted)
            shortcut = SimulatedShortcutOnboarding()
        case .shortcut:
            preferences = InMemoryOnboardingPreferences(completedWelcome: true)
            model = SimulatedParakeetModelManager(initialState: .notInstalled)
            mic = SimulatedMicrophonePermission(status: .granted)
            ax = SimulatedAccessibilityPermission(trustState: .trusted)
            shortcut = SimulatedShortcutOnboarding()
        case .preparing:
            preferences = InMemoryOnboardingPreferences(
                completedWelcome: true,
                completedShortcutOnboarding: true
            )
            model = SimulatedParakeetModelManager(initialState: .downloading, durationSeconds: 30)
            mic = SimulatedMicrophonePermission(status: .granted)
            ax = SimulatedAccessibilityPermission(trustState: .trusted)
            shortcut = SimulatedShortcutOnboarding()
        case .ready:
            preferences = InMemoryOnboardingPreferences(
                completedWelcome: true,
                completedShortcutOnboarding: true
            )
            model = SimulatedParakeetModelManager(initialState: .installed)
            mic = SimulatedMicrophonePermission(status: .granted)
            ax = SimulatedAccessibilityPermission(trustState: .trusted)
            shortcut = SimulatedShortcutOnboarding()
        }

        return SetupCoordinator(
            modelManager: model,
            microphone: mic,
            accessibility: ax,
            preferences: preferences,
            shortcutOnboarding: shortcut,
            featureEnabled: true
        )
    }
}
#endif
