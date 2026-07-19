import Foundation

/// Thin boundary around a global hotkey backend (KeyboardShortcuts in production).
@MainActor
protocol GlobalShortcutServicing: AnyObject {
    /// Install the key-up handler once (idempotent: must not stack duplicate handlers).
    func start()

    /// Remove handlers and unregister the Carbon hotkey for this name when unused.
    func stop()

    /// Assign the action invoked when the shortcut fires. Call before `start()`.
    func setHandler(_ handler: @escaping () -> Void)

    /// Best-effort observation after start — not a cross-app conflict oracle.
    var isListening: Bool { get }

    /// Symbolic shortcut string for menu hints (e.g. `⌃⇧D`).
    var displayString: String { get }
}
