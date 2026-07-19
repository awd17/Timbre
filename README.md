# Timbre

Menu-bar voice dictation for macOS.  
Start a session from the status item.  
See the live transcript.  
Stop the session.  
Copy the text to the clipboard.

**Repository:** https://github.com/awd17/Timbre

For feature status, architecture, and contributor rules, see [`docs/PROJECT_STATUS.md`](docs/PROJECT_STATUS.md).

## Requirements

- macOS 14.6 or later
- Xcode 16 or later
- An Apple Development signing team for local runs
- Microphone permission (and Speech Recognition permission for the default Apple Speech path)

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
xcodebuild -scheme Timbre -destination 'platform=macOS' build
```

## Test

```bash
xcodebuild -scheme Timbre -destination 'platform=macOS' test
```

## Run

In Xcode, press ⌘R.  
Open the waveform status item.  
Use Start, Stop, Copy Again, or Quit.

| Launch argument | Effect |
|-----------------|--------|
| *(none)* | Real Apple Speech and microphone (default in Debug and Release). In DEBUG, first-run setup may appear (gated; see below). |
| `--mock-transcription` | Debug only. Fake transcript. No microphone. Disables automatic setup. |
| `--parakeet-transcription` | Debug only. Local Parakeet v2 batch transcription after Stop. |
| `--parakeet-fixture` | Debug only. With `--parakeet-transcription`, run the committed WAV through the app path (no mic). Disables automatic setup. |
| `--debug-window` | Debug only. Opens the Timbre Debug window. |
| `--disable-setup` | Debug only. Disables the automatic first-run setup window. |

```bash
# Path depends on your DerivedData location
Timbre.app/Contents/MacOS/Timbre --debug-window --mock-transcription
Timbre.app/Contents/MacOS/Timbre --debug-window --parakeet-transcription
```

Release builds always use Apple Speech and ignore the debug transcription flags.  
Release builds do **not** show automatic setup or download the Parakeet model.

## Parakeet / FluidAudio (for developers only)

The default app path uses Apple Speech.

### First-run setup (DEBUG, gated)

DEBUG builds can show a small setup window that requests microphone access, then downloads and verifies the Parakeet component (`ensureInstalled`), then releases it from memory.  
Release keeps this off until a later PR makes Parakeet the default engine.

Details: [`docs/SETUP_AND_MODEL_MANAGEMENT.md`](docs/SETUP_AND_MODEL_MANAGEMENT.md).

### Menu-bar opt-in (DEBUG)

Batch microphone dictation through Parakeet is available with `--parakeet-transcription`.  
It uses the shared `ParakeetModelManager.ensureLoaded()` path.  
Full runbook: [`docs/PARAKEET_MICROPHONE_DICTATION.md`](docs/PARAKEET_MICROPHONE_DICTATION.md).

### Smoke CLI

A separate command-line target still verifies model download, cache reuse, and file transcription:

```bash
./scripts/run-parakeet-smoke.sh
```

Full steps: [`docs/PARAKEET_SMOKE_TEST.md`](docs/PARAKEET_SMOKE_TEST.md).
