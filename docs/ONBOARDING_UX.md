# Onboarding UX

Developer notes for Timbre’s first-run onboarding window.

## Visible flow

```text
Welcome
→ Choose shortcut
→ Microphone if needed
→ Text Insertion if needed
→ Getting ready (download / verify)
→ Ready
```

There is no multi-stage progress indicator. Steps transition in one branded window.

Model download starts only when:

1. The user has confirmed the shortcut onboarding step
2. A shortcut is currently assigned
3. Microphone permission is granted
4. Accessibility is trusted

## Background asset

```text
Source artwork during development: ../images/OnboardingBG.png
Bundled asset: Timbre/Assets.xcassets/OnboardingBackground.imageset/
Asset name: OnboardingBackground
```

Runtime uses only the bundled asset catalog entry. Do not load `../images` at runtime.

## Shortcut selection vs confirmation

| Concept | Source of truth |
|---------|-----------------|
| Assigned shortcut | KeyboardShortcuts named `.toggleDictation` |
| Onboarding confirmation | `timbre.hasCompletedShortcutOnboarding` |

The temporary default `⌃⇧D` may already exist in storage before the user sees onboarding. That does **not** skip the shortcut step. Continue requires a non-nil assignment and writes the confirmation preference.

Recorder changes update Continue immediately via the package’s public `KeyboardShortcuts.Recorder(for:onChange:)` callback and `ShortcutOnboardingProviding`.

Clearing the shortcut later returns the user to shortcut recovery on the next reconcile. It does not invalidate or redownload the model.

## Closing during download

**Continue in Background** (or the window close button) dismisses the window only. Shared `ParakeetModelManaging.ensureInstalled()` keeps running. Reopening shows live progress. Quitting the app ends in-process work; the next launch re-probes the on-disk cache.

## Simulated onboarding (DEBUG)

```bash
Timbre.app/Contents/MacOS/Timbre \
  --simulate-onboarding \
  --simulate-onboarding-duration 6
```

| Argument | Effect |
|----------|--------|
| `--simulate-onboarding` | Forces setup on; fake mic/Accessibility/model; isolated prefs and custom hotkey capture; disables global hotkey registration, real prewarm, paste insertion, System Settings, FluidAudio |
| `--simulate-onboarding-duration <seconds>` | Fake download length (default 6) |
| `--simulate-onboarding-failure` | First simulated install fails; retry can succeed |
| `--simulate-onboarding-step <name>` | Jump to a seeded state (`welcome`, `shortcut`, `shortcut-empty`, `microphone`, `microphone-denied`, `accessibility`, `accessibility-denied`, `preparing`, `ready`, `failed`) |
| `--simulate-onboarding-real-recorder` | Uses the production `.toggleDictation` recorder instead of the isolated simulated recorder (can mutate the developer’s real shortcut). Automated UI tests do **not** use this. |

Incompatible with `--disable-setup`, `--parakeet-fixture`, and `--apple-speech`. Compatible with `--mock-transcription` in the sense that simulation already uses mock transcription internally.

Close/reopen keeps simulated progress because the fake model manager is owned by the app delegate, not the SwiftUI view.

Release builds ignore all simulation flags.

## Real reset (not for normal UI iteration)

```bash
defaults delete com.augustdrakton.Timbre timbre.hasCompletedSetupWelcome
defaults delete com.augustdrakton.Timbre timbre.hasDismissedSetupReady
defaults delete com.augustdrakton.Timbre timbre.hasCompletedShortcutOnboarding
defaults delete com.augustdrakton.Timbre timbre.hasOfferedAccessibilityPrompt
defaults delete com.augustdrakton.Timbre KeyboardShortcuts_toggleDictation

tccutil reset Microphone com.augustdrakton.Timbre
tccutil reset Accessibility com.augustdrakton.Timbre

rm -rf "$HOME/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v2"
```

Prefer `--simulate-onboarding` for UI iteration. Delete the model cache only for true end-to-end download testing.

## Existing-user migration

| Situation | Behavior |
|-----------|----------|
| Fully ready + shortcut onboarding confirmed | Do not auto-present |
| Model installed + permissions OK + shortcut not confirmed | Shortcut once → Ready (no redownload) |
| Shortcut confirmed + Accessibility missing | Text Insertion recovery → Ready |
| Model missing | After shortcut + permissions → Preparing |

## Menu UI

Menu-bar popover polish is intentionally deferred. Menu chrome still uses the shared coordinator readiness signals (`Finish Setup…`, `Getting Ready…`, etc.).

## Related

- [`SETUP_AND_MODEL_MANAGEMENT.md`](SETUP_AND_MODEL_MANAGEMENT.md)
- [`GLOBAL_DICTATION_SHORTCUT.md`](GLOBAL_DICTATION_SHORTCUT.md)
- [`MODEL_PREWARMING.md`](MODEL_PREWARMING.md)
- [`PROJECT_STATUS.md`](PROJECT_STATUS.md)
