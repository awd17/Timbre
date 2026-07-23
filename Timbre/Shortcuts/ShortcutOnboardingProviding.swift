import Foundation
import KeyboardShortcuts

/// Thin adapter over the named dictation shortcut for onboarding Continue gating and Ready copy.
///
/// Assignment source of truth remains KeyboardShortcuts. Confirmation is a separate onboarding preference.
@MainActor
protocol ShortcutOnboardingProviding: AnyObject {
    var hasAssignedShortcut: Bool { get }
    var displayString: String { get }
    /// Apply a Recorder `onChange` value so SwiftUI updates immediately.
    func applyRecorderChange(isAssigned: Bool, displayString: String?)
    /// Re-read KeyboardShortcuts storage (e.g. on window activation).
    func refreshFromStorage()
}

@MainActor
@Observable
final class KeyboardShortcutsOnboardingAdapter: ShortcutOnboardingProviding {
    private(set) var hasAssignedShortcut: Bool
    private(set) var displayString: String

    init() {
        // Touch the named shortcut so the package default is registered when unset.
        _ = KeyboardShortcuts.Name.toggleDictation
        let shortcut = KeyboardShortcuts.getShortcut(for: .toggleDictation)
        self.hasAssignedShortcut = shortcut != nil
        self.displayString = shortcut?.description ?? DictationShortcutName.temporaryDefaultDisplayString
    }

    func applyRecorderChange(isAssigned: Bool, displayString: String?) {
        hasAssignedShortcut = isAssigned
        if let displayString, !displayString.isEmpty {
            self.displayString = displayString
        } else if isAssigned, let shortcut = KeyboardShortcuts.getShortcut(for: .toggleDictation) {
            self.displayString = shortcut.description
        } else {
            self.displayString = DictationShortcutName.temporaryDefaultDisplayString
        }
        TimbreLog.line(
            "Timbre onboarding: shortcut changed assigned=\(isAssigned) display=\(self.displayString)"
        )
    }

    func refreshFromStorage() {
        let shortcut = KeyboardShortcuts.getShortcut(for: .toggleDictation)
        hasAssignedShortcut = shortcut != nil
        displayString = shortcut?.description ?? DictationShortcutName.temporaryDefaultDisplayString
    }
}
