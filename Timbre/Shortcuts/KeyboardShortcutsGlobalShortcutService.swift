import Foundation
import KeyboardShortcuts

/// Adapts KeyboardShortcuts 2.4.x to `GlobalShortcutServicing`.
///
/// Uses `onKeyUp` + `removeHandler` (no throwing registration API).
@MainActor
final class KeyboardShortcutsGlobalShortcutService: GlobalShortcutServicing {
    private let name: KeyboardShortcuts.Name
    private var handler: (() -> Void)?
    private var didStart = false
    #if DEBUG
    private var pendingIntegrationBurst: (
        extraInvocations: Int,
        didInvoke: () -> Void
    )?
    #endif

    init(name: KeyboardShortcuts.Name = .toggleDictation) {
        self.name = name
    }

    var isListening: Bool {
        KeyboardShortcuts.isEnabled(for: name)
    }

    var displayString: String {
        DictationShortcutName.displayString(for: name)
    }

    func start() {
        // Idempotent: clear any prior handler for this name before adding one.
        KeyboardShortcuts.removeHandler(for: name)

        KeyboardShortcuts.onKeyUp(for: name) { [weak self] in
            Task { @MainActor in
                self?.handleKeyUp()
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
        KeyboardShortcuts.removeHandler(for: name)
        handler = nil
        didStart = false
        TimbreLog.line("Timbre shortcut: stopped")
    }

    func setHandler(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    private func handleKeyUp() {
        handler?()

        #if DEBUG
        guard let burst = pendingIntegrationBurst else { return }
        pendingIntegrationBurst = nil
        for _ in 0..<burst.extraInvocations {
            handler?()
            burst.didInvoke()
        }
        #endif
    }

    #if DEBUG
    /// Arms extra calls that run synchronously after the next real Carbon key-up.
    /// This lets the UI suite verify busy-state de-duplication without posting
    /// authorization-gated HID events from the XCTest runner.
    func armIntegrationTestBurst(
        extraInvocations: Int,
        didInvoke: @escaping () -> Void
    ) {
        guard extraInvocations > 0 else { return }
        pendingIntegrationBurst = (extraInvocations, didInvoke)
    }

    func invokeKeyUpForUnitTesting() {
        handleKeyUp()
    }
    #endif
}
