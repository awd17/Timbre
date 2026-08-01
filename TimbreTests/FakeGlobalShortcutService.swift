import Foundation
@testable import Timbre

@MainActor
final class FakeGlobalShortcutService: GlobalShortcutServicing {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var handler: ((GlobalShortcutInvocation) -> Void)?
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

    func setHandler(_ handler: @escaping (GlobalShortcutInvocation) -> Void) {
        self.handler = handler
    }

    /// Simulates a global key-up without registering a real hotkey.
    func fire(requestedAt: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        handler?(GlobalShortcutInvocation(requestedAt: requestedAt))
    }
}
