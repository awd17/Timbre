import KeyboardShortcuts

/// Named dictation toggle shortcut.
///
/// Temporary pre-release default: Control+Shift+D (`⌃⇧D`).
/// Change the `default:` value here only. First-run onboarding presents
/// `KeyboardShortcuts.Recorder` for confirmation / replacement.
extension KeyboardShortcuts.Name {
    static let toggleDictation = Self(
        "toggleDictation",
        default: DictationShortcutName.recommendedShortcut
    )

    #if DEBUG
    /// Isolated storage used by simulated onboarding so UI tests never change the real shortcut.
    static let simulatedOnboarding = Self("simulatedOnboarding")
    #endif
}

enum DictationShortcutName {
    /// Fallback display when the package has no stored shortcut yet.
    static let temporaryDefaultDisplayString = "⌃⇧D"
    static let recommendedShortcut = KeyboardShortcuts.Shortcut(
        .d,
        modifiers: [.control, .shift]
    )

    @MainActor
    static var displayString: String {
        if let shortcut = KeyboardShortcuts.getShortcut(for: .toggleDictation) {
            return shortcut.description
        }
        return temporaryDefaultDisplayString
    }
}
