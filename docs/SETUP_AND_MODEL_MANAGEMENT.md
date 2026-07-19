# Setup and Parakeet model management

Developer documentation for Timbre’s first-run setup flow and shared Parakeet model lifecycle.

## Status

- **Parakeet is the default dictation engine** in Debug and Release.
- Automatic setup UI is on whenever Timbre needs the Parakeet component or microphone access for production dictation.
- In DEBUG, setup is **off** when `--mock-transcription`, `--parakeet-fixture`, `--apple-speech`, or `--disable-setup` is present.
- Release **ignores** those developer bypass flags.

Dictation readiness requires both:

1. Model installed and valid on disk (or loaded in memory)
2. Microphone permission granted

The global dictation shortcut respects the same readiness gates: it will not start recording while setup is incomplete or the model is installing. When setup is required or failed, a shortcut press may present the existing setup window. See [`docs/GLOBAL_DICTATION_SHORTCUT.md`](GLOBAL_DICTATION_SHORTCUT.md).

## Architecture

```text
SetupFlowView / MenuBarDictationView
        → SetupCoordinator
              → MicrophonePermissionProviding
              → ParakeetModelManaging (ensureInstalled)
ParakeetTranscriptionService (production default)
        → ParakeetModelManager.ensureLoaded()   # first Start only loads into memory
ParakeetModelManager
        → FluidAudio AsrModels / AsrManager
        → on-disk cache (source of truth for “installed”)
```

Views must not import FluidAudio.

Launch construction of `ParakeetModelManager` / `ParakeetTranscriptionService` must not request the microphone, download files, or load the model. Setup owns `ensureInstalled()`; the first Start owns `ensureLoaded()`.

### Installed vs loaded

| State | Meaning |
|-------|---------|
| `notInstalled` | Required files are not present |
| `downloading` | Download in progress |
| `installed` | On disk and verified; **no** retained `AsrManager` |
| `loading` | Compiling/loading into memory |
| `loaded` | `AsrManager` retained for dictation |
| `failed` | Recoverable failure |

- **Onboarding** calls `ensureInstalled()`: download → verify load → **release** manager → `installed`.
- **Production Parakeet dictation** calls `ensureLoaded()`: load (download if needed) and **retain** while useful.

### Single-flight

`ParakeetModelManager` shares one install task and one load task. Opening setup twice, or overlapping install with dictation prepare, must not start competing downloads.

Session cancel and closing the setup window do **not** cancel preparation.

### Dictation while setup is incomplete

When setup is enabled and the model is not installed, still downloading, or the microphone is not granted, the menu-bar popover shows a setup-only surface: no transcript, no Start. Open the setup window from **Finish Setup…** / **Getting Ready…** / **Setup Failed — Try Again…**. After the component is installed and the mic is granted, normal dictation controls return without relaunching.

`applicationDidBecomeActive` refreshes cache and microphone status so revoke/re-grant and deleted caches update the menu while Timbre stays open.

```text
Welcome → Microphone → Preparing → Ready
```

1. Mic permission is requested **before** any download.
2. After grant, install starts automatically (no second Download button).
3. Progress UI shows a determinate bar mapped from FluidAudio callbacks (monotonic overall fraction), percent, and an ETA when enough progress exists.
4. Closing the window does not cancel preparation; the menu-bar app keeps running.
5. Quit ends the process; the next launch re-probes the **cache**, not a stale Boolean.
6. Prefs alone never prove the model is installed.

### Persistence

| Key | Purpose |
|-----|---------|
| `timbre.hasCompletedSetupWelcome` | Welcome was continued |
| `timbre.hasDismissedSetupReady` | User tapped Done on Ready |

Model availability: `AsrModels.modelsExist` / successful verify via FluidAudio.

### Cache

| Item | Value |
|------|--------|
| Directory | `~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v2` |
| Approx size | ~464 MB (see `PARAKEET_SMOKE_TEST.md`) |

Size is for developers only; setup UI does not show megabytes.

## Clean Release verification

Use the **Release-built** `Timbre.app`, not a Debug binary with simulated Release selection.

```bash
# Reset microphone TCC for this bundle
tccutil reset Microphone com.augustdrakton.Timbre

# Optional if clearing DEBUG Apple Speech leftovers
tccutil reset SpeechRecognition com.augustdrakton.Timbre

# Remove model cache
rm -rf "$HOME/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v2"

# Clear setup prefs
defaults delete com.augustdrakton.Timbre

xcodebuild -scheme Timbre -configuration Release -destination 'platform=macOS' build
# Launch Build/Products/Release/Timbre.app with no arguments
```

Walk: setup appears → grant mic (Speech Recognition must not appear) → prepare → optionally close window → Ready → Done → Start/Stop dictation → clipboard.  
Pass DEBUG-only flags to the Release binary and confirm they do not change the backend or bypass setup.

## DEBUG setup bypass

```bash
Timbre.app/Contents/MacOS/Timbre --disable-setup
Timbre.app/Contents/MacOS/Timbre --mock-transcription --debug-window
Timbre.app/Contents/MacOS/Timbre --apple-speech --debug-window
Timbre.app/Contents/MacOS/Timbre --parakeet-fixture --debug-window
```

## Related

- [`PARAKEET_MICROPHONE_DICTATION.md`](PARAKEET_MICROPHONE_DICTATION.md) — production mic path uses `ensureLoaded()`
- [`PARAKEET_SMOKE_TEST.md`](PARAKEET_SMOKE_TEST.md) — file smoke CLI (independent of the app manager)
- [`PROJECT_STATUS.md`](PROJECT_STATUS.md)
