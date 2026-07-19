import Foundation

/// Action taken when the global dictation shortcut is pressed.
enum DictationShortcutAction: Equatable {
    case start
    case stop
    case presentSetup
    case none
}

/// Setup facts needed for shortcut policy (avoids importing model-management details).
struct DictationShortcutSetupContext: Equatable {
    var allowsDictation: Bool
    var blocksDictationUI: Bool
    var isInstalling: Bool
    var isSetupFailed: Bool

    /// When setup feature is off (`SetupCoordinator` is nil).
    static let unrestricted = DictationShortcutSetupContext(
        allowsDictation: true,
        blocksDictationUI: false,
        isInstalling: false,
        isSetupFailed: false
    )

    @MainActor
    static func from(_ coordinator: SetupCoordinator?) -> DictationShortcutSetupContext {
        guard let coordinator else { return .unrestricted }
        let state = coordinator.modelState
        let failed: Bool
        if case .failed = state {
            failed = true
        } else {
            failed = false
        }
        return DictationShortcutSetupContext(
            allowsDictation: coordinator.allowsDictation,
            blocksDictationUI: coordinator.blocksDictationUI,
            isInstalling: state.isInstalling,
            isSetupFailed: failed
        )
    }
}

enum DictationShortcutPolicy {
    /// Deterministic mapping from setup readiness + session phase to one shortcut action.
    static func resolve(
        session: SessionState,
        setup: DictationShortcutSetupContext
    ) -> DictationShortcutAction {
        if setup.blocksDictationUI {
            if setup.isInstalling {
                return .none
            }
            if setup.isSetupFailed {
                return .presentSetup
            }
            return .presentSetup
        }

        guard setup.allowsDictation else {
            return .none
        }

        switch session {
        case .idle, .completed, .failed:
            return .start
        case .listening:
            return .stop
        case .preparing, .finishing:
            return .none
        }
    }
}
