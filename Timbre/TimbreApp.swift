import AppKit
import AuthenticationServices
import KeyboardShortcuts
import SwiftUI

@main
struct TimbreApp: App {
    @NSApplicationDelegateAdaptor(TimbreAppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            appDelegate.menuContent
        } label: {
            Image("MenuBarIcon")
                .renderingMode(.template)
                .accessibilityLabel("Timbre")
                .accessibilityIdentifier("timbreStatusItem")
                .background(
                    SettingsOpenActionBridge(
                        coordinator: appDelegate.settingsOpeningCoordinator
                    )
                )
        }
        .menuBarExtraStyle(.menu)

        Settings {
            TimbreSettingsView(
                preferences: appDelegate.appPreferences,
                inputDevices: appDelegate.audioInputDevices,
                playbackController: appDelegate.playbackController,
                controller: appDelegate.controller,
                authentication: appDelegate.authenticationController,
                shortcutState: appDelegate.shortcutState,
                shortcutName: appDelegate.shortcutRecorderName,
                bundleInformation: BundleInformation(),
                onResetOverlayPosition: {
                    appDelegate.dictationIndicatorCoordinator.resetPlacement()
                },
                onResetAllSettings: {
                    appDelegate.resetAllSettings()
                },
                onQuit: {
                    appDelegate.controller.quit()
                },
                onClose: {
                    appDelegate.settingsOpeningCoordinator.settingsWindowWillClose()
                }
            )
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    appDelegate.settingsOpeningCoordinator.open()
                }
                .keyboardShortcut(",")
                .disabled(appDelegate.setupCoordinator?.settingsAreUnlocked == false)
            }
        }
    }
}

@MainActor
final class TimbreAppDelegate: NSObject, NSApplicationDelegate {
    let controller: AssistantController
    let modelManager: any ParakeetModelManaging
    let setupCoordinator: SetupCoordinator?
    let authenticationController: AuthenticationController
    let prewarmCoordinator: ParakeetPrewarmCoordinator?
    let shortcutCoordinator: DictationShortcutCoordinator
    let appPreferences: UserDefaultsAppPreferences
    let audioInputDevices: CoreAudioInputDeviceManager
    let playbackController: DictationPlaybackController
    let dockVisibilityCoordinator: DockVisibilityCoordinator
    let settingsOpeningCoordinator: SettingsOpeningCoordinator
    let dictationIndicatorCoordinator: DictationIndicatorWindowController
    let shortcutState: KeyboardShortcutsOnboardingAdapter
    let shortcutRecorderName: KeyboardShortcuts.Name

    private var debugWindow: NSWindow?
    #if DEBUG
    private var debugWindowCloseDelegate: DebugWindowCloseDelegate?
    #endif
    private var setupWindowController: SetupWindowController?
    private var acceptsDockReopenRequests = false
    #if DEBUG
    private let integrationRuntime: IntegrationTestRuntime?
    #endif

    var menuContent: MenuBarMenuView {
        MenuBarMenuView(
            controller: controller,
            preferences: appPreferences,
            inputDevices: audioInputDevices,
            setupCoordinator: setupCoordinator,
            authentication: authenticationController,
            onOpenSetup: { [weak self] in
                self?.presentSetupWindow()
            },
            onOpenSettings: { [weak self] in
                self?.settingsOpeningCoordinator.open()
            }
        )
    }

