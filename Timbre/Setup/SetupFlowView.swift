import KeyboardShortcuts
import SwiftUI

struct SetupFlowView: View {
    @Bindable var coordinator: SetupCoordinator
    var shortcutRecorderName: KeyboardShortcuts.Name = .toggleDictation
    var onContinueInBackground: (() -> Void)?
    var onDone: () -> Void
    @State private var isRecordingShortcut = false

    var body: some View {
        ZStack {
            // Opaque backstop so no default window gray can peek through edges.
            Color.black
                .ignoresSafeArea()
                .accessibilityHidden(true)

            Image("OnboardingBackground")
                .resizable()
                .scaledToFill()
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .clipped()
                .ignoresSafeArea()
                .accessibilityHidden(true)

            LinearGradient(
                colors: [
                    Color.black.opacity(0.42),
                    Color.black.opacity(0.18),
                    Color.black.opacity(0.60),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .accessibilityHidden(true)

            stepContent
                .id(coordinator.step)
                .transition(.opacity)
                .padding(.horizontal, 44)
                .padding(.top, 36)
                .padding(.bottom, 30)
                .foregroundStyle(.white)
        }
        .animation(.easeInOut(duration: 0.25), value: coordinator.step)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .ignoresSafeArea()
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

    // MARK: - Scaffold

    private func stepScaffold<Hero: View, Content: View, Footer: View>(
        title: String,
        subtitle: String,
        @ViewBuilder hero: () -> Hero,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            hero()
            Text(title)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .accessibilityAddTraits(.isHeader)
                .padding(.top, 20)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.72))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: 400)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 9)
            }
            content()
            Spacer(minLength: 0)
            footer()
        }
        .frame(maxWidth: .infinity)
    }

    private func stepScaffold<Hero: View, Footer: View>(
        title: String,
        subtitle: String,
        @ViewBuilder hero: () -> Hero,
        @ViewBuilder footer: () -> Footer
    ) -> some View {
        stepScaffold(title: title, subtitle: subtitle, hero: hero, content: { EmptyView() }, footer: footer)
    }

    private var appIconHero: some View {
        Image("OnboardingAppIcon")
            .resizable()
            .interpolation(.high)
            .frame(width: 92, height: 92)
            .shadow(color: .black.opacity(0.5), radius: 18, y: 10)
            .accessibilityHidden(true)
    }

    private func symbolHero(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 25, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: 62, height: 62)
            .background(.white.opacity(0.10), in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.20), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
            .accessibilityHidden(true)
    }

    // MARK: - Steps

    private var welcome: some View {
        stepScaffold(
            title: "Welcome to Timbre",
            subtitle: "Voice dictation for your Mac.\nSet it up once, then dictate anywhere.",
            hero: { appIconHero },
            footer: {
                Button("Continue") {
                    coordinator.continueFromWelcome()
                }
                .buttonStyle(OnboardingPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("setupContinueButton")
            }
        )
    }

    private var shortcut: some View {
        stepScaffold(
            title: "Choose your shortcut",
            subtitle: "Use this shortcut to start and stop dictation from anywhere.",
            hero: { symbolHero("command") },
            content: {
                VStack(spacing: 16) {
                    VStack(spacing: 9) {
                        Text("YOUR HOTKEY")
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(1.4)
                            .foregroundStyle(.white.opacity(0.48))

                        if coordinator.canContinueFromShortcut {
                            if let shortcut = coordinator.shortcutDisplayString {
                                ShortcutKeyCapsView(displayString: shortcut)
                                    .accessibilityElement(children: .ignore)
                                    .accessibilityLabel("Current hotkey \(shortcut)")
                                    .accessibilityIdentifier("setupShortcutKeyCaps")
                            }
                        } else {
                            Text("Not set")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                    }
                    .frame(minHeight: 54)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("setupShortcutDisplay")

                    Button {
                        guard !isRecordingShortcut else { return }
                        isRecordingShortcut = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: isRecordingShortcut ? "dot.radiowaves.left.and.right" : "keyboard")
                                .font(.system(size: 12, weight: .semibold))
                            Text(isRecordingShortcut ? "Listening for shortcut…" : "Set hotkey")
                        }
                        .frame(minWidth: 154)
                    }
                    .buttonStyle(OnboardingSecondaryButtonStyle())
                    .accessibilityLabel(isRecordingShortcut ? "Listening for shortcut" : "Set hotkey")
                    .accessibilityIdentifier("setupShortcutSetButton")
                    .overlay {
                        ShortcutRecorderCapture(
                            name: shortcutRecorderName,
                            isRecording: $isRecordingShortcut
                        ) { newShortcut in
                            coordinator.shortcutRecorderDidChange(
                                isAssigned: newShortcut != nil,
                                displayString: newShortcut?.description
                            )
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityHidden(true)
                    }

                    Text(
                        isRecordingShortcut
                            ? "Press the shortcut you want to use."
                            : "Use ⌃, ⌥, or ⌘ with a letter, number, Space, or function key."
                    )
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(isRecordingShortcut ? 0.85 : 0.6))
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("setupShortcutRecordingStatus")
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 22)
            },
            footer: {
                Button("Continue") {
                    coordinator.continueFromShortcut()
                }
                .buttonStyle(OnboardingPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!coordinator.canContinueFromShortcut)
                .accessibilityIdentifier("setupShortcutContinueButton")
            }
        )
    }

    private var microphone: some View {
        stepScaffold(
            title: "Microphone Access",
            subtitle: "Timbre uses your microphone when you start dictating.",
            hero: { symbolHero("mic.fill") },
            content: {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                    .padding(.top, 24)
            },
            footer: { EmptyView() }
        )
    }

    private var microphoneDenied: some View {
        stepScaffold(
            title: "Microphone Access",
            subtitle: "Microphone access is turned off. Enable it in System Settings to continue.",
            hero: { symbolHero("mic.slash.fill") },
            footer: {
                HStack(spacing: 10) {
                    Button("Open System Settings") {
                        coordinator.openMicrophoneSettings()
                    }
                    .buttonStyle(OnboardingSecondaryButtonStyle())
                    .accessibilityIdentifier("setupOpenMicSettingsButton")

                    Button("Try Again") {
                        coordinator.retryMicrophone()
                    }
                    .buttonStyle(OnboardingPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("setupMicRetryButton")
                }
            }
        )
    }

    private var textInsertion: some View {
        stepScaffold(
            title: "Text Insertion",
            subtitle: "Allow Timbre to place your dictation into other apps.",
            hero: { symbolHero("character.cursor.ibeam") },
            footer: {
                Button("Continue") {
                    coordinator.requestTextInsertionAccess()
                }
                .buttonStyle(OnboardingPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("setupTextInsertionContinueButton")
            }
        )
    }

    private var textInsertionDenied: some View {
        stepScaffold(
            title: "Text Insertion",
            subtitle: "Text insertion access is turned off. Enable Timbre in System Settings to continue.",
            hero: { symbolHero("character.cursor.ibeam") },
            footer: {
                HStack(spacing: 10) {
                    Button("Open System Settings") {
                        coordinator.openAccessibilitySettings()
                    }
                    .buttonStyle(OnboardingSecondaryButtonStyle())
                    .accessibilityIdentifier("setupOpenAccessibilitySettingsButton")

                    Button("Try Again") {
                        coordinator.requestTextInsertionAccess()
                    }
                    .buttonStyle(OnboardingPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("setupAccessibilityRetryButton")
                }
            }
        )
    }

    private var preparing: some View {
        let progress = coordinator.preparationProgress
        return stepScaffold(
            title: "Getting Timbre ready",
            subtitle: "Timbre needs to download an additional component before you can start dictating.",
            hero: { symbolHero("arrow.down.circle") },
            content: {
                VStack(spacing: 10) {
                    if let detail = progress.detail {
                        Text(detail)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.6))
                    }

                    if let fraction = progress.fraction {
                        ProgressView(value: fraction, total: 1)
                            .progressViewStyle(.linear)
                            .tint(.white)
                            .accessibilityIdentifier("setupProgress")
                        HStack {
                            if let percent = progress.percentText {
                                Text(percent)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white.opacity(0.6))
                                    .monospacedDigit()
                                    .accessibilityIdentifier("setupProgressPercent")
                            }
                            Spacer()
                            if let eta = progress.estimatedTimeRemainingText {
                                Text(eta)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white.opacity(0.6))
                                    .accessibilityIdentifier("setupProgressETA")
                            }
                        }
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                            .tint(.white)
                            .accessibilityIdentifier("setupProgress")
                    }
                }
                .frame(maxWidth: 340)
                .frame(maxWidth: .infinity)
                .padding(.top, 22)
            },
            footer: {
                Button("Continue in Background") {
                    onContinueInBackground?()
                }
                .buttonStyle(OnboardingSecondaryButtonStyle())
                .accessibilityIdentifier("setupContinueInBackgroundButton")
            }
        )
    }

    private var ready: some View {
        stepScaffold(
            title: "Timbre is ready",
            subtitle: "",
            hero: { appIconHero },
            content: {
                Group {
                    if let shortcut = coordinator.shortcutDisplayString {
                        HStack(spacing: 7) {
                            Text("Press")
                            ShortcutKeyCapsView(displayString: shortcut)
                            Text("to start dictating anywhere.")
                        }
                    } else {
                        Text(
                            "Start dictation from the Timbre menu, or add a shortcut in Settings."
                        )
                    }
                }
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.8))
                .padding(.top, 10)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    coordinator.shortcutDisplayString.map {
                        "Press \($0) to start dictating anywhere."
                    } ?? "Start dictation from the Timbre menu, or add a shortcut in Settings."
                )
                .accessibilityIdentifier("setupReadyShortcutHint")
            },
            footer: {
                Button("Done") {
                    onDone()
                }
                .buttonStyle(OnboardingPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("setupDoneButton")
            }
        )
    }

    private var failed: some View {
        stepScaffold(
            title: "Something went wrong",
            subtitle: "Timbre couldn’t finish getting ready. You can try again.",
            hero: { symbolHero("exclamationmark.triangle") },
            footer: {
                Button("Try Again") {
                    coordinator.retryAfterFailure()
                }
                .buttonStyle(OnboardingPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("setupRetryButton")
            }
        )
    }
}

