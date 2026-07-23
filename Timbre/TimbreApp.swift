import AppKit
import KeyboardShortcuts
import SwiftUI

@main
struct TimbreApp: App {
    @NSApplicationDelegateAdaptor(TimbreAppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarDictationView(
                controller: appDelegate.controller,
                setupCoordinator: appDelegate.setupCoordinator,
                shortcutCoordinator: appDelegate.shortcutCoordinator,
                onOpenSetup: {
                    appDelegate.presentSetupWindow()
                }
            )
        } label: {
            Label("Timbre", systemImage: "waveform")
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class TimbreAppDelegate: NSObject, NSApplicationDelegate {
    let controller: AssistantController
    let modelManager: ParakeetModelManager
    let setupCoordinator: SetupCoordinator?
    let prewarmCoordinator: ParakeetPrewarmCoordinator?
    let shortcutCoordinator: DictationShortcutCoordinator

    private var debugWindow: NSWindow?
    private var setupWindowController: SetupWindowController?
    private let usesRealShortcutRecorder: Bool
    private let isSimulatedOnboarding: Bool

    override init() {
        let arguments = ProcessInfo.processInfo.arguments
#if DEBUG
        let simulating = SimulatedOnboarding.isEnabled(arguments: arguments)
        let simConfig = SimulatedOnboarding.configuration(arguments: arguments)
#else
        let simulating = false
#endif
        isSimulatedOnboarding = simulating
#if DEBUG
        usesRealShortcutRecorder = simulating ? simConfig.useRealRecorder : true
#else
        usesRealShortcutRecorder = true
#endif

        let modelManager = ParakeetModelManager()
        self.modelManager = modelManager

        let setupEnabled = TimbreSetupFeature.isEnabled(arguments: arguments)

        let targetProvider = FrontmostApplicationTracker()
        let liveAccessibility = AccessibilityPermissionService()

        let createdSetupCoordinator: SetupCoordinator?
        if setupEnabled {
#if DEBUG
            if simulating {
                TimbreLog.line(
                    "Timbre onboarding: SIMULATED mode duration=\(simConfig.durationSeconds)s failOnce=\(simConfig.failOnce) realRecorder=\(simConfig.useRealRecorder)"
                )
                let preferences = Self.makeSimulatedPreferences(config: simConfig)
                if !simConfig.useRealRecorder {
                    let simulatedShortcut: KeyboardShortcuts.Shortcut? =
                        simConfig.initialStep == "shortcut-empty"
                        ? nil
                        : DictationShortcutName.recommendedShortcut
                    KeyboardShortcuts.setShortcut(
                        simulatedShortcut,
                        for: .simulatedOnboarding
                    )
                }
                let shortcut: any ShortcutOnboardingProviding = simConfig.useRealRecorder
                    ? KeyboardShortcutsOnboardingAdapter()
                    : SimulatedShortcutOnboarding(
                        hasAssignedShortcut: simConfig.initialStep != "shortcut-empty",
                        displayString: DictationShortcutName.temporaryDefaultDisplayString
                    )
                let (mic, ax, model) = Self.makeSimulatedPermissionAndModel(config: simConfig)
                createdSetupCoordinator = SetupCoordinator(
                    modelManager: model,
                    microphone: mic,
                    accessibility: ax,
                    preferences: preferences,
                    shortcutOnboarding: shortcut,
                    featureEnabled: true
                )
            } else {
                createdSetupCoordinator = SetupCoordinator(
                    modelManager: modelManager,
                    microphone: MicrophonePermissionService(),
                    accessibility: liveAccessibility,
                    featureEnabled: true
                )
            }
#else
            createdSetupCoordinator = SetupCoordinator(
                modelManager: modelManager,
                microphone: MicrophonePermissionService(),
                accessibility: liveAccessibility,
                featureEnabled: true
            )
#endif
        } else {
            createdSetupCoordinator = nil
        }
        setupCoordinator = createdSetupCoordinator

        if let createdSetupCoordinator, !simulating {
            let prewarmCoordinator = ParakeetPrewarmCoordinator(
                modelManager: modelManager,
                isEligible: { [weak createdSetupCoordinator] in
                    createdSetupCoordinator?.allowsDictation == true
                },
                isParakeetProductionBackend: Self.isProductionParakeetBackend(
                    arguments: arguments
                ),
                disablePrewarm: Self.shouldDisableModelPrewarm(arguments: arguments),
                onModelStateChanged: { [weak createdSetupCoordinator] in
                    createdSetupCoordinator?.modelPreparationDidChange()
                }
            )
            self.prewarmCoordinator = prewarmCoordinator
            createdSetupCoordinator.onReadinessChanged = { [weak prewarmCoordinator] _ in
                prewarmCoordinator?.evaluate(source: .setupReadinessChanged)
            }
        } else {
            prewarmCoordinator = nil
            if simulating {
                TimbreLog.line("Timbre onboarding: SIMULATED mode disables real model prewarming")
            }
        }

        let deliveryAccessibility: any AccessibilityPermissionProviding
#if DEBUG
        if simulating {
            deliveryAccessibility = SimulatedAccessibilityPermission(trustState: .trusted)
        } else {
            deliveryAccessibility = liveAccessibility
        }
#else
        deliveryAccessibility = liveAccessibility
#endif

        controller = AssistantController(
            transcription: Self.makeTranscriptionService(
                modelManager: modelManager,
                arguments: arguments,
                simulating: simulating
            ),
            delivery: Self.makeTranscriptDelivery(
                arguments: arguments,
                targetProvider: targetProvider,
                accessibility: deliveryAccessibility,
                simulating: simulating
            ),
            targetProvider: targetProvider
        )

        shortcutCoordinator = DictationShortcutCoordinator(
            controller: controller,
            setupCoordinator: setupCoordinator,
            shortcutService: KeyboardShortcutsGlobalShortcutService()
        )
        super.init()

        shortcutCoordinator.setPresentSetup { [weak self] in
            self?.presentSetupWindow()
        }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        Self.applyBundledApplicationIcon()
        #if DEBUG
        if Self.wantsDebugWindow {
            NSApp.setActivationPolicy(.regular)
        }
        #endif
        if setupCoordinator?.shouldAutoPresent == true {
            NSApp.setActivationPolicy(.regular)
        }
    }

    /// Explicitly applies the asset-catalog icon so Xcode and Launch Services do not
    /// keep showing the generic executable icon for this menu-bar-first app.
    private static func applyBundledApplicationIcon() {
        guard
            let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
            let icon = NSImage(contentsOf: iconURL)
        else {
            TimbreLog.line("Timbre icon: bundled AppIcon.icns is missing")
            return
        }

        NSApp.applicationIconImage = icon
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        presentDebugWindowIfNeeded()
        ParakeetFixtureGate.runIfRequested(
            arguments: ProcessInfo.processInfo.arguments,
            controller: controller
        )
        #endif

        if !Self.shouldSkipGlobalShortcut(simulating: isSimulatedOnboarding) {
            shortcutCoordinator.start()
        } else if isSimulatedOnboarding {
            TimbreLog.line("Timbre shortcut: skipped (simulated onboarding)")
        } else {
            TimbreLog.line("Timbre shortcut: skipped (--parakeet-fixture)")
        }

        if let setupCoordinator, setupCoordinator.shouldAutoPresent {
            presentSetupWindow()
        }

        prewarmCoordinator?.evaluate(source: .launchReadiness)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        setupCoordinator?.applicationDidBecomeActive()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        shortcutCoordinator.stop()
        controller.prepareForTermination()
        return .terminateNow
    }

    private static func shouldSkipGlobalShortcut(simulating: Bool) -> Bool {
        if simulating { return true }
        #if DEBUG
        return TranscriptionBackendSelection.wantsParakeetFixture(
            arguments: ProcessInfo.processInfo.arguments,
            isDebug: true
        )
        #else
        return false
        #endif
    }

    private static func isProductionParakeetBackend(arguments: [String]) -> Bool {
#if DEBUG
        let isDebug = true
#else
        let isDebug = false
#endif
        let resolution = TranscriptionBackendSelection.resolve(
            arguments: arguments,
            isDebug: isDebug
        )
        guard resolution.backend == .parakeet else { return false }
        return !TranscriptionBackendSelection.wantsParakeetFixture(
            arguments: arguments,
            isDebug: isDebug
        )
    }

    private static func shouldDisableModelPrewarm(arguments: [String]) -> Bool {
#if DEBUG
        if SimulatedOnboarding.isEnabled(arguments: arguments) {
            return true
        }
        let isDebug = true
#else
        let isDebug = false
#endif
        return ParakeetPrewarmCoordinator.shouldDisablePrewarm(
            arguments: arguments,
            isDebug: isDebug
        )
    }

    func presentSetupWindow() {
        guard let setupCoordinator else { return }
        if setupWindowController == nil {
            setupWindowController = SetupWindowController(
                coordinator: setupCoordinator,
                shouldRestoreAccessory: { [weak self] in
                    #if DEBUG
                    if Self.wantsDebugWindow { return false }
                    #endif
                    return self?.debugWindow?.isVisible != true
                },
                usesRealShortcutRecorder: usesRealShortcutRecorder
            )
        }
        setupWindowController?.present()
    }

    /// DEBUG mock/fixture/UI paths use clipboard-only delivery so automation never pastes.
    private static func makeTranscriptDelivery(
        arguments: [String],
        targetProvider: any DictationTargetProviding,
        accessibility: any AccessibilityPermissionProviding,
        simulating: Bool
    ) -> any TranscriptDeliveryServicing {
        if simulating {
            return ClipboardOnlyTranscriptDelivery()
        }
#if DEBUG
        let isDebug = true
#else
        let isDebug = false
#endif
        let setupEnabled = TimbreSetupFeature.isEnabled(arguments: arguments, isDebug: isDebug)
        if !setupEnabled {
            return ClipboardOnlyTranscriptDelivery()
        }
        return FocusedApplicationTextOutputService(
            accessibility: accessibility,
            targetProvider: targetProvider
        )
    }

    /// Constructs the transcription backend without requesting microphone permission,
    /// downloading files, or loading the model into memory.
    private static func makeTranscriptionService(
        modelManager: ParakeetModelManager,
        arguments: [String],
        simulating: Bool
    ) -> any TranscriptionServicing {
#if DEBUG
        if simulating {
            TimbreLog.line("Timbre transcription backend: mock (simulated onboarding)")
            return MockTranscriptionService()
        }
        let isDebug = true
#else
        let isDebug = false
#endif
        let resolution = TranscriptionBackendSelection.resolve(
            arguments: arguments,
            isDebug: isDebug
        )

        if resolution.deprecatedParakeetFlagPresent {
            TimbreLog.line(
                "Timbre: \(TranscriptionBackendSelection.parakeetArgument) is deprecated; Parakeet is already the default."
            )
        }
        if let winner = resolution.conflictWinner {
            TimbreLog.line(
                "Timbre: conflicting transcription flags; using \(winner.logName) priority (\(resolution.backend.logName))."
            )
        }
        TimbreLog.line("Timbre transcription backend: \(resolution.backend.logName)")

        switch resolution.backend {
        case .mock:
#if DEBUG
            return MockTranscriptionService()
#else
            // Unreachable: Release resolve always returns .parakeet.
            return ParakeetTranscriptionService(
                audioSource: ParakeetMicrophoneAudioSource(),
                modelManager: modelManager
            )
#endif
        case .parakeet:
#if DEBUG
            if TranscriptionBackendSelection.wantsParakeetFixture(
                arguments: arguments,
                isDebug: true
            ) {
                if let fixtureURL = ParakeetTranscriptionService.defaultFixtureURL() {
                    TimbreLog.line("Timbre Parakeet: using fixture \(fixtureURL.path)")
                    return ParakeetTranscriptionService(
                        fixtureURL: fixtureURL,
                        modelManager: modelManager
                    )
                }
                TimbreLog.line(
                    "Timbre: --parakeet-fixture requested but parakeet-smoke-test.wav is missing from the app bundle; using microphone Parakeet (no Apple Speech fallback)."
                )
            }
#endif
            return ParakeetTranscriptionService(
                audioSource: ParakeetMicrophoneAudioSource(),
                modelManager: modelManager
            )
        case .appleSpeech:
#if DEBUG
            return SpeechRecognitionService()
#else
            // Unreachable: Release resolve always returns .parakeet.
            return ParakeetTranscriptionService(
                audioSource: ParakeetMicrophoneAudioSource(),
                modelManager: modelManager
            )
#endif
        }
    }

#if DEBUG
    private static func makeSimulatedPreferences(
        config: SimulatedOnboarding.Configuration
    ) -> InMemoryOnboardingPreferences {
        switch config.initialStep {
        case "shortcut", "shortcut-empty":
            return InMemoryOnboardingPreferences(completedWelcome: true)
        case "microphone",
             "microphone-denied",
             "accessibility",
             "text-insertion",
             "accessibility-denied",
             "preparing",
             "ready",
             "failed":
            return InMemoryOnboardingPreferences(
                completedWelcome: true,
                completedShortcutOnboarding: true
            )
        default:
            return InMemoryOnboardingPreferences()
        }
    }

    private static func makeSimulatedPermissionAndModel(
        config: SimulatedOnboarding.Configuration
    ) -> (
        SimulatedMicrophonePermission,
        SimulatedAccessibilityPermission,
        SimulatedParakeetModelManager
    ) {
        switch config.initialStep {
        case "microphone":
            return (
                SimulatedMicrophonePermission(status: .undetermined),
                SimulatedAccessibilityPermission(trustState: .trusted),
                SimulatedParakeetModelManager(
                    initialState: .notInstalled,
                    durationSeconds: config.durationSeconds,
                    failOnce: config.failOnce
                )
            )
        case "microphone-denied":
            return (
                SimulatedMicrophonePermission(status: .denied),
                SimulatedAccessibilityPermission(trustState: .trusted),
                SimulatedParakeetModelManager(
                    initialState: .installed,
                    durationSeconds: config.durationSeconds,
                    failOnce: config.failOnce
                )
            )
        case "accessibility", "text-insertion":
            return (
                SimulatedMicrophonePermission(status: .granted),
                SimulatedAccessibilityPermission(trustState: .notTrusted),
                SimulatedParakeetModelManager(
                    initialState: .installed,
                    durationSeconds: config.durationSeconds,
                    failOnce: config.failOnce
                )
            )
        case "accessibility-denied":
            return (
                SimulatedMicrophonePermission(status: .granted),
                SimulatedAccessibilityPermission(
                    trustState: .notTrusted,
                    hasOfferedPrompt: true
                ),
                SimulatedParakeetModelManager(
                    initialState: .installed,
                    durationSeconds: config.durationSeconds,
                    failOnce: config.failOnce
                )
            )
        case "preparing":
            return (
                SimulatedMicrophonePermission(status: .granted),
                SimulatedAccessibilityPermission(trustState: .trusted),
                SimulatedParakeetModelManager(
                    initialState: .notInstalled,
                    durationSeconds: config.durationSeconds,
                    failOnce: config.failOnce
                )
            )
        case "ready":
            return (
                SimulatedMicrophonePermission(status: .granted),
                SimulatedAccessibilityPermission(trustState: .trusted),
                SimulatedParakeetModelManager(
                    initialState: .installed,
                    durationSeconds: config.durationSeconds,
                    failOnce: false
                )
            )
        case "failed":
            return (
                SimulatedMicrophonePermission(status: .granted),
                SimulatedAccessibilityPermission(trustState: .trusted),
                SimulatedParakeetModelManager(
                    initialState: .failed(message: "Something went wrong while getting Timbre ready."),
                    durationSeconds: config.durationSeconds,
                    failOnce: false
                )
            )
        default:
            return (
                SimulatedMicrophonePermission(status: .granted),
                SimulatedAccessibilityPermission(trustState: .trusted),
                SimulatedParakeetModelManager(
                    initialState: .notInstalled,
                    durationSeconds: config.durationSeconds,
                    failOnce: config.failOnce
                )
            )
        }
    }

    private static var wantsDebugWindow: Bool {
        ProcessInfo.processInfo.arguments.contains("--debug-window")
    }

    private func presentDebugWindowIfNeeded() {
        guard Self.wantsDebugWindow else { return }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 280),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Timbre Debug"
        window.contentView = NSHostingView(
            rootView: MenuBarDictationView(
                controller: controller,
                setupCoordinator: nil,
                shortcutCoordinator: shortcutCoordinator,
                onOpenSetup: nil
            )
            .frame(minWidth: 320, minHeight: 220)
        )
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        debugWindow = window
    }
#endif
}
