import AppKit
import SwiftUI

/// Presents a single first-run setup window. Closing does not cancel model preparation.
@MainActor
final class SetupWindowController: NSObject, NSWindowDelegate {
    private let coordinator: SetupCoordinator
    private var window: NSWindow?
    private let shouldRestoreAccessory: () -> Bool
    /// When true, shortcut step uses KeyboardShortcuts.Recorder; otherwise a simulated control.
    private let usesRealShortcutRecorder: Bool

    init(
        coordinator: SetupCoordinator,
        shouldRestoreAccessory: @escaping () -> Bool,
        usesRealShortcutRecorder: Bool = true
    ) {
        self.coordinator = coordinator
        self.shouldRestoreAccessory = shouldRestoreAccessory
        self.usesRealShortcutRecorder = usesRealShortcutRecorder
        super.init()
    }

    var isVisible: Bool {
        window?.isVisible == true
    }

    func present() {
        coordinator.presentRequestedFromMenu()

        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            coordinator.markWindowVisible(true)
            return
        }

        NSApp.setActivationPolicy(.regular)

        let setupWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 440),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        setupWindow.title = "Timbre"
        setupWindow.titleVisibility = .hidden
        setupWindow.titlebarAppearsTransparent = true
        setupWindow.isMovableByWindowBackground = true
        setupWindow.isReleasedWhenClosed = false
        setupWindow.delegate = self
        setupWindow.contentView = NSHostingView(
            rootView: SetupFlowView(
                coordinator: coordinator,
                usesRealShortcutRecorder: usesRealShortcutRecorder,
                onContinueInBackground: { [weak self] in
                    self?.window?.close()
                },
                onDone: { [weak self] in
                    self?.dismissAfterReady()
                }
            )
            .frame(width: 560, height: 440)
        )
        setupWindow.center()
        setupWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = setupWindow
        coordinator.markWindowVisible(true)
    }

    func dismissAfterReady() {
        coordinator.acknowledgeReadyAndDismiss()
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        coordinator.markWindowVisible(false)
        if shouldRestoreAccessory() {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        coordinator.windowDidBecomeActive()
    }
}
