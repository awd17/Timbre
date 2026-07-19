import Foundation
import KeyboardShortcuts

/// Adapts KeyboardShortcuts 2.4.x to `GlobalShortcutServicing`.
///
/// Uses `onKeyUp` + `removeHandler` (no throwing registration API).
@MainActor
final class KeyboardShortcutsGlobalShortcutService: GlobalShortcutServicing {
    private var handler: (() -> Void)?
    private var didStart = false

    var isListening: Bool {
        KeyboardShortcuts.isEnabled(for: .toggleDictation)
    }

    var displayString: String {
        DictationShortcutName.displayString
    }

    func start() {
        // Idempotent: clear any prior handler for this name before adding one.
        KeyboardShortcuts.removeHandler(for: .toggleDictation)

        KeyboardShortcuts.onKeyUp(for: .toggleDictation) { [weak self] in
            Task { @MainActor in
                self?.handler?()
            }
        }
        didStart = true

        if !isListening {
            TimbreLog.line(
                "Timbre shortcut: toggleDictation is not listening after start (shortcut unset or Carbon registration inactive)."
            )
        } else {
            TimbreLog.line("Timbre shortcut: listening for \(displayString)")
        }
    }

    func stop() {
        guard didStart else { return }
        KeyboardShortcuts.removeHandler(for: .toggleDictation)
        handler = nil
        didStart = false
        TimbreLog.line("Timbre shortcut: stopped")
    }

    func setHandler(_ handler: @escaping () -> Void) {
        self.handler = handler
    }
}
