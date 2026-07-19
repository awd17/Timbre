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

    private var debugWindow: NSWindow?
    private var setupWindowController: SetupWindowController?

    override init() {
        let modelManager = ParakeetModelManager()
        self.modelManager = modelManager

        let arguments = ProcessInfo.processInfo.arguments
        let setupEnabled = TimbreSetupFeature.isEnabled(arguments: arguments)

        if setupEnabled {
            setupCoordinator = SetupCoordinator(
                modelManager: modelManager,
                microphone: MicrophonePermissionService(),
                featureEnabled: true
            )
        } else {
            setupCoordinator = nil
        }

        controller = AssistantController(
            transcription: Self.makeTranscriptionService(modelManager: modelManager)
        )
        super.init()
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

        if let setupCoordinator, setupCoordinator.shouldAutoPresent {
            presentSetupWindow()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        setupCoordinator?.applicationDidBecomeActive()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        controller.prepareForTermination()
        return .terminateNow
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
