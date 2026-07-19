# Timbre project status

This document gives context for developers and agents.  
Use this document when you add features or change architecture.  
Do not put long product history in `README.md`.

## Purpose

Timbre is a menu-bar voice dictation app for macOS.  
The user starts a session from the status item.  
The app shows a listening/processing status for Parakeet batch dictation (no live partials).  
The user stops the session.  
The app copies the final text to the clipboard.

## Current release

Status: v0.1 prototype.  
You can build on this code.  
**Parakeet v2 is the default production dictation engine** in Debug and Release.  
First-run setup downloads and verifies the model when needed (including Release).  
Apple Speech remains available only as an explicit DEBUG comparison backend (`--apple-speech`).  
The tests pass.  
The UI and the controller do not depend on a specific speech engine.

## Feature status

### Complete

- Menu-bar-only app with `MenuBarExtra` and `LSUIElement`
- Start and stop dictation from the menu UI
- Parakeet batch transcription after Stop (production default)
- Copy to clipboard and Copy Again
- Microphone permission for the production path
- Swappable transcription protocol
- Mock transcription in DEBUG builds
- Debug window for UI tests in DEBUG builds
- Unit tests and UI tests
- Parakeet / FluidAudio model download, load, and file-transcription smoke CLI
- Fixture-through-app gate via `--parakeet-fixture` (service → controller → clipboard)
- **Shared `ParakeetModelManager`** with installed vs loaded states (`ensureInstalled` / `ensureLoaded`)
- **First-run setup in Debug and Release** (welcome → mic → download/verify → ready)
- Dictation readiness requires installed model **and** granted microphone permission

### Not started / out of this milestone

- Live Parakeet partial transcription / streaming / VAD / auto-stop
- Full Settings screen / user model controls
- Global keyboard shortcuts
- Floating panel
- Paste into the focused app
- Read or replace selected text
- Text rewrite and LLM features
- Assistant mode and CUA
- Accounts and billing
- DMG packaging, Developer ID signing, and notarization
- macOS “Timbre is ready” notifications

## Architecture

The app is small and layered.

### Layers

1. Views call `AssistantController` (dictation) and optionally `SetupCoordinator` (first-run).
2. `AssistantController` owns the session workflow.
3. Transcription uses `TranscriptionServicing`.
4. Clipboard uses `ClipboardServicing`.
5. `ParakeetModelManager` owns model install/load; setup and Parakeet dictation share it.

Backends:

- `ParakeetTranscriptionService` — **default** (Debug and Release; no launch flag required)
- `MockTranscriptionService` — DEBUG `--mock-transcription`
- `SpeechRecognitionService` — DEBUG `--apple-speech` only

Views must not import FluidAudio, AVFoundation, Core ML, or `AsrManager`.

FluidAudio 0.15.5 is linked to both the **Timbre** app target and **ParakeetSmokeTest**.  
Launch construction is side-effect-free: no mic prompt, download, or model load until setup / Start.

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
    SpeechRecognitionService.swift  DEBUG Apple Speech comparison
    MockTranscriptionService.swift
    ParakeetTranscriptionService.swift  production default
    ParakeetModelManaging.swift
    ParakeetModelManager.swift
    ModelPreparationState.swift
    MicrophonePermissionProviding.swift
    ClipboardServicing.swift
    ClipboardService.swift
  Setup/
    TimbreSetupFeature.swift
    SetupCoordinator.swift
    SetupWindowController.swift
    SetupFlowView.swift
  Fixtures/parakeet-smoke-test.wav
  Views/MenuBarDictationView.swift
Tools/ParakeetSmokeTest/
  Sources/                        Developer CLI
  Fixtures/                       WAV file and script notes
scripts/run-parakeet-smoke.sh
docs/PARAKEET_SMOKE_TEST.md
docs/PARAKEET_MICROPHONE_DICTATION.md
docs/SETUP_AND_MODEL_MANAGEMENT.md
TimbreTests/
TimbreUITests/
```

## Rules for changes

- Do not couple SwiftUI views to Speech or AVFoundation.
- New speech backends must implement `TranscriptionServicing` when they join the interactive app path.
- Prefer changes to `SessionState` over new controller flags.
- Keep mock transcription, Apple Speech override, fixture gate, debug window, and setup-bypass flags inside DEBUG-only paths.
- Parakeet is the production default in Debug and Release; do not silently fall back to Apple Speech.
- Automatic setup is on in Release; DEBUG may bypass it for mock / fixture / `--apple-speech` / `--disable-setup`.
- Distinguish installed (on disk) from loaded (`AsrManager` retained).
- Do not request mic, download, or load the model from app/backend construction at launch.
- Keep the Parakeet smoke CLI working when changing FluidAudio usage.
- Keep permission strings in the Xcode target Info settings.
- Keep App Sandbox off unless a later task requires it.

## Out of scope

Do not start these items unless a task asks for them:

- Live Parakeet partials / streaming ASR
- Hotkeys
- Accessibility paste
- Full Settings screens
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
9. The project added gated first-run setup and a shared Parakeet model manager (installed vs loaded).
10. The project made Parakeet the production default and enabled setup in Release.

## Related docs

- Local setup and commands: `README.md`
- Parakeet smoke test: `docs/PARAKEET_SMOKE_TEST.md`
- Parakeet app mic path: `docs/PARAKEET_MICROPHONE_DICTATION.md`
- Setup / model management: `docs/SETUP_AND_MODEL_MANAGEMENT.md`
- Repository: https://github.com/awd17/Timbre
