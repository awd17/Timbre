import AppKit
import SwiftUI

@main
struct TimbreApp: App {
    @NSApplicationDelegateAdaptor(TimbreAppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarDictationView(controller: appDelegate.controller)
        } label: {
            Label("Timbre", systemImage: "waveform")
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class TimbreAppDelegate: NSObject, NSApplicationDelegate {
    let controller: AssistantController

    private var debugWindow: NSWindow?

    override init() {
        controller = AssistantController(transcription: Self.makeTranscriptionService())
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if Self.wantsDebugWindow {
            NSApp.setActivationPolicy(.regular)
        }
        #endif
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        presentDebugWindowIfNeeded()
        ParakeetFixtureGate.runIfRequested(
            arguments: ProcessInfo.processInfo.arguments,
            controller: controller
        )
        #endif
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        controller.prepareForTermination()
        return .terminateNow
    }

    private static func makeTranscriptionService() -> any TranscriptionServicing {
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
                    return ParakeetTranscriptionService(fixtureURL: fixtureURL)
                }
                TimbreLog.line(
                    "Timbre: --parakeet-fixture requested but parakeet-smoke-test.wav is missing from the app bundle; falling back to Apple Speech."
                )
                return SpeechRecognitionService()
            }
            return ParakeetTranscriptionService(audioSource: ParakeetMicrophoneAudioSource())
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
            rootView: MenuBarDictationView(controller: controller)
                .frame(minWidth: 320, minHeight: 220)
        )
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        debugWindow = window
    }
    #endif
}
