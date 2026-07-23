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
    private let name: KeyboardShortcuts.Name
    private(set) var hasAssignedShortcut: Bool
    private(set) var displayString: String

    init(name: KeyboardShortcuts.Name = .toggleDictation) {
        self.name = name
        // Touch the named shortcut so the package default is registered when unset.
        let shortcut = KeyboardShortcuts.getShortcut(for: name)
        self.hasAssignedShortcut = shortcut != nil
        self.displayString = shortcut?.description ?? DictationShortcutName.temporaryDefaultDisplayString
    }

    func applyRecorderChange(isAssigned: Bool, displayString: String?) {
        hasAssignedShortcut = isAssigned
        if let displayString, !displayString.isEmpty {
            self.displayString = displayString
        } else if isAssigned, let shortcut = KeyboardShortcuts.getShortcut(for: name) {
            self.displayString = shortcut.description
        } else {
            self.displayString = DictationShortcutName.temporaryDefaultDisplayString
        }
        TimbreLog.line(
            "Timbre onboarding: shortcut changed assigned=\(isAssigned) display=\(self.displayString)"
        )
    }

    func refreshFromStorage() {
        let shortcut = KeyboardShortcuts.getShortcut(for: name)
        hasAssignedShortcut = shortcut != nil
        displayString = shortcut?.description ?? DictationShortcutName.temporaryDefaultDisplayString
    }
}
