# Timbre

Menu-bar voice dictation for macOS.  
Start a session from the status item, or press **Control+Shift+D** (`⌃⇧D`) from anywhere.  
Speak, then stop (menu or the same shortcut).  
The app transcribes locally with Parakeet and inserts text into the app you were using when you started (Accessibility permission required). Timbre uses the clipboard internally and preserves the transcript when insertion cannot safely run.

**Repository:** https://github.com/awd17/Timbre

For feature status, architecture, and contributor rules, see [`docs/PROJECT_STATUS.md`](docs/PROJECT_STATUS.md).

## Requirements

- macOS 14.6 or later
- Apple Silicon (Parakeet / FluidAudio)
- Xcode 16 or later
- An Apple Development signing team for local runs
- Microphone permission for normal use
- Accessibility permission for inserting text into other apps

Speech Recognition permission is only needed for the DEBUG `--apple-speech` comparison backend.

## Setup

```bash
git clone https://github.com/awd17/Timbre.git
cd Timbre
open Timbre.xcodeproj
```

In Xcode, select the **Timbre** scheme.  
Set your Development Team under Signing & Capabilities.  
App Sandbox is off.  
`LSUIElement` is on, so the app has no Dock icon.

## Build

```bash
xcodebuild -scheme Timbre -configuration Debug -destination 'platform=macOS' build
xcodebuild -scheme Timbre -configuration Release -destination 'platform=macOS' build
```

## Test

```bash
scripts/run-full-integration-test.sh
```

This builds the test bundle once, then runs all unit tests and the single
full-application UI lifecycle without rebuilding. See
[`docs/FULL_APPLICATION_INTEGRATION_TEST.md`](docs/FULL_APPLICATION_INTEGRATION_TEST.md).

## Run

In Xcode, press ⌘R (Debug), or launch a Release build of `Timbre.app`.  
On first launch (when setup is incomplete), complete onboarding: welcome → choose shortcut → microphone → text insertion → download/verify → Done.
Use your required global shortcut to start and stop dictation. Open the waveform
status item for the native compact menu: **Settings…**, **Copy Last Dictation**,
and **Quit Timbre**. A temporary setup command appears above them only when
onboarding or recovery is required. Settings includes the shared dictation
shortcut, Dock visibility (off by default), clipboard retention (off by default),
and version information. See [`docs/SETTINGS.md`](docs/SETTINGS.md).

The temporary default shortcut is **⌃⇧D** until you change it in onboarding. See [`docs/ONBOARDING_UX.md`](docs/ONBOARDING_UX.md) and [`docs/GLOBAL_DICTATION_SHORTCUT.md`](docs/GLOBAL_DICTATION_SHORTCUT.md).

Parakeet is the default engine in **Debug and Release**. No backend launch argument is required.

| Launch argument | Effect |
|-----------------|--------|
| *(none)* | Parakeet batch dictation + microphone. Setup appears when the model, mic, Accessibility, or shortcut confirmation is not ready. |
| `--mock-transcription` | Debug only. Fake transcript. No microphone. Disables automatic setup. |
| `--apple-speech` | Debug only. Apple Speech comparison backend. Disables Parakeet setup. |
| `--parakeet-fixture` | Debug only. Run the committed WAV through the app path (no mic). Disables automatic setup. |
| `--parakeet-transcription` | Deprecated no-op. Parakeet is already the default; logged once. |
| `--debug-window` | Debug only. Opens the Timbre Debug window. |
| `--disable-setup` | Debug only. Disables the automatic first-run setup window. |
| `--disable-model-prewarm` | Debug only. Disables background model prewarming (Start still loads via `ensureLoaded`). |
| `--integration-test` | Debug only. Unified automated app lifecycle; configured by test environment variables. |

Release builds ignore all of the DEBUG-only flags above.

```bash
# Path depends on your DerivedData location
Timbre.app/Contents/MacOS/Timbre --debug-window --mock-transcription
Timbre.app/Contents/MacOS/Timbre --debug-window --apple-speech
Timbre.app/Contents/MacOS/Timbre --debug-window --parakeet-fixture
```

DEBUG flag priority when several are present: fixture → mock → apple-speech → Parakeet default.

## Parakeet / FluidAudio

Production dictation is Parakeet v2 batch transcription (no live partials).  
After setup readiness, Timbre **prewarms** the installed model into memory in the background (`loadInstalledAndRetain`).
Start uses `ensureLoaded` and joins any in-flight prewarm; later sessions reuse the retained manager.
Setup installs and verifies the model on disk (`ensureInstalled`) without keeping it loaded.

Details: [`docs/SETUP_AND_MODEL_MANAGEMENT.md`](docs/SETUP_AND_MODEL_MANAGEMENT.md), [`docs/MODEL_PREWARMING.md`](docs/MODEL_PREWARMING.md), and [`docs/PARAKEET_MICROPHONE_DICTATION.md`](docs/PARAKEET_MICROPHONE_DICTATION.md).

### Clean Release verification

Reset microphone and Accessibility TCC and local state, then exercise the **Release** product (not only Debug with simulated flags):

```bash
tccutil reset Microphone com.augustdrakton.Timbre
tccutil reset Accessibility com.augustdrakton.Timbre
# Optional if comparing DEBUG Apple Speech leftovers:
tccutil reset SpeechRecognition com.augustdrakton.Timbre

rm -rf "$HOME/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v2"
defaults delete com.augustdrakton.Timbre

xcodebuild -scheme Timbre -configuration Release -destination 'platform=macOS' build
# Launch the Release .app from DerivedData Build/Products/Release/Timbre.app
```

Confirm: setup appears; choose shortcut → microphone → text insertion before download; Start/Stop inserts into the focused app; clipboard retention follows Settings; DEBUG flags passed to the Release binary do not change backend or bypass setup.

Details: [`docs/SETUP_AND_MODEL_MANAGEMENT.md`](docs/SETUP_AND_MODEL_MANAGEMENT.md), [`docs/ONBOARDING_UX.md`](docs/ONBOARDING_UX.md), [`docs/PARAKEET_MICROPHONE_DICTATION.md`](docs/PARAKEET_MICROPHONE_DICTATION.md), and [`docs/FOCUSED_APP_TEXT_INSERTION.md`](docs/FOCUSED_APP_TEXT_INSERTION.md).

### Smoke CLI

A separate command-line target still verifies model download, cache reuse, and file transcription:

```bash
./scripts/run-parakeet-smoke.sh
```

Full steps: [`docs/PARAKEET_SMOKE_TEST.md`](docs/PARAKEET_SMOKE_TEST.md).