    override init() {
        let processInfo = ProcessInfo.processInfo
        let arguments = processInfo.arguments
        let targetProvider = FrontmostApplicationTracker()

        let selectedModelManager: any ParakeetModelManaging
        let selectedSetupCoordinator: SetupCoordinator?
        let selectedTranscription: any TranscriptionServicing
        let selectedDelivery: any TranscriptDeliveryServicing
        let selectedClipboard: any ClipboardServicing
        let selectedShortcutService: any GlobalShortcutServicing
        let selectedShortcutName: KeyboardShortcuts.Name
        let selectedShortcutState: KeyboardShortcutsOnboardingAdapter
        let shouldConfigurePrewarm: Bool
        let isProductionBackendForPrewarm: Bool

        let authenticationController = AuthenticationController()
        self.authenticationController = authenticationController

        #if DEBUG
        let integrationConfiguration = IntegrationTestConfiguration.resolve(
            arguments: arguments,
            environment: processInfo.environment
        )
        let integrationRuntime = integrationConfiguration.map(IntegrationTestRuntime.init)
        self.integrationRuntime = integrationRuntime
        #endif

        let selectedAppPreferences = UserDefaultsAppPreferences(
            defaults: {
                #if DEBUG
                integrationRuntime?.defaults ?? .standard
                #else
                .standard
                #endif
            }()
        )
        let selectedAudioInputDevices = CoreAudioInputDeviceManager(
            preferences: selectedAppPreferences
        )

        #if DEBUG
        if let integrationRuntime {
            TimbreLog.line(
                "Timbre integration: profile=\(integrationRuntime.configuration.profile) scenario=\(integrationRuntime.configuration.scenario.rawValue)"
            )
            selectedModelManager = integrationRuntime.modelManager
            // Integration UI covers onboarding without a live Clerk session.
            selectedSetupCoordinator = SetupCoordinator(
                modelManager: integrationRuntime.modelManager,
                microphone: integrationRuntime.microphone,
                accessibility: integrationRuntime.accessibility,
                preferences: UserDefaultsOnboardingPreferences(
                    defaults: integrationRuntime.defaults
                ),
                shortcutOnboarding: integrationRuntime.shortcutOnboarding,
                authentication: AlwaysAuthenticatedStatus(),
                featureEnabled: true
            )
            selectedTranscription = integrationRuntime.transcription
            selectedDelivery = integrationRuntime.makeDelivery(
                targetProvider: targetProvider,
                preferences: selectedAppPreferences
            )
            selectedClipboard = integrationRuntime.clipboard
            selectedShortcutService = integrationRuntime.shortcutService
            selectedShortcutName = integrationRuntime.shortcutName
            selectedShortcutState = integrationRuntime.shortcutOnboarding
            shouldConfigurePrewarm = true
            isProductionBackendForPrewarm = true
            // The integration UI drives onboarding without a live Clerk session.
            // Plant a signed-in account so the combined welcome + sign-in page
            // renders its signed-in branch (advance via Continue).
            authenticationController._testApplySignedInState(
                user: MeUser(
                    userId: "integration",
                    email: "integration@timbre.test",
                    firstName: "Timbre",
                    lastName: "Integration"
                )
            )
        } else {
            let productionModelManager = ParakeetModelManager()
            let liveAccessibility = AccessibilityPermissionService()
            let setupEnabled = TimbreSetupFeature.isEnabled(arguments: arguments)
            let shortcutState = KeyboardShortcutsOnboardingAdapter()
            selectedModelManager = productionModelManager
            selectedSetupCoordinator = setupEnabled
                ? SetupCoordinator(
                    modelManager: productionModelManager,
                    microphone: MicrophonePermissionService(),
                    accessibility: liveAccessibility,
                    preferences: UserDefaultsOnboardingPreferences(),
                    shortcutOnboarding: shortcutState,
                    authentication: authenticationController,
                    featureEnabled: true
                )
                : nil
            selectedTranscription = Self.makeTranscriptionService(
                modelManager: productionModelManager,
                arguments: arguments,
                inputDevices: selectedAudioInputDevices
            )
            selectedDelivery = Self.makeTranscriptDelivery(
                arguments: arguments,
                targetProvider: targetProvider,
                accessibility: liveAccessibility,
                preferences: selectedAppPreferences
            )
            selectedClipboard = ClipboardService()
            selectedShortcutService = KeyboardShortcutsGlobalShortcutService()
            selectedShortcutName = .toggleDictation
            selectedShortcutState = shortcutState
            shouldConfigurePrewarm = selectedSetupCoordinator != nil
            isProductionBackendForPrewarm = Self.isProductionParakeetBackend(
                arguments: arguments
            )
        }
        #else
        let productionModelManager = ParakeetModelManager()
        let liveAccessibility = AccessibilityPermissionService()
        let shortcutState = KeyboardShortcutsOnboardingAdapter()
        selectedModelManager = productionModelManager
        selectedSetupCoordinator = SetupCoordinator(
            modelManager: productionModelManager,
            microphone: MicrophonePermissionService(),
            accessibility: liveAccessibility,
            preferences: UserDefaultsOnboardingPreferences(),
            shortcutOnboarding: shortcutState,
            authentication: authenticationController,
            featureEnabled: true
        )
        selectedTranscription = Self.makeTranscriptionService(
            modelManager: productionModelManager,
            arguments: arguments,
            inputDevices: selectedAudioInputDevices
        )
        selectedDelivery = FocusedApplicationTextOutputService(
            accessibility: liveAccessibility,
            targetProvider: targetProvider,
            preferences: selectedAppPreferences
        )
        selectedClipboard = ClipboardService()
        selectedShortcutService = KeyboardShortcutsGlobalShortcutService()
        selectedShortcutName = .toggleDictation
        selectedShortcutState = shortcutState
        shouldConfigurePrewarm = true
        isProductionBackendForPrewarm = true
        #endif

        modelManager = selectedModelManager
        setupCoordinator = selectedSetupCoordinator
        shortcutRecorderName = selectedShortcutName
        self.shortcutState = selectedShortcutState
        appPreferences = selectedAppPreferences
        audioInputDevices = selectedAudioInputDevices
        let playbackController = DictationPlaybackController(
            preferences: selectedAppPreferences,
            defaults: selectedAppPreferences.defaults
        )
        self.playbackController = playbackController
        let dockVisibilityCoordinator = DockVisibilityCoordinator(
            preferences: selectedAppPreferences
        )
        self.dockVisibilityCoordinator = dockVisibilityCoordinator
        settingsOpeningCoordinator = SettingsOpeningCoordinator(
            dockVisibilityCoordinator: dockVisibilityCoordinator,
            setupCoordinator: selectedSetupCoordinator
        )
        controller = AssistantController(
            transcription: selectedTranscription,
            clipboard: selectedClipboard,
            delivery: selectedDelivery,
            targetProvider: targetProvider,
            playback: playbackController
        )
        dictationIndicatorCoordinator = DictationIndicatorWindowController(
            controller: controller,
            placementStore: DictationIndicatorPlacementStore(
                defaults: selectedAppPreferences.defaults
            )
        )
        shortcutCoordinator = DictationShortcutCoordinator(
            controller: controller,
            setupCoordinator: selectedSetupCoordinator,
            shortcutService: selectedShortcutService
        )

        if shouldConfigurePrewarm, let selectedSetupCoordinator {
            let prewarmCoordinator = ParakeetPrewarmCoordinator(
                modelManager: selectedModelManager,
                isEligible: { [weak selectedSetupCoordinator] in
                    selectedSetupCoordinator?.allowsDictation == true
                },
                isParakeetProductionBackend: isProductionBackendForPrewarm,
                disablePrewarm: Self.shouldDisableModelPrewarm(arguments: arguments),
                onModelStateChanged: { [weak selectedSetupCoordinator] in
                    selectedSetupCoordinator?.modelPreparationDidChange()
                }
            )
            self.prewarmCoordinator = prewarmCoordinator
            selectedSetupCoordinator.onReadinessChanged = { [weak prewarmCoordinator] _ in
                prewarmCoordinator?.evaluate(source: .setupReadinessChanged)
            }
        } else {
            prewarmCoordinator = nil
        }

        super.init()
        authenticationController.setPresentationAnchorProvider(self)
        authenticationController.onStateDidChange = { [weak self] in
            self?.setupCoordinator?.authenticationDidChange()
        }
        shortcutCoordinator.setPresentSetup { [weak self] in
            self?.presentSetupWindow()
        }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        Self.applyBundledApplicationIcon()
        if setupCoordinator?.shouldAutoPresent == true {
            dockVisibilityCoordinator.beginTemporaryPresentation(.onboarding)
        }
        #if DEBUG
        if Self.wantsDebugWindow || integrationRuntime?.configuration.showsMenuHost == true {
            dockVisibilityCoordinator.beginTemporaryPresentation(.debugWindow)
        }
        #endif
        dockVisibilityCoordinator.applyLaunchPolicy()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        dictationIndicatorCoordinator.start()
        authenticationController.start()

        #if DEBUG
        presentDebugWindowIfNeeded()
        ParakeetFixtureGate.runIfRequested(
            arguments: ProcessInfo.processInfo.arguments,
            controller: controller
        )
        #endif

        if !Self.shouldSkipGlobalShortcut(arguments: ProcessInfo.processInfo.arguments) {
            shortcutCoordinator.start()
        } else {
            TimbreLog.line("Timbre shortcut: skipped (--parakeet-fixture)")
        }

        if let setupCoordinator, setupCoordinator.shouldAutoPresent {
            presentSetupWindow()
        }

        prewarmCoordinator?.evaluate(source: .launchReadiness)

        Task { @MainActor [weak self] in
            // LaunchServices (including Xcode Run) can send a reopen while it
            // activates a newly launched accessory app. Only later Dock
            // reopens should present Settings.
            await Task.yield()
            self?.acceptsDockReopenRequests = true
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        setupCoordinator?.applicationDidBecomeActive()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        shortcutCoordinator.stop()
        dictationIndicatorCoordinator.stop()
        controller.prepareForTermination()
        audioInputDevices.stopMonitoring()
        #if DEBUG
        integrationRuntime?.cleanupPersistentStateIfRequested()
        #endif
        return .terminateNow
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        // During onboarding, reopens (e.g. Dock clicks) should bring the
        // setup window forward instead of opening Settings prematurely.
        if let setupCoordinator, !setupCoordinator.settingsAreUnlocked {
            presentSetupWindow()
            return true
        }
        guard Self.shouldOpenSettingsForReopen(
            acceptsDockReopenRequests: acceptsDockReopenRequests,
            showInDock: appPreferences.showInDock
        ) else {
            return false
        }
        settingsOpeningCoordinator.open()
        return true
    }

    func applicationShouldSaveSecureApplicationState(_ app: NSApplication) -> Bool {
        false
    }

    func applicationShouldRestoreSecureApplicationState(_ app: NSApplication) -> Bool {
        false
    }

    static func shouldOpenSettingsForReopen(
        acceptsDockReopenRequests: Bool,
        showInDock: Bool
    ) -> Bool {
        acceptsDockReopenRequests && showInDock
    }

    func presentSetupWindow() {
        guard let setupCoordinator else { return }
        if setupWindowController == nil {
            setupWindowController = SetupWindowController(
                coordinator: setupCoordinator,
                authentication: authenticationController,
                dockVisibilityCoordinator: dockVisibilityCoordinator,
                shortcutRecorderName: shortcutRecorderName
            )
        }
        setupWindowController?.present()
    }

    func resetAllSettings() {
        guard controller.canStart else { return }
        playbackController.endListening()
        appPreferences.resetUserSettings()
        shortcutState.resetSettingsShortcutToDefault()
        dictationIndicatorCoordinator.resetPlacement()
    }

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

    private static func shouldSkipGlobalShortcut(arguments: [String]) -> Bool {
        #if DEBUG
        return TranscriptionBackendSelection.wantsParakeetFixture(
            arguments: arguments,
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
        if IntegrationTestConfiguration.isRequested(arguments: arguments) {
            return false
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

    private static func makeTranscriptDelivery(
        arguments: [String],
        targetProvider: any DictationTargetProviding,
        accessibility: any AccessibilityPermissionProviding,
        preferences: any AppPreferencesProviding
    ) -> any TranscriptDeliveryServicing {
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
            targetProvider: targetProvider,
            preferences: preferences
        )
    }

    private static func makeTranscriptionService(
        modelManager: ParakeetModelManager,
        arguments: [String],
        inputDevices: CoreAudioInputDeviceManager
    ) -> any TranscriptionServicing {
        #if DEBUG
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
            return ParakeetTranscriptionService(
                audioSource: ParakeetMicrophoneAudioSource(
                    inputDevices: inputDevices
                ),
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
                    "Timbre: --parakeet-fixture requested but parakeet-smoke-test.wav is missing from the app bundle; using microphone Parakeet."
                )
            }
            #endif
            return ParakeetTranscriptionService(
                audioSource: ParakeetMicrophoneAudioSource(
                    inputDevices: inputDevices
                ),
                modelManager: modelManager
            )
        case .appleSpeech:
            #if DEBUG
            return SpeechRecognitionService(inputDevices: inputDevices)
            #else
            return ParakeetTranscriptionService(
                audioSource: ParakeetMicrophoneAudioSource(
                    inputDevices: inputDevices
                ),
                modelManager: modelManager
            )
            #endif
        }
    }

    #if DEBUG
    private static var wantsDebugWindow: Bool {
        ProcessInfo.processInfo.arguments.contains("--debug-window")
    }

    private func presentDebugWindowIfNeeded() {
        let wantsIntegrationHost = integrationRuntime?.configuration.showsMenuHost == true
        guard Self.wantsDebugWindow || wantsIntegrationHost else { return }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 300),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = wantsIntegrationHost ? "Timbre Integration Menu" : "Timbre Debug"
        let closeDelegate = DebugWindowCloseDelegate { [weak self, weak window] in
            guard let self, self.debugWindow === window else { return }
            self.debugWindow = nil
            self.debugWindowCloseDelegate = nil
            self.dockVisibilityCoordinator.endTemporaryPresentation(.debugWindow)
        }
        window.delegate = closeDelegate
        window.contentView = NSHostingView(
            rootView: VStack(alignment: .leading, spacing: 8) {
                menuContent
            }
            .padding()
            .frame(minWidth: 260, minHeight: 160, alignment: .topLeading)
        )
        window.center()
        window.makeKeyAndOrderFront(nil)
        dockVisibilityCoordinator.activate()
        debugWindow = window
        debugWindowCloseDelegate = closeDelegate
    }
    #endif
}

extension TimbreAppDelegate: AuthenticationPresentationAnchorProviding {
    func authenticationPresentationAnchor() -> ASPresentationAnchor {
        if let setupWindow = setupWindowController?.windowForAuthentication {
            return setupWindow
        }
        if let key = NSApp.keyWindow {
            return key
        }
        if let visible = NSApp.windows.first(where: \.isVisible) {
            return visible
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        return window
    }
}

#if DEBUG
@MainActor
final class DebugWindowCloseDelegate: NSObject, NSWindowDelegate {
    private var onClose: (() -> Void)?

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        let action = onClose
        onClose = nil
        action?()
    }
}
#endif
