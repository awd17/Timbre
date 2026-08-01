import Foundation

/// Routes global shortcut presses into setup presentation or `AssistantController`.
@MainActor
final class DictationShortcutCoordinator {
    private let controller: AssistantController
    private let setupCoordinator: SetupCoordinator?
    private let shortcutService: any GlobalShortcutServicing
    private var presentSetup: () -> Void
    private var didStart = false

    init(
        controller: AssistantController,
        setupCoordinator: SetupCoordinator?,
        shortcutService: any GlobalShortcutServicing,
        presentSetup: @escaping () -> Void = {}
    ) {
        self.controller = controller
        self.setupCoordinator = setupCoordinator
        self.shortcutService = shortcutService
        self.presentSetup = presentSetup
    }

    func setPresentSetup(_ presentSetup: @escaping () -> Void) {
        self.presentSetup = presentSetup
    }

    var displayString: String? { shortcutService.displayString }

    var isListening: Bool { shortcutService.isListening }

    func start() {
        guard !didStart else { return }

        shortcutService.setHandler { [weak self] invocation in
            self?.handlePress(invocation: invocation)
        }
        shortcutService.start()
        didStart = true
    }

    func stop() {
        guard didStart else { return }
        shortcutService.stop()
        didStart = false
    }

    /// Invoked by the shortcut service (and unit tests) on each press.
    func handlePress(invocation: GlobalShortcutInvocation = .now()) {
        let setup = DictationShortcutSetupContext.from(setupCoordinator)
        let action = DictationShortcutPolicy.resolve(
            session: controller.sessionState,
            setup: setup
        )

        switch action {
        case .start:
            controller.beginDictationFromShortcut(requestedAt: invocation.requestedAt)
        case .stop:
            Task { await controller.stopDictation(requestedAt: invocation.requestedAt) }
        case .presentSetup:
            presentSetup()
        case .none:
            TimbreLog.line(
                "Timbre shortcut: ignored (session=\(controller.sessionState.statusMessage), setupBlocked=\(setup.blocksDictationUI), installing=\(setup.isInstalling))"
            )
        }
    }

    /// Menu hint reflecting whether the next press would start or stop.
    func menuHintText() -> String? {
        guard didStart, isListening else { return nil }
        let setup = DictationShortcutSetupContext.from(setupCoordinator)
        let action = DictationShortcutPolicy.resolve(
            session: controller.sessionState,
            setup: setup
        )
        guard let chord = displayString else { return nil }
        switch action {
        case .start:
            return "Press \(chord) to start"
        case .stop:
            return "Press \(chord) to stop"
        case .presentSetup:
            return "Press \(chord) to open setup"
        case .none:
            return nil
        }
    }
}
