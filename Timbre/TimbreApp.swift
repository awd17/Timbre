import AppKit
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

    override init() {
        let modelManager = ParakeetModelManager()
        self.modelManager = modelManager

        let arguments = ProcessInfo.processInfo.arguments
        let setupEnabled = TimbreSetupFeature.isEnabled(arguments: arguments)

        let targetProvider = FrontmostApplicationTracker()
        let accessibility = AccessibilityPermissionService()

        let createdSetupCoordinator: SetupCoordinator?
        if setupEnabled {
            createdSetupCoordinator = SetupCoordinator(
                modelManager: modelManager,
                microphone: MicrophonePermissionService(),
                accessibility: accessibility,
                featureEnabled: true
            )
        } else {
            createdSetupCoordinator = nil
        }
        setupCoordinator = createdSetupCoordinator

        if let createdSetupCoordinator {
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
        }

        controller = AssistantController(
            transcription: Self.makeTranscriptionService(modelManager: modelManager),
            delivery: Self.makeTranscriptDelivery(
                arguments: arguments,
                targetProvider: targetProvider,
                accessibility: accessibility
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
        #if DEBUG
        if Self.wantsDebugWindow {
            NSApp.setActivationPolicy(.regular)
        }
        #endif
        if setupCoordinator?.shouldAutoPresent == true {
            NSApp.setActivationPolicy(.regular)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        presentDebugWindowIfNeeded()
        ParakeetFixtureGate.runIfRequested(
            arguments: ProcessInfo.processInfo.arguments,
            controller: controller
        )
        #endif

        if !Self.shouldSkipGlobalShortcut {
            shortcutCoordinator.start()
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

    private static var shouldSkipGlobalShortcut: Bool {
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
                }
            )
        }
        setupWindowController?.present()
    }

    /// DEBUG mock/fixture/UI paths use clipboard-only delivery so automation never pastes.
    private static func makeTranscriptDelivery(
        arguments: [String],
        targetProvider: any DictationTargetProviding,
        accessibility: any AccessibilityPermissionProviding
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
            targetProvider: targetProvider
        )
    }

    /// Constructs the transcription backend without requesting microphone permission,
    /// downloading files, or loading the model into memory.
    private static func makeTranscriptionService(
        modelManager: ParakeetModelManager
    ) -> any TranscriptionServicing {
        let arguments = ProcessInfo.processInfo.arguments
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
