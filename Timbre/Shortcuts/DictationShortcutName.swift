import KeyboardShortcuts

/// Named dictation toggle shortcut.
///
/// Temporary pre-release default: Control+Shift+D (`⌃⇧D`).
/// Change the `default:` value here only. Onboarding polish must add
/// `KeyboardShortcuts.Recorder` before the first public release.
extension KeyboardShortcuts.Name {
    static let toggleDictation = Self(
        "toggleDictation",
        default: .init(.d, modifiers: [.control, .shift])
    )
}

enum DictationShortcutName {
    /// Fallback display when the package has no stored shortcut yet.
    static let temporaryDefaultDisplayString = "⌃⇧D"

    @MainActor
    static var displayString: String {
        if let shortcut = KeyboardShortcuts.getShortcut(for: .toggleDictation) {
            return shortcut.description
        }
        return temporaryDefaultDisplayString
    }
}
