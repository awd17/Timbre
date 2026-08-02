# Global dictation shortcut

Developer notes for Timbre’s system-wide Start/Stop hotkey.

## Status

- Toggle hotkey is wired through `DictationShortcutCoordinator` into the existing `AssistantController` workflow.
- `Escape` cancels Preparing, Listening, or Processing immediately, restores any
  hotkey-owned playback change, discards captured speech, and never calls text
  delivery for that session.
- While one of those dictation phases is active, a temporary active CGEvent tap
  consumes Escape before the frontmost app can react. The tap is removed as soon
  as dictation ends, so Escape remains untouched for all other app activity.
- Temporary pre-release default: **Control+Shift+D** (`⌃⇧D`).
- First-run onboarding presents `KeyboardShortcuts.Recorder` for `.toggleDictation` so the user can confirm or replace the shortcut.
- Confirmation is tracked separately as `timbre.hasCompletedShortcutOnboarding` (see [`ONBOARDING_UX.md`](ONBOARDING_UX.md)).
- Completed transcripts are copied to the clipboard and inserted into the captured target when safe (see [`FOCUSED_APP_TEXT_INSERTION.md`](FOCUSED_APP_TEXT_INSERTION.md)).

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

Or:

```bash
defaults delete com.augustdrakton.Timbre KeyboardShortcuts_toggleDictation
```

## Onboarding Recorder

Onboarding displays Timbre-styled keycaps above a **Set hotkey** button. A
visually hidden `KeyboardShortcuts.RecorderCocoa` handles capture, validation,
and conflict alerts after the button is pressed.

Continue is disabled when the assigned shortcut is nil during first-run setup.
Onboarding, Settings, and Ready copy read the same live state for
`.toggleDictation`. The shortcut is required because dictation is shortcut-only.
Settings permits a temporary clear while editing, but restores the previous
shortcut if the window closes without a replacement. Missing shortcut storage
returns an existing user to the shortcut recovery step. No second shortcut
preference is stored.

The DEBUG full-app integration runtime injects
`.integrationTestToggleDictation` into the same recorder, onboarding adapter,
and global shortcut service. The lifecycle test therefore records and invokes
a real Carbon hotkey without mutating the production `.toggleDictation`
assignment.

## Toggle behavior

```text
Idle / Completed / Failed → Start
Listening → Stop
Preparing / Processing → ignored
Setup installing → ignored
Setup required / failed → present setup window
```

The compact menu does not expose Start/Stop.

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
- `KeyboardShortcuts.Recorder` can warn about system and menu conflicts during onboarding.
- Timbre does not promise detecting when another application has registered the same global combination.

## Testing

### Unit

```bash
xcodebuild -scheme Timbre -destination 'platform=macOS' -only-testing:TimbreTests test
```

Uses `FakeGlobalShortcutService` — no real system hotkeys.

### Full-app automation

```bash
scripts/run-full-integration-test.sh
```

The single lifecycle test records `⌃⇧K`, invokes it through real Carbon
registration in TextEdit, exercises busy-state presses and relaunch, and
leaves only final Command-V posting behind a deterministic probe. See
[`FULL_APPLICATION_INTEGRATION_TEST.md`](FULL_APPLICATION_INTEGRATION_TEST.md).

### Manual supplemental check

1. Build Debug and Release.
2. Launch Timbre; complete setup if needed (including shortcut confirmation).
3. Focus TextEdit; press the chosen shortcut → Preparing/Listening without opening the menu.
4. Speak; press the shortcut again → Processing → text inserted into TextEdit.
5. Verify clipboard behavior for the current retention setting; Copy Last Dictation explicitly copies and does not paste again.
6. Start a second session via the hotkey (model reuse).
7. Mash during Processing → no overlapping session.
8. Switch apps during Processing → no paste into the newly active app; transcript remains on clipboard.
9. Reset setup → hotkey does not bypass onboarding.
10. Close setup during download → hotkey no-ops; download continues.
11. The compact menu exposes only Settings, Copy Last Dictation, and Quit after setup.
12. DEBUG `--mock-transcription` toggle works without posting real paste events.
13. `--parakeet-fixture` skips global shortcut registration.

## Related

- Onboarding UX: [`ONBOARDING_UX.md`](ONBOARDING_UX.md).
- Focused-app insertion: [`FOCUSED_APP_TEXT_INSERTION.md`](FOCUSED_APP_TEXT_INSERTION.md).
- Model prewarming: [`MODEL_PREWARMING.md`](MODEL_PREWARMING.md).
