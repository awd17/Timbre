import Foundation
@testable import Timbre

@MainActor
final class FakeGlobalShortcutService: GlobalShortcutServicing {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var handler: (() -> Void)?
    var isListening = false
    var displayString: String? = "⌃⇧D"

    func start() {
        startCount += 1
        isListening = true
    }

    func stop() {
        stopCount += 1
        isListening = false
    }

    func setHandler(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    /// Simulates a global key-up without registering a real hotkey.
    func fire() {
        handler?()
    }
}
