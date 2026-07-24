# Focused-app text insertion

Developer notes for Timbre’s Accessibility-gated insertion of completed dictation into the intended external application.

## Status

- After Stop, Timbre copies the transcript to the pasteboard, then posts Command-V into the captured target when safe.
- The **Keep transcript on clipboard** setting controls successful insertion and defaults off. Timbre still uses the pasteboard internally.
- Accessibility permission is **required** for normal production dictation readiness.
- Automatic insertion uses `NSPasteboard` + `CGEvent` Command-V — not direct AX text replacement.
- Model prewarming after setup readiness is documented in [`MODEL_PREWARMING.md`](MODEL_PREWARMING.md). Onboarding polish and shortcut customization remain later work.

## End-to-end loop

```text
Focus a text field in another app
→ Start (⌃⇧D or menu)
→ speak
→ Stop
→ Parakeet transcribes
→ Timbre copies transcript
→ Timbre posts Command-V into the captured target (when safe)
→ text appears at the caret; the previous complete clipboard snapshot is restored when safe, or the transcript remains according to Settings/fallback policy

When retention is off, restoration is driven by promised-data consumption.
After consumption, Timbre allows a bounded 150 ms grace period for editors that
inspect pasteboard data before committing their paste on a later run-loop turn.
It then restores all captured item representations only while its tracked
`changeCount` remains current. Unreadable, changing, or over-64-MiB snapshots
are not partially restored. A newer clipboard generation always wins; see
[`SETTINGS.md`](SETTINGS.md) for limitations.
```

Copy Again copies only; it never pastes again.

## Setup vs in-session clipboard fallback

These policies must not be confused:

| Concern | Policy |
|---------|--------|
| **Entering normal production dictation** | Accessibility must be **trusted**. Missing trust → setup recovery (`allowsDictation == false`). Users are not offered ordinary clipboard-only Start/Stop as the default path. |
| **During/after an allowed session** | If insertion cannot safely proceed, keep the transcript on the clipboard and show a concise fallback status. |

In-session clipboard-only reasons include: Accessibility revoked mid-session, target missing/terminated/changed, Timbre/self target, pasteboard race, Command-V post failure, confidently detected secure field, ambiguous pid/bundle identity.

## Accessibility permission model

macOS exposes Accessibility as **trusted** vs **not trusted**. There is no reliable system-level “undetermined.”

| API / state | Role |
|-------------|------|
| `AXIsProcessTrusted` / live `trustState` | Source of truth for readiness and paste gating |
| `timbre.hasOfferedAccessibilityPrompt` | UX only — whether Timbre already offered the system prompt |
| Prefs / offered flag | **Never** prove denial or readiness |

Reset during development:

```bash
tccutil reset Accessibility com.augustdrakton.Timbre
```

(Use the app’s actual bundle identifier if it differs in your signing setup.)

Granting Accessibility should restore readiness without redownloading the model. Recheck on `applicationDidBecomeActive`. Whether trust applies without relaunch depends on the OS build; Timbre always re-reads live trust when active.

## Setup order

```text
Welcome → Microphone → Text Insertion → Preparing → Ready
```

- Both permissions are resolved **before** the ~500 MB model download.
- Accessibility not trusted → do **not** call `ensureInstalled()`.
- Existing users with the model already on disk → Text Insertion only (no redownload).
- User-facing copy: “Allow Text Insertion” / Open System Settings when recovery is needed.

Readiness:

```text
model ready + microphone granted + Accessibility trusted = allowsDictation
```

## Target capture and MenuBarExtra

Capture happens at Start **before** `prepare()` / model load, into a controller-owned `DictationSessionContext` (one session id + target + initiation).

### Menu-focus experiment result

`MenuBarExtra` with `.window` style makes Timbre frontmost when the user opens the menu and taps Start. A simple frontmost-only provider would lose the external target on the menu path.

Therefore production uses `FrontmostApplicationTracker`:

- Observes `NSWorkspace.didActivateApplicationNotification`
- Remembers the last non-Timbre app
- At Start, prefers current external frontmost, else last external
- Never selects Timbre as the target
- Removes the observer on deinit

At delivery, if a **different** third-party app is frontmost → copy only (no focus steal).

If Timbre itself is frontmost (typical after menu Start) → narrowly reactivate **only** the captured target, confirm frontmost matches (pid + bundle when available), then paste. Failure → copy only.

## Delivery architecture

```text
AssistantController
  → TranscriptDeliveryServicing
       → ClipboardServicing (always copy first)
       → AccessibilityPermissionProviding (live trust)
       → DictationTargetProviding (frontmost / reactivation)
       → PasteCommandEventPosting (CGEvent Command-V)
```

Result:

- `pasteEventPosted` → status “Inserted.” (events posted; acceptance not universally confirmable)
- `copiedAfterInsertFailure(...)` → “Couldn't insert text. Copied instead.”
- `copiedByDesign` → “Copied to clipboard.” for Copy Again and DEBUG clipboard-only mode
- `failed(.clipboardUnavailable)` → “Couldn't copy or insert text.” while retaining the transcript in Timbre for another Copy Again attempt

DEBUG mock / fixture / `--disable-setup` / UI tests inject `ClipboardOnlyTranscriptDelivery` so automation never posts real paste events.

## Validation before Command-V

1. Pasteboard write succeeded and still holds Timbre’s transcript (`changeCount` / string check)
2. Accessibility currently trusted
3. Target non-nil, not Timbre, still running
4. Pid **and** bundle match when bundle was captured (do not trust pid alone)
5. Frontmost is the captured target, or Timbre-frontmost reactivation confirmed
6. Focused element is not a confidently detected secure text field (`AXSecureTextField`)

## Compatibility notes

Manually verify insertion in at least TextEdit plus one other app (Notes, browser textarea, or an editor). Logs that say events were posted are not sufficient proof.

Known limitations:

- Some apps may ignore synthetic Command-V; fallback keeps clipboard.
- Secure-field detection is best-effort via AX role; inconsistent apps may still receive paste.
- No app-specific adapters in this PR.
- No clipboard restoration of the user’s previous pasteboard contents.

## Out of scope

Shortcut recorder, hold-to-talk, floating panel, direct AX text set, selection rewrite, LLM/TTS, rich text, packaging/signing, onboarding/menu redesign.
