# Timbre project status

This document gives context for developers and agents.  
Use this document when you add features or change architecture.  
Do not put long product history in `README.md`.

## Purpose

Timbre is a menu-bar voice dictation app for macOS.  
The user starts a session from the status item.  
The app shows live transcription (Apple Speech) or a listening/processing status (Parakeet batch).  
The user stops the session.  
The app copies the final text to the clipboard.

## Current release

Status: v0.1 prototype.  
You can build on this code.  
The basic dictation flow works with Apple Speech by default.  
DEBUG builds can opt into Parakeet v2 batch microphone dictation.  
The tests pass.  
The UI and the controller do not depend on a specific speech engine.

## Feature status

### Complete

- Menu-bar-only app with `MenuBarExtra` and `LSUIElement`
- Start and stop dictation from the menu UI
- Live partial transcript and final transcript (Apple Speech)
- Copy to clipboard and Copy Again
- Microphone and speech permission handling (Apple Speech path)
- Swappable transcription protocol
- Mock transcription in DEBUG builds
- Debug window for UI tests in DEBUG builds
- Unit tests and UI tests
- Parakeet / FluidAudio model download, load, and file-transcription smoke CLI
- **DEBUG opt-in Parakeet batch microphone dictation** via `--parakeet-transcription` (`ParakeetTranscriptionService`)
- Fixture-through-app gate via `--parakeet-fixture` (service → controller → clipboard)

### Not started / out of this milestone

- Parakeet as the **default** production engine
- Live Parakeet partial transcription / streaming / VAD / auto-stop
- User-facing model download progress or settings
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

### Layers

1. Views call `AssistantController`.
2. `AssistantController` owns the session workflow.
3. Transcription uses `TranscriptionServicing`.
4. Clipboard uses `ClipboardServicing`.

Backends:

- `SpeechRecognitionService` — default (Debug without flags, and all Release launches)
- `MockTranscriptionService` — DEBUG `--mock-transcription`
- `ParakeetTranscriptionService` — DEBUG `--parakeet-transcription` only (`#if DEBUG`)

Views must not import FluidAudio, AVFoundation, Core ML, or `AsrManager`.

FluidAudio 0.15.5 is linked to both the **Timbre** app target and **ParakeetSmokeTest**.  
Runtime Parakeet selection is DEBUG-only; linking may still affect Release binary size (not claimed as zero without measurement).

### Session model

`SessionState` phases include `preparing`, `listening`, `finishing` (shown as Processing...), `completed`, and `failed`.

### Session safety

`TranscriptionSession` identifies each recording.  
Late callbacks from a cancelled session must not change a newer session.  
Session cancel does not cancel shared Parakeet model preparation.

## Source layout

```
Timbre/
  TimbreApp.swift                 MenuBarExtra and AppDelegate; backend factory
  AssistantController.swift       Session workflow
  Models/SessionState.swift       Phase model
  Services/
    TranscriptionServicing.swift  Protocol and TranscriptionError
    TranscriptionBackendSelection.swift
    TranscriptionSession.swift
    SpeechRecognitionService.swift
    MockTranscriptionService.swift
    ParakeetTranscriptionService.swift  DEBUG only
    ClipboardServicing.swift
    ClipboardService.swift
  Fixtures/parakeet-smoke-test.wav
  Views/MenuBarDictationView.swift
Tools/ParakeetSmokeTest/
  Sources/                        Developer CLI
  Fixtures/                       WAV file and script notes
scripts/run-parakeet-smoke.sh
docs/PARAKEET_SMOKE_TEST.md
docs/PARAKEET_MICROPHONE_DICTATION.md
TimbreTests/
TimbreUITests/
```

## Rules for changes

- Do not couple SwiftUI views to Speech or AVFoundation.
- New speech backends must implement `TranscriptionServicing` when they join the interactive app path.
- Prefer changes to `SessionState` over new controller flags.
- Keep mock transcription, Parakeet selection, and the debug window inside `#if DEBUG`.
- Release builds must use `SpeechRecognitionService` until a later task changes the engine.
- Keep the Parakeet smoke CLI working when changing FluidAudio usage.
- Keep permission strings in the Xcode target Info settings.
- Keep App Sandbox off unless a later task requires it.

## Out of scope

Do not start these items unless a task asks for them:

- Making Parakeet the default engine
- Live Parakeet partials / streaming ASR
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
7. The project added a developer CLI for Parakeet / FluidAudio file transcription.
8. The project added DEBUG opt-in Parakeet batch microphone dictation in the app.

## Related docs

- Local setup and commands: `README.md`
- Parakeet smoke test: `docs/PARAKEET_SMOKE_TEST.md`
- Parakeet app mic path: `docs/PARAKEET_MICROPHONE_DICTATION.md`
- Repository: https://github.com/awd17/Timbre
