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
        #endif
    }

    private static func makeTranscriptionService() -> any TranscriptionServicing {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--mock-transcription") {
            return MockTranscriptionService()
        }
        #endif
        return SpeechRecognitionService()
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