// MARK: - Button styles

private struct OnboardingPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(isEnabled ? Color.black : Color.white.opacity(0.4))
            .padding(.horizontal, 26)
            .frame(height: 34)
            .background(
                Capsule(style: .continuous)
                    .fill(isEnabled ? Color.white : Color.white.opacity(0.14))
            )
            .opacity(configuration.isPressed && isEnabled ? 0.75 : 1)
            .animation(.easeInOut(duration: 0.15), value: isEnabled)
    }
}

private struct OnboardingSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 18)
            .frame(height: 34)
            .background(Capsule(style: .continuous).fill(.white.opacity(0.12)))
            .overlay(Capsule(style: .continuous).strokeBorder(.white.opacity(0.16), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
}

// MARK: - Key caps

/// Renders one shortcut component (modifier glyph or key name) as a physical key cap.
private struct KeyCapView: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .frame(minWidth: 28, minHeight: 28)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.20), Color.white.opacity(0.09)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.38), Color.white.opacity(0.12)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
    }
}

/// Splits a shortcut display string (e.g. "⌃⇧D") into key caps.
private struct ShortcutKeyCapsView: View {
    let displayString: String

    var body: some View {
        HStack(spacing: 5) {
            ForEach(Self.tokens(from: displayString), id: \.self) { token in
                KeyCapView(label: token)
            }
        }
        .accessibilityHidden(true)
    }

    static func tokens(from display: String) -> [String] {
        let modifiers: Set<Character> = ["⌃", "⌥", "⇧", "⌘"]
        var rest = Substring(display)
        var tokens: [String] = []
        while let first = rest.first, modifiers.contains(first) {
            tokens.append(String(first))
            rest = rest.dropFirst()
        }
        if !rest.isEmpty {
            tokens.append(String(rest))
        }
        return tokens.isEmpty ? [display] : tokens
    }
}
