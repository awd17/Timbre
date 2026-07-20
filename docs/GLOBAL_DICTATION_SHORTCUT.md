# Global dictation shortcut

Developer notes for Timbre’s system-wide Start/Stop hotkey.

## Status

- Toggle hotkey is wired through `DictationShortcutCoordinator` into the existing `AssistantController` workflow.
- Temporary pre-release default: **Control+Shift+D** (`⌃⇧D`).
- Completed transcripts are copied to the clipboard and inserted into the captured target when safe (see [`FOCUSED_APP_TEXT_INSERTION.md`](FOCUSED_APP_TEXT_INSERTION.md)).
- Shortcut customization UI is **not** implemented.
- Before the first public release, the onboarding-polish PR **must** add `KeyboardShortcuts.Recorder` so the user can confirm or choose the shortcut.

## Temporary default

| Candidate | Verdict |
|-----------|---------|
| Right ⌘ + Right ⌥ | Not Carbon-registerable |
| ⌘Space | Spotlight |
| ⌃Space | Input Sources |
| ⌃⌥… | VoiceOver modifier / actions |
| ⌘⌥Space | Finder search window |
| ⌃⌘Space | Emoji & Symbols |
| ⌃⇧Space | Trackpad Handwriting / input-source Space family |
| **⌃⇧D** | Selected temporary default |

Change the temporary default in one place:

```swift
// Timbre/Shortcuts/DictationShortcutName.swift
extension KeyboardShortcuts.Name {
    static let toggleDictation = Self(
        "toggleDictation",
        default: .init(.d, modifiers: [.control, .shift])
    )
}
```

KeyboardShortcuts persists the value in `UserDefaults` under `KeyboardShortcuts_toggleDictation`. Changing `default:` does not override an already-stored value. During development:

```swift
KeyboardShortcuts.reset(.toggleDictation)
```

## Toggle behavior

```text
Idle / Completed / Failed → Start
Listening → Stop
Preparing / Processing → ignored
Setup installing → ignored
Setup required / failed → present setup window
```

Menu Start/Stop call the same controller methods.

## Architecture

```text
KeyboardShortcuts (Carbon RegisterEventHotKey)
  → KeyboardShortcutsGlobalShortcutService
  → DictationShortcutCoordinator
  → AssistantController / presentSetupWindow
```

Package: [sindresorhus/KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) **2.4.0** (3.x needs Swift tools 6.2; this project uses 2.4.0).

Service APIs match the package: `onKeyUp` + `removeHandler` + `isEnabled(for:)` + `getShortcut(for:)`. Registration does not throw. There is no automatic cross-app conflict detection in this PR.

## Conflicts

- Manual verification confirms the temporary default fires globally when no other app owns the chord.
- Future `KeyboardShortcuts.Recorder` can warn about system and menu conflicts during onboarding.
- This PR does not promise detecting when another application has registered the same global combination.

## Testing

### Unit

```bash
xcodebuild -scheme Timbre -destination 'platform=macOS' -only-testing:TimbreTests test
```

Uses `FakeGlobalShortcutService` — no real system hotkeys.

### Manual (required for global behavior)

1. Build Debug and Release.
2. Launch Timbre; complete setup if needed.
3. Focus TextEdit; press ⌃⇧D → Preparing/Listening without opening the menu.
4. Speak; press ⌃⇧D again → Processing → text inserted into TextEdit (and still on clipboard).
5. Confirm clipboard still holds the transcript; Copy Again does not paste again.
6. Start a second session via the hotkey (model reuse).
7. Mash during Processing → no overlapping session.
8. Switch apps during Processing → no paste into the newly active app; transcript remains on clipboard.
9. Reset setup → hotkey does not bypass onboarding.
10. Close setup during download → hotkey no-ops; download continues.
11. Menu Start/Stop still behave the same (menu path may briefly reactivate the captured target).
12. DEBUG `--mock-transcription` toggle works without posting real paste events.
13. `--parakeet-fixture` skips global shortcut registration.

## Related

- Focused-app insertion: [`FOCUSED_APP_TEXT_INSERTION.md`](FOCUSED_APP_TEXT_INSERTION.md).
- Next PR: reduce slow first-Start latency (model prewarming).
- Later: onboarding polish with `KeyboardShortcuts.Recorder`.
