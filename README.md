# Timbre

Menu-bar voice dictation for macOS.  
Start a session from the status item, or press **Control+Shift+D** (`⌃⇧D`) from anywhere.  
Speak, then stop (menu or the same shortcut).  
The app transcribes locally with Parakeet and copies the text to the clipboard.  
Paste manually where you need it (automatic insertion is not implemented yet).

**Repository:** https://github.com/awd17/Timbre

For feature status, architecture, and contributor rules, see [`docs/PROJECT_STATUS.md`](docs/PROJECT_STATUS.md).

## Requirements

- macOS 14.6 or later
- Apple Silicon (Parakeet / FluidAudio)
- Xcode 16 or later
- An Apple Development signing team for local runs
- Microphone permission for normal use

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
xcodebuild -scheme Timbre -destination 'platform=macOS' test
```

## Run

In Xcode, press ⌘R (Debug), or launch a Release build of `Timbre.app`.  
On first launch (when the model is not installed), complete setup: microphone → download/verify → Done.  
Open the waveform status item, or use the global shortcut **⌃⇧D** to Start/Stop without opening the menu.  
Use Start, Stop, Copy Again, or Quit in the menu as before.

The built-in shortcut is a temporary development default. Shortcut customization UI is not shipped yet; see [`docs/GLOBAL_DICTATION_SHORTCUT.md`](docs/GLOBAL_DICTATION_SHORTCUT.md).

Parakeet is the default engine in **Debug and Release**. No backend launch argument is required.

| Launch argument | Effect |
|-----------------|--------|
| *(none)* | Parakeet batch dictation + microphone. Setup appears when the model or mic is not ready. |
| `--mock-transcription` | Debug only. Fake transcript. No microphone. Disables automatic setup. |
| `--apple-speech` | Debug only. Apple Speech comparison backend. Disables Parakeet setup. |
| `--parakeet-fixture` | Debug only. Run the committed WAV through the app path (no mic). Disables automatic setup. |
| `--parakeet-transcription` | Deprecated no-op. Parakeet is already the default; logged once. |
| `--debug-window` | Debug only. Opens the Timbre Debug window. |
| `--disable-setup` | Debug only. Disables the automatic first-run setup window. |

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
First Start loads the installed model into memory (`ensureLoaded`); later sessions reuse it.  
Setup installs and verifies the model on disk (`ensureInstalled`) without keeping it loaded.

Details: [`docs/SETUP_AND_MODEL_MANAGEMENT.md`](docs/SETUP_AND_MODEL_MANAGEMENT.md) and [`docs/PARAKEET_MICROPHONE_DICTATION.md`](docs/PARAKEET_MICROPHONE_DICTATION.md).

### Clean Release verification

Reset microphone TCC and local state, then exercise the **Release** product (not only Debug with simulated flags):

```bash
tccutil reset Microphone com.augustdrakton.Timbre
# Optional if comparing DEBUG Apple Speech leftovers:
tccutil reset SpeechRecognition com.augustdrakton.Timbre

rm -rf "$HOME/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v2"
defaults delete com.augustdrakton.Timbre

xcodebuild -scheme Timbre -configuration Release -destination 'platform=macOS' build
# Launch the Release .app from DerivedData Build/Products/Release/Timbre.app
```

Confirm: setup appears; microphone is requested; Speech Recognition is not; Start/Stop produces a clipboard transcript; DEBUG flags passed to the Release binary do not change backend or bypass setup.

### Smoke CLI

A separate command-line target still verifies model download, cache reuse, and file transcription:

```bash
./scripts/run-parakeet-smoke.sh
```

Full steps: [`docs/PARAKEET_SMOKE_TEST.md`](docs/PARAKEET_SMOKE_TEST.md).
