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
2. A shortcut is assigned while completing the initial shortcut step
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

Clearing the shortcut later does not return the user to onboarding, invalidate
the model, or block menu dictation. Ready copy and menu hints update to the
unset state, and the shortcut can be assigned again in Settings.

## Closing during download

**Continue in Background** dismisses the window and suppresses the automatic
Ready presentation after a successful install. Shared
`ParakeetModelManaging.ensureInstalled()` keeps running, and reopening shows
live progress without starting another install. A failure clears the
suppression so recovery is presented. The ordinary close button also leaves
preparation running, but does not opt out of the later Ready presentation.
Quitting ends in-process work; the next launch re-probes the on-disk cache.

## Automated full-app onboarding (DEBUG)

```bash
scripts/run-full-integration-test.sh
```

The single UI lifecycle runs both foreground and background onboarding,
records an isolated real Carbon shortcut, covers permission recovery and
install failure/retry, and continues through menu dictation, relaunch,
delivery safety, and Quit. It uses persistent isolated profiles and a fake
model that never touches FluidAudio or the network. See
[`FULL_APPLICATION_INTEGRATION_TEST.md`](FULL_APPLICATION_INTEGRATION_TEST.md).

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

Use the full-app integration test for repeatable onboarding coverage. Delete
the model cache only for true end-to-end download testing.

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
