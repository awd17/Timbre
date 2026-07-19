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

    private static func makeTranscriptionService(
        modelManager: ParakeetModelManager
    ) -> any TranscriptionServicing {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        let resolution = TranscriptionBackendSelection.resolve(arguments: arguments, isDebug: true)
        if resolution.conflictingFlagsIgnoredParakeet {
            TimbreLog.line(
                "Timbre: both \(TranscriptionBackendSelection.mockArgument) and \(TranscriptionBackendSelection.parakeetArgument) set; using mock transcription."
            )
        }
        TimbreLog.line("Timbre transcription backend: \(resolution.backend.logName)")

        switch resolution.backend {
        case .mock:
            return MockTranscriptionService()
        case .parakeet:
            if TranscriptionBackendSelection.wantsParakeetFixture(arguments: arguments, isDebug: true) {
                if let fixtureURL = ParakeetTranscriptionService.defaultFixtureURL() {
                    TimbreLog.line("Timbre Parakeet: using fixture \(fixtureURL.path)")
                    return ParakeetTranscriptionService(
                        fixtureURL: fixtureURL,
                        modelManager: modelManager
                    )
                }
                TimbreLog.line(
                    "Timbre: --parakeet-fixture requested but parakeet-smoke-test.wav is missing from the app bundle; falling back to Apple Speech."
                )
                return SpeechRecognitionService()
            }
            return ParakeetTranscriptionService(
                audioSource: ParakeetMicrophoneAudioSource(),
                modelManager: modelManager
            )
        case .appleSpeech:
            return SpeechRecognitionService()
        }
        #else
        return SpeechRecognitionService()
        #endif
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
