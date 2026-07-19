import AppKit
import SwiftUI

/// Presents a single first-run setup window. Closing does not cancel model preparation.
@MainActor
final class SetupWindowController: NSObject, NSWindowDelegate {
    private let coordinator: SetupCoordinator
    private var window: NSWindow?
    private let shouldRestoreAccessory: () -> Bool

    init(coordinator: SetupCoordinator, shouldRestoreAccessory: @escaping () -> Bool) {
        self.coordinator = coordinator
        self.shouldRestoreAccessory = shouldRestoreAccessory
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
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        setupWindow.title = "Set Up Timbre"
        setupWindow.isReleasedWhenClosed = false
        setupWindow.delegate = self
        setupWindow.contentView = NSHostingView(
            rootView: SetupFlowView(coordinator: coordinator) { [weak self] in
                self?.dismissAfterReady()
            }
            .frame(minWidth: 380, minHeight: 260)
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
