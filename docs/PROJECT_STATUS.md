# Timbre project status

This document gives context for developers and agents.  
Use this document when you add features or change architecture.  
Do not put long product history in `README.md`.

## Purpose

Timbre is a menu-bar voice dictation app for macOS.  
The user starts a session from the status item.  
The app shows live transcription.  
The user stops the session.  
The app copies the final text to the clipboard.

## Current release

Status: v0.1 prototype.  
You can build on this code.  
The basic dictation flow works with Apple Speech.  
The tests pass.  
The UI and the controller do not depend on a specific speech engine.

## Feature status

### Complete

- Menu-bar-only app with `MenuBarExtra` and `LSUIElement`
- Start and stop dictation from the menu UI
- Live partial transcript and final transcript
- Copy to clipboard and Copy Again
- Microphone and speech permission handling (Apple APIs)
- Swappable transcription protocol
- Mock transcription in DEBUG builds
- Debug window for UI tests in DEBUG builds
- Unit tests and UI tests
- Parakeet / FluidAudio **model download, load, and file-transcription proof** (developer CLI only; see [`PARAKEET_SMOKE_TEST.md`](PARAKEET_SMOKE_TEST.md))

### Not started

- Parakeet live dictation / microphone capture via FluidAudio
- Parakeet implementation of `TranscriptionServicing`
- Replacing Apple Speech as the default engine
- Global keyboard shortcuts
- Floating panel
- Paste into the focused app
- Read or replace selected text
- Text rewrite and LLM features
- Assistant mode and CUA
- Accounts and billing
- DMG packaging, Developer ID signing, and notarization

## Architecture

The app is small and layered.  
Approximate size: 950 lines of Swift (app target).

### Layers

1. Views call `AssistantController`.
2. `AssistantController` owns the session workflow.
3. Transcription uses `TranscriptionServicing`.
4. Clipboard uses `ClipboardServicing`.

Apple Speech lives in `SpeechRecognitionService`.  
A future Parakeet or FluidAudio service can implement the same protocol.  
You do not need to rewrite the menu UI for that change.

The Parakeet smoke harness is intentionally **outside** that protocol for now.  
It is a separate developer CLI that proves offline file transcription only.

### Session model

`SessionState` is one enum with associated values.  
Derive status text, transcript text, and button state from that enum.  
Do not add parallel flags on the controller when you can extend `SessionState`.

### Session safety

`TranscriptionSession` identifies each recording.  
Ignore late callbacks from a cancelled session.  
Those callbacks must not change a newer session.

## Source layout

```
Timbre/
  TimbreApp.swift                 MenuBarExtra and AppDelegate; owns the controller
  AssistantController.swift       Session workflow
  Models/SessionState.swift       Phase model
  Services/
    TranscriptionServicing.swift  Protocol and TranscriptionError
    TranscriptionSession.swift    Per-recording identity and completion
    SpeechRecognitionService.swift
    MockTranscriptionService.swift
    ClipboardServicing.swift
    ClipboardService.swift
  Views/MenuBarDictationView.swift
Tools/ParakeetSmokeTest/
  Sources/                        Developer CLI (FluidAudio only here)
  Fixtures/                       WAV + expected script notes
scripts/run-parakeet-smoke.sh     Builds and runs the smoke CLI
docs/PARAKEET_SMOKE_TEST.md       Smoke-test runbook
TimbreTests/                      Controller and session lifecycle tests
TimbreUITests/                    Debug-window mock test and screenshot attachment
```

## Rules for changes

- Do not couple SwiftUI views to Speech or AVFoundation.
- New speech backends must implement `TranscriptionServicing` when they join the interactive app path.
- Prefer changes to `SessionState` over new controller flags.
- Keep mock transcription and the debug window inside `#if DEBUG`.
- Release builds must use `SpeechRecognitionService` until a later task switches engines.
- Keep FluidAudio linked only to `ParakeetSmokeTest` until a later task adds app integration.
- Keep permission strings in the Xcode target Info settings.
- Keep App Sandbox off unless a later task requires it.

## Out of scope

Do not start these items unless a task asks for them:

- Live Parakeet dictation in the app
- Hotkeys
- Accessibility paste
- Settings screens
- Authentication
- Billing
- Packaging and notarization

## History from the blank template

1. The project replaced `WindowGroup` and Hello World with `MenuBarExtra`.
2. The project added the controller, session model, and clipboard service.
3. The project added a temporary Apple Speech pipeline.
4. The project added the transcription protocol and a mock service.
5. The project added unit tests and one UI test.
6. The project hardened concurrency with `@MainActor` and session tokens.
7. The project added a developer-only Parakeet / FluidAudio file-transcription smoke test.

## Related docs

- Local setup and commands: `README.md`
- Parakeet smoke test: `docs/PARAKEET_SMOKE_TEST.md`
- Repository: https://github.com/awd17/Timbre
