# Setup and Parakeet model management

Developer documentation for Timbre’s first-run setup flow and shared Parakeet model lifecycle.

## Status

- **Parakeet is the default dictation engine** in Debug and Release.
- Automatic setup UI is on whenever Timbre needs the Parakeet component or microphone access for production dictation.
- In DEBUG, setup is **off** when `--mock-transcription`, `--parakeet-fixture`, `--apple-speech`, or `--disable-setup` is present.
- Release **ignores** those developer bypass flags.

Dictation readiness requires:

1. Model installed and valid on disk (or loaded in memory)
2. Microphone permission granted
3. Accessibility trusted (for text insertion)

The global dictation shortcut respects the same readiness gates: it will not start recording while setup is incomplete or the model is installing. When setup is required or failed, a shortcut press may present the existing setup window. See [`docs/GLOBAL_DICTATION_SHORTCUT.md`](GLOBAL_DICTATION_SHORTCUT.md) and [`docs/FOCUSED_APP_TEXT_INSERTION.md`](FOCUSED_APP_TEXT_INSERTION.md).

## Architecture

```text
SetupFlowView / MenuBarMenuView
        → SetupCoordinator
              → MicrophonePermissionProviding
              → AccessibilityPermissionProviding
              → ParakeetModelManaging (ensureInstalled)
ParakeetPrewarmCoordinator (after readiness)
        → ParakeetModelManaging.loadInstalledAndRetain()  # no download
ParakeetTranscriptionService (production default)
        → ParakeetModelManager.ensureLoaded()   # joins prewarm or loads; retains
ParakeetModelManager
        → FluidAudio AsrModels / AsrManager
        → on-disk cache (source of truth for “installed”)
```

Views must not import FluidAudio.

Launch construction of `ParakeetModelManager` / `ParakeetTranscriptionService` must not request the microphone, download files, or load the model. Setup owns `ensureInstalled()`. `ParakeetPrewarmCoordinator` owns proactive `loadInstalledAndRetain()`, starting as soon as the model is on disk (independent of permission readiness). Production does not register the dictation hotkey until that retained load completes. Dictation Start calls `ensureLoaded()` as a fast invariant/reuse check; Stop never inherits launch compilation.

### Installed vs loaded

| State | Meaning |
|-------|---------|
| `notInstalled` | Required files are not present |
| `downloading` | Download in progress |
| `installed` | On disk and verified; **no** retained `AsrManager` |
| `loading` | Install/verify compile into memory (setup Preparing) |
| `loaded` | `AsrManager` retained for dictation |
| `failed` | Recoverable install failure |

- **Onboarding** calls `ensureInstalled()`: download → verify load → **release** manager → `installed`.
- **Prewarming** calls `loadInstalledAndRetain()`: load from disk only, **retain**, never download.
  Starts as soon as the model is on disk (no microphone/Accessibility gate) so the cold Core ML/ANE
  compile happens during first-run setup instead of stalling the first dictation.
- **Production Parakeet dictation** calls `ensureLoaded()`: load (download if needed) and **retain** while useful.

Loading an existing cache into memory leaves the public lifecycle at `installed` until the retained
manager is ready. A private owned flight tracks the in-progress operation, keeping disk readiness and
memory activity from becoming competing enum states.

See [`MODEL_PREWARMING.md`](MODEL_PREWARMING.md).

### Single-flight

`ParakeetModelManager` shares one install task and one owned load flight. Opening setup twice, or overlapping install with dictation prepare, must not start competing downloads.

Session cancel and closing the setup window do **not** cancel preparation.

### Dictation while setup is incomplete

When setup is incomplete, the native menu adds one temporary recovery command:
**Finish Setup…**, **Getting Ready…**, or **Setup Failed — Try Again…**. The
normal Settings, Copy Last Dictation, and Quit commands remain available.
Dictation itself is shortcut-only, and readiness requires an assigned shortcut.
After readiness is restored, the temporary setup command disappears without a
relaunch.

`applicationDidBecomeActive` refreshes cache, microphone, and Accessibility trust so revoke/re-grant and deleted caches update the menu while Timbre stays open.
Setup also performs a short series of read-only Accessibility rechecks after
AppKit finishes launching. This handles Xcode-launched debug builds where an
already-granted process can transiently report untrusted during app-delegate
construction, without displaying another prompt or requiring a relaunch.

```text
Welcome → Shortcut → Microphone → Text Insertion → Preparing → Ready
```

