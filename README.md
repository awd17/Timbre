# Timbre

Menu-bar macOS voice dictation app. Start a session from the status item, see live transcription, stop, and copy the result to the clipboard.

**Repo:** https://github.com/awd17/Timbre

## Current status (v0.1 prototype)

Ready to build on. Core dictation loop works end-to-end with Apple Speech, tests pass, and the UI/controller are decoupled from the transcription backend.

| Area | Status |
|------|--------|
| Menu-bar-only app (`MenuBarExtra`, `LSUIElement`) | Done |
| Start / stop dictation from menu UI | Done |
| Live partial + final transcript | Done |
| Copy to clipboard + Copy Again | Done |
| Mic + speech permission handling | Done (Apple APIs) |
| Swappable transcription protocol | Done |
| Mock transcription (DEBUG) | Done |
| Debug window for UI tests (DEBUG) | Done |
| Unit + UI tests | Done |
| FluidAudio / Parakeet local STT | Not started |
| Global hotkeys | Not started |
| Floating panel / paste into focused app | Not started |
| Read/replace selection, rewrite, LLM | Not started |
| Assistant / CUA / accounts / billing | Not started |
| DMG, Developer ID, notarization | Not started |

**Code shape:** Small layered SwiftUI app (~950 LOC). `AssistantController` owns session workflow; views stay dumb; Apple Speech lives behind `TranscriptionServicing` so a Parakeet/FluidAudio implementation can drop in without rewriting the menu UI. Session state is a single associated-value enum. Per-recording `TranscriptionSession` identity blocks stale callbacks from corrupting a newer session.

## Requirements

- macOS 14.6+
- Xcode 16+
- Apple Development signing team (local run)
- Microphone + Speech Recognition permission when using real transcription

## Setup

```bash
git clone https://github.com/awd17/Timbre.git
cd Timbre
open Timbre.xcodeproj
```

In Xcode: **Timbre** scheme → Signing & Capabilities → your Development Team. App Sandbox is off; `LSUIElement` is on (no Dock icon).

## Build / test / run

```bash
xcodebuild -scheme Timbre -destination 'platform=macOS' build
xcodebuild -scheme Timbre -destination 'platform=macOS' test
```

**Xcode:** ⌘R → waveform status item → Start / Stop / Copy Again / Quit.

| Launch argument | Effect |
|-----------------|--------|
| *(none)* | Real Apple Speech + microphone |
| `--mock-transcription` | **Debug only.** Fake partials/final; no mic |
| `--debug-window` | **Debug only.** “Timbre Debug” window + regular activation policy |

```bash
# Example after a Debug build (path varies by DerivedData)
Timbre.app/Contents/MacOS/Timbre --debug-window --mock-transcription
```

## Layout

```
Timbre/
  TimbreApp.swift                 # MenuBarExtra + AppDelegate (owns controller)
  AssistantController.swift       # Session workflow
  Models/SessionState.swift       # Associated-value phase model
  Services/
    TranscriptionServicing.swift  # Protocol + TranscriptionError
    TranscriptionSession.swift    # Per-recording identity / completion
    SpeechRecognitionService.swift
    MockTranscriptionService.swift
    ClipboardServicing.swift / ClipboardService.swift
  Views/MenuBarDictationView.swift
TimbreTests/                      # Controller + session lifecycle
TimbreUITests/                    # Debug-window mock smoke + screenshot attachment
```

## Agent / contributor notes

- **Do not** couple SwiftUI views to Speech/AVFoundation. New STT backends implement `TranscriptionServicing`.
- Prefer extending `SessionState` over parallel booleans/flags on the controller.
- Mock + debug window are `#if DEBUG` only; Release always uses `SpeechRecognitionService`.
- Permissions: `NSMicrophoneUsageDescription` + `NSSpeechRecognitionUsageDescription` in target Info settings; empty sandbox entitlements.
- Out of scope until explicitly requested: FluidAudio/Parakeet, hotkeys, accessibility paste, settings, auth, billing, packaging/notarization.

## What shipped from the blank Xcode template

1. Replaced `WindowGroup` / Hello World with menu-bar `MenuBarExtra`.
2. Added controller + session model + clipboard service.
3. Temporary Apple Speech pipeline (`SFSpeechRecognizer` + `AVAudioEngine`).
4. Protocol boundary + mock for tests and DEBUG launches.
5. Unit tests (controller + session lifecycle) and one UI test with retained screenshot attachment.
6. Hardening: `@MainActor` speech service, session tokens, DEBUG-only debug harness, `.gitignore`.
