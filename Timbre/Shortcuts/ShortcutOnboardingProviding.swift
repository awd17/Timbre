import Foundation
import KeyboardShortcuts

/// Thin adapter over the named dictation shortcut for onboarding Continue gating and Ready copy.
///
/// Assignment source of truth remains KeyboardShortcuts. Confirmation is a separate onboarding preference.
@MainActor
protocol ShortcutOnboardingProviding: AnyObject {
    var hasAssignedShortcut: Bool { get }
    var displayString: String? { get }
    /// Apply a Recorder `onChange` value so SwiftUI updates immediately.
    func applyRecorderChange(isAssigned: Bool, displayString: String?)
    /// Re-read KeyboardShortcuts storage (e.g. on window activation).
    func refreshFromStorage()
}

@MainActor
@Observable
final class KeyboardShortcutsOnboardingAdapter: ShortcutOnboardingProviding {
    private let name: KeyboardShortcuts.Name
    private var lastAssignedShortcut: KeyboardShortcuts.Shortcut?
    private var settingsRollbackShortcut: KeyboardShortcuts.Shortcut?
    private(set) var hasAssignedShortcut: Bool
    private(set) var displayString: String?

    init(name: KeyboardShortcuts.Name = .toggleDictation) {
        self.name = name
        // Touch the named shortcut so the package default is registered when unset.
        let shortcut = KeyboardShortcuts.getShortcut(for: name)
        self.lastAssignedShortcut = shortcut
        self.hasAssignedShortcut = shortcut != nil
        self.displayString = shortcut?.description
    }

    func applyRecorderChange(isAssigned: Bool, displayString: String?) {
        if isAssigned, let shortcut = KeyboardShortcuts.getShortcut(for: name) {
            lastAssignedShortcut = shortcut
        }
        hasAssignedShortcut = isAssigned
        self.displayString = displayString?.isEmpty == false
            ? displayString
            : (isAssigned ? KeyboardShortcuts.getShortcut(for: name)?.description : nil)
        TimbreLog.line(
            "Timbre onboarding: shortcut changed assigned=\(isAssigned) display=\(self.displayString ?? "not set")"
        )
    }

    func refreshFromStorage() {
        let shortcut = KeyboardShortcuts.getShortcut(for: name)
        if let shortcut {
            lastAssignedShortcut = shortcut
        }
        let effectiveShortcut = shortcut ?? settingsRollbackShortcut
        hasAssignedShortcut = effectiveShortcut != nil
        displayString = effectiveShortcut?.description
    }

    func beginSettingsShortcutEditing() {
        let shortcut = KeyboardShortcuts.getShortcut(for: name)
        if let shortcut {
            lastAssignedShortcut = shortcut
        }
        settingsRollbackShortcut = shortcut ?? lastAssignedShortcut
            ?? DictationShortcutName.recommendedShortcut
        applyRecorderChange(
            isAssigned: shortcut != nil,
            displayString: shortcut?.description
        )
    }

    func applySettingsRecorderChange(_ shortcut: KeyboardShortcuts.Shortcut?) {
        if let shortcut {
            lastAssignedShortcut = shortcut
            settingsRollbackShortcut = shortcut
        }
        let effectiveShortcut = shortcut ?? settingsRollbackShortcut
        applyRecorderChange(
            isAssigned: effectiveShortcut != nil,
            displayString: effectiveShortcut?.description
        )
    }

    func finishSettingsShortcutEditing() {
        defer { settingsRollbackShortcut = nil }

        if let shortcut = KeyboardShortcuts.getShortcut(for: name) {
            lastAssignedShortcut = shortcut
            applyRecorderChange(isAssigned: true, displayString: shortcut.description)
            return
        }

        let restored = settingsRollbackShortcut ?? lastAssignedShortcut
            ?? DictationShortcutName.recommendedShortcut
        KeyboardShortcuts.setShortcut(restored, for: name)
        lastAssignedShortcut = restored
        applyRecorderChange(isAssigned: true, displayString: restored.description)
    }
}
