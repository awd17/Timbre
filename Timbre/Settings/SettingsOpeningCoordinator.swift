import AppKit
import SwiftUI

@MainActor
final class SettingsOpeningCoordinator {
    private let dockVisibilityCoordinator: DockVisibilityCoordinator
    /// First-run setup coordinator, if any. While its onboarding flow (including
    /// the download phase and the "ready" window) has not finished, Settings
    /// stays hidden so users can't change things mid-setup.
    private weak var setupCoordinator: SetupCoordinator?
    private var openAction: (() -> Void)?
    private var hasPendingOpen = false

    init(
        dockVisibilityCoordinator: DockVisibilityCoordinator,
        setupCoordinator: SetupCoordinator? = nil
    ) {
        self.dockVisibilityCoordinator = dockVisibilityCoordinator
        self.setupCoordinator = setupCoordinator
    }

    /// True when the Settings UI is allowed to appear right now.
    var canOpenSettings: Bool {
        setupCoordinator?.settingsAreUnlocked ?? true
    }

    func install(openAction: @escaping () -> Void) {
        self.openAction = openAction
        guard hasPendingOpen else { return }
        hasPendingOpen = false
        open()
    }

    func open() {
        guard canOpenSettings else {
            TimbreLog.line("Timbre: settings open suppressed until setup is complete")
            return
        }
        guard let openAction else {
            hasPendingOpen = true
            return
        }
        dockVisibilityCoordinator.beginTemporaryPresentation(.settingsWindow)
        dockVisibilityCoordinator.activate()
        openAction()
    }

    func settingsWindowWillClose() {
        dockVisibilityCoordinator.endTemporaryPresentation(.settingsWindow)
    }
}

struct SettingsOpenActionBridge: View {
    @Environment(\.openSettings) private var openSettings
    let coordinator: SettingsOpeningCoordinator

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                coordinator.install {
                    openSettings()
                }
            }
    }
}

struct SettingsWindowLifecycleObserver: NSViewRepresentable {
    let onClose: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onClose: onClose)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.attachWhenAvailable(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onClose = onClose
        context.coordinator.attachWhenAvailable(to: nsView)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stopObserving()
    }

    @MainActor
    final class Coordinator {
        var onClose: () -> Void
        private weak var observedWindow: NSWindow?
        private var observer: NSObjectProtocol?

        init(onClose: @escaping () -> Void) {
            self.onClose = onClose
        }

        func attachWhenAvailable(to view: NSView) {
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let window = view?.window else { return }
                self.observe(window)
            }
        }

        private func observe(_ window: NSWindow) {
            guard observedWindow !== window else { return }
            stopObserving()
            observedWindow = window
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.onClose()
                    self?.stopObserving()
                }
            }
        }

        func stopObserving() {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
            observer = nil
            observedWindow = nil
        }
    }
}
