import AppKit
import KeyboardShortcuts
import SwiftUI

/// Presents a single first-run setup window. Closing does not cancel model preparation.
@MainActor
final class SetupWindowController: NSObject, NSWindowDelegate {
    private let coordinator: SetupCoordinator
    private var window: NSWindow?
    private let dockVisibilityCoordinator: DockVisibilityCoordinator
    private let shortcutRecorderName: KeyboardShortcuts.Name

    init(
        coordinator: SetupCoordinator,
        dockVisibilityCoordinator: DockVisibilityCoordinator,
        shortcutRecorderName: KeyboardShortcuts.Name = .toggleDictation
    ) {
        self.coordinator = coordinator
        self.dockVisibilityCoordinator = dockVisibilityCoordinator
        self.shortcutRecorderName = shortcutRecorderName
        super.init()
    }

    var isVisible: Bool {
        window?.isVisible == true
    }

    func present() {
        coordinator.presentRequestedFromMenu()
        dockVisibilityCoordinator.beginTemporaryPresentation(.onboarding)

        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            dockVisibilityCoordinator.activate()
            coordinator.markWindowVisible(true)
            return
        }

        let setupWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 460),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        setupWindow.title = "Timbre"
        setupWindow.titleVisibility = .hidden
        setupWindow.titlebarAppearsTransparent = true
        setupWindow.titlebarSeparatorStyle = .none
        setupWindow.isMovableByWindowBackground = true
        setupWindow.isReleasedWhenClosed = false
        // Prevent the default light window chrome from showing as a bottom strip
        // when full-size SwiftUI content does not perfectly cover the content view.
        setupWindow.backgroundColor = .black
        setupWindow.isOpaque = true
        setupWindow.hasShadow = true
        setupWindow.delegate = self
        let hostingView = NSHostingView(
            rootView: SetupFlowView(
                coordinator: coordinator,
                shortcutRecorderName: shortcutRecorderName,
                onContinueInBackground: { [weak self] in
                    self?.coordinator.continuePreparationInBackground()
                    self?.window?.close()
                },
                onDone: { [weak self] in
                    self?.dismissAfterReady()
                }
            )
            .frame(width: 600, height: 460)
        )
        // Keep the window's authored size; the flow view stretches to fill it,
        // including under the transparent title bar.
        hostingView.sizingOptions = []
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.black.cgColor
        setupWindow.contentView = hostingView
        // Ensure the hosting view fills the entire content view (no 1pt gray gaps).
        hostingView.translatesAutoresizingMaskIntoConstraints = true
        hostingView.autoresizingMask = [.width, .height]
        setupWindow.center()
        #if DEBUG
        if let contentView = setupWindow.contentView {
            TimbreLog.line(
                "debug window frame=\(setupWindow.frame) contentView=\(contentView.frame) layoutRect=\(setupWindow.contentLayoutRect)"
            )
        }
        #endif
        setupWindow.makeKeyAndOrderFront(nil)
        dockVisibilityCoordinator.activate()
        window = setupWindow
        coordinator.markWindowVisible(true)
    }

    func dismissAfterReady() {
        coordinator.acknowledgeReadyAndDismiss()
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        coordinator.markWindowVisible(false)
        dockVisibilityCoordinator.endTemporaryPresentation(.onboarding)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        coordinator.windowDidBecomeActive()
    }
}
