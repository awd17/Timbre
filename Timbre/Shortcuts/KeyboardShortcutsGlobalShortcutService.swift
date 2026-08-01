import Foundation
import KeyboardShortcuts

/// Adapts KeyboardShortcuts 2.4.x to `GlobalShortcutServicing`.
///
/// Uses `onKeyUp` + `removeHandler` (no throwing registration API).
@MainActor
final class KeyboardShortcutsGlobalShortcutService: GlobalShortcutServicing {
    private let name: KeyboardShortcuts.Name
    private var handler: ((GlobalShortcutInvocation) -> Void)?
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

    var displayString: String? {
        DictationShortcutName.displayString(for: name)
    }

    func start() {
        // Idempotent: clear any prior handler for this name before adding one.
        KeyboardShortcuts.removeHandler(for: name)

        KeyboardShortcuts.onKeyUp(for: name) { [weak self] in
            let invocation = GlobalShortcutInvocation.now()
            guard let self else { return }
            if Thread.isMainThread {
                // Carbon delivers app event-handler callbacks on the main
                // thread. Run the hotkey action in this turn instead of
                // scheduling an avoidable actor hop.
                MainActor.assumeIsolated {
                    self.handleKeyUp(invocation)
                }
            } else {
                Task { @MainActor [weak self] in
                    self?.handleKeyUp(invocation)
                }
            }
        }
        didStart = true

        if !isListening {
            TimbreLog.line(
                "Timbre shortcut: toggleDictation is not listening after start (shortcut unset or Carbon registration inactive)."
            )
        } else {
            TimbreLog.line("Timbre shortcut: listening for \(displayString ?? "unknown shortcut")")
        }
    }

    func stop() {
        guard didStart else { return }
        KeyboardShortcuts.removeHandler(for: name)
        handler = nil
        didStart = false
        TimbreLog.line("Timbre shortcut: stopped")
    }

    func setHandler(_ handler: @escaping (GlobalShortcutInvocation) -> Void) {
        self.handler = handler
    }

    private func handleKeyUp(_ invocation: GlobalShortcutInvocation) {
        handler?(invocation)

        #if DEBUG
        guard let burst = pendingIntegrationBurst else { return }
        pendingIntegrationBurst = nil
        for _ in 0..<burst.extraInvocations {
            handler?(.now())
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
        handleKeyUp(.now())
    }
    #endif
}