1. Shortcut confirmation happens **before** permission prompts and before any download.
2. Mic permission is requested **before** Accessibility and before any download.
3. Text insertion (Accessibility) is resolved **before** the ~500 MB model download.
4. If Accessibility is not trusted, Timbre does **not** begin a new model download.
5. Existing users with the model already installed skip redownload; they may still see shortcut confirmation or permission recovery.
6. After shortcut confirmation and both permissions are trusted, install starts automatically (no second Download button).
7. Progress UI shows a determinate bar mapped from FluidAudio callbacks (monotonic overall fraction), percent, and an ETA when enough progress exists.
8. When the model finishes installing, Timbre **loads it into memory inside this same "Preparing" step**. This hides the cold Core ML/ANE compile (~10-15s on a fresh bundle) behind onboarding so the very first dictation after Ready is warm instead of stalling in its own Preparing phase.
9. Closing the window does not cancel preparation; the menu-bar app keeps running.
10. Quit ends the process; the next launch re-probes the **cache**, not a stale Boolean.
11. Prefs alone never prove the model is installed or that Accessibility is trusted.

### Setup readiness vs clipboard fallback

Missing Accessibility blocks normal production Start (setup recovery). Clipboard-only fallback still applies **during** an allowed session when insertion cannot safely proceed — see [`FOCUSED_APP_TEXT_INSERTION.md`](FOCUSED_APP_TEXT_INSERTION.md).

### Persistence

| Key | Purpose |
|-----|---------|
| `timbre.hasCompletedSetupWelcome` | Welcome was continued |
| `timbre.hasCompletedShortcutOnboarding` | User confirmed the shortcut onboarding step |
| `timbre.hasDismissedSetupReady` | User tapped Done on Ready |
| `timbre.hasOfferedAccessibilityPrompt` | UX only: Timbre already offered the Accessibility prompt |

Model availability: `AsrModels.modelsExist` / successful verify via FluidAudio.
Accessibility readiness: live `AXIsProcessTrusted` only.
Assigned shortcut: KeyboardShortcuts storage for `.toggleDictation` (separate from confirmation).
After the shortcut step has been confirmed, the current assignment is not a
general readiness requirement. Clearing it in Settings leaves menu dictation
and setup readiness intact.

### Cache

| Item | Value |
|------|--------|
| Directory | `~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v2` |
| Approx size | ~464 MB (see `PARAKEET_SMOKE_TEST.md`) |

Size is for developers only; setup UI does not show megabytes.

## Clean Release verification

Use the **Release-built** `Timbre.app`, not a Debug binary with simulated Release selection.

```bash
# Reset microphone and Accessibility TCC for this bundle
tccutil reset Microphone com.augustdrakton.Timbre
tccutil reset Accessibility com.augustdrakton.Timbre

# Optional if clearing DEBUG Apple Speech leftovers
tccutil reset SpeechRecognition com.augustdrakton.Timbre

# Remove model cache
rm -rf "$HOME/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v2"

# Clear setup prefs
defaults delete com.augustdrakton.Timbre

xcodebuild -scheme Timbre -configuration Release -destination 'platform=macOS' build
# Launch Build/Products/Release/Timbre.app with no arguments
```

Walk: setup appears → choose shortcut → grant mic → Allow Text Insertion → prepare → optionally close window → Ready → Done → Start/Stop dictation → text inserted (and on clipboard).
Pass DEBUG-only flags to the Release binary and confirm they do not change the backend or bypass setup.

Xcode Debug builds intentionally use `com.augustdrakton.Timbre.debug` and
display as **Timbre Debug**. This gives the Apple Development-signed executable
its own Accessibility and microphone rows instead of colliding with an
installed release named Timbre:

```bash
tccutil reset Microphone com.augustdrakton.Timbre.debug
tccutil reset Accessibility com.augustdrakton.Timbre.debug
```

## DEBUG setup bypass

```bash
Timbre.app/Contents/MacOS/Timbre --disable-setup
Timbre.app/Contents/MacOS/Timbre --mock-transcription --debug-window
Timbre.app/Contents/MacOS/Timbre --apple-speech --debug-window
Timbre.app/Contents/MacOS/Timbre --parakeet-fixture --debug-window
```

Use `scripts/run-full-integration-test.sh` for isolated automated onboarding,
menu, relaunch, and delivery coverage. See
[`FULL_APPLICATION_INTEGRATION_TEST.md`](FULL_APPLICATION_INTEGRATION_TEST.md).

## Related

- [`ONBOARDING_UX.md`](ONBOARDING_UX.md) — onboarding window and shortcut confirmation
- [`FULL_APPLICATION_INTEGRATION_TEST.md`](FULL_APPLICATION_INTEGRATION_TEST.md) — unified automated lifecycle
- [`PARAKEET_MICROPHONE_DICTATION.md`](PARAKEET_MICROPHONE_DICTATION.md) — production mic path uses `ensureLoaded()`
- [`PARAKEET_SMOKE_TEST.md`](PARAKEET_SMOKE_TEST.md) — file smoke CLI (independent of the app manager)
- [`FOCUSED_APP_TEXT_INSERTION.md`](FOCUSED_APP_TEXT_INSERTION.md) — Accessibility + insertion
- [`PROJECT_STATUS.md`](PROJECT_STATUS.md)
