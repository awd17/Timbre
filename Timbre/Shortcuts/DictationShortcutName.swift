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
    /// Isolated storage used by the full-app integration test.
    static let integrationTestToggleDictation = Self("integrationTestToggleDictation")
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
        displayString(for: .toggleDictation)
    }

    @MainActor
    static func displayString(for name: KeyboardShortcuts.Name) -> String {
        if let shortcut = KeyboardShortcuts.getShortcut(for: name) {
            return shortcut.description
        }
        return temporaryDefaultDisplayString
    }
}
