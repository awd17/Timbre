# Setup and Parakeet model management

Developer documentation for Timbre’s first-run setup flow and shared Parakeet model lifecycle.

## Status in this milestone

- Apple Speech remains the **default dictation engine** (Debug without flags, and all Release launches).
- Automatic setup UI is **gated** by `TimbreSetupFeature` and is **off in Release**.
- In DEBUG, setup is **on by default**, except when `--mock-transcription`, `--parakeet-fixture`, or `--disable-setup` is present.
- The next PR should remove this gate when Parakeet becomes the production default.

Release users must not auto-download ~500 MB for a component the app does not yet use for dictation.

## Architecture

```text
SetupFlowView / MenuBarDictationView
        → SetupCoordinator
              → MicrophonePermissionProviding
              → ParakeetModelManaging (ensureInstalled)
ParakeetTranscriptionService (DEBUG)
        → ParakeetModelManager.ensureLoaded()
ParakeetModelManager
        → FluidAudio AsrModels / AsrManager
        → on-disk cache (source of truth for “installed”)
```

Views must not import FluidAudio.

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
- **DEBUG Parakeet dictation** calls `ensureLoaded()`: load (download if needed) and **retain** while useful.

Do not keep a loaded `AsrManager` after onboarding while Apple Speech is still the active backend.

### Single-flight

`ParakeetModelManager` shares one install task and one load task. Opening setup twice, or overlapping install with DEBUG dictation prepare, must not start competing downloads.

Session cancel and closing the setup window do **not** cancel preparation.

### Dictation while setup is incomplete

When the setup feature is enabled and the model is not yet installed (or is still downloading), the menu-bar popover shows a setup-only surface: no transcript, no Start. Open the setup window from **Finish Setup…** / **Getting Ready…**. After the component is installed, normal dictation controls return.


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

## Reset for testing

```bash
# Remove model cache
rm -rf "$HOME/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v2"

# Clear setup prefs (bundle id)
defaults delete com.augustdrakton.Timbre
# Or only setup keys:
defaults delete com.augustdrakton.Timbre timbre.hasCompletedSetupWelcome
defaults delete com.augustdrakton.Timbre timbre.hasDismissedSetupReady
```

Launch DEBUG Timbre (setup on by default). Walk: Continue → grant mic → prepare → optionally close window → Ready → Done → quit → relaunch (no re-download).

Force setup off:

```bash
Timbre.app/Contents/MacOS/Timbre --disable-setup
# or
Timbre.app/Contents/MacOS/Timbre --mock-transcription --debug-window
```

## What the next PR should change

- Make Parakeet the normal production transcription backend.
- Remove the `TimbreSetupFeature` Release/DEBUG gate (or turn it on for Release).
- Route users to setup when the required download is unavailable.
- Keep Apple Speech as a temporary fallback if desired.
- Optionally add Settings model controls.

Do not implement those in this milestone.

## Related

- [`PARAKEET_MICROPHONE_DICTATION.md`](PARAKEET_MICROPHONE_DICTATION.md) — DEBUG mic path uses `ensureLoaded()`
- [`PARAKEET_SMOKE_TEST.md`](PARAKEET_SMOKE_TEST.md) — file smoke CLI (independent of the app manager)
- [`PROJECT_STATUS.md`](PROJECT_STATUS.md)
