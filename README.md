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
- Microphone and Speech Recognition permission for real transcription

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
| *(none)* | Real Apple Speech and microphone |
| `--mock-transcription` | Debug only. Fake transcript. No microphone. |
| `--debug-window` | Debug only. Opens the Timbre Debug window. |

```bash
# Path depends on your DerivedData location
Timbre.app/Contents/MacOS/Timbre --debug-window --mock-transcription
```
