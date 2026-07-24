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
    static let recommendedShortcut = KeyboardShortcuts.Shortcut(
        .d,
        modifiers: [.control, .shift]
    )

    @MainActor
    static var displayString: String? {
        displayString(for: .toggleDictation)
    }

    @MainActor
    static func displayString(for name: KeyboardShortcuts.Name) -> String? {
        KeyboardShortcuts.getShortcut(for: name)?.description
    }
}
