# Timbre project status

This document gives context for developers and agents.  
Use this document when you add features or change architecture.  
Do not put long product history in `README.md`.

## Purpose

Timbre is a menu-bar voice dictation app for macOS.  
The user starts a session from the status item or the global shortcut.  
The app shows a listening/processing status for Parakeet batch dictation (no live partials).  
The user stops the session.  
The app copies the final text to the clipboard and inserts it into the captured target application when Accessibility trust and target validation allow.

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
- **Focused-app text insertion** via clipboard + Command-V (Accessibility required)
- Microphone permission for the production path
- Accessibility permission for text insertion
- Swappable transcription protocol
- Mock transcription in DEBUG builds
- Debug window for UI tests in DEBUG builds
- Unit tests and UI tests
- Parakeet / FluidAudio model download, load, and file-transcription smoke CLI
- Fixture-through-app gate via `--parakeet-fixture` (service → controller → clipboard)
- **Shared `ParakeetModelManager`** with installed vs loaded states (`ensureInstalled` / `ensureLoaded`)
- **First-run setup in Debug and Release** (welcome → shortcut → mic → text insertion → download/verify → ready)
- Dictation readiness requires installed model, granted microphone, Accessibility trust, and initial shortcut confirmation; a shortcut may later be cleared without reopening onboarding
- **Global dictation shortcut** (temporary default ⌃⇧D via KeyboardShortcuts 2.4.0; onboarding Recorder; toggle Start/Stop)
- **Native Settings** with shared shortcut editing, Dock visibility, safe clipboard-retention policy, and About information
- **Model prewarming** after setup readiness (`loadInstalledAndRetain`; never downloads; Start joins single-flight load)
- **Onboarding visual polish** (branded setup window + background asset)
- **Unified full-app integration lifecycle** (one UI test method; build once and relaunch the same binary)

### Not started / out of this milestone

- Live Parakeet partial transcription / streaming / VAD / auto-stop
- Menu-bar popover redesign (next)
- Floating dictation indicator (later)
- Floating panel
- Read or replace selected text
- Text rewrite and LLM features
- Assistant mode and CUA
- Accounts and billing
- DMG packaging, Developer ID signing, and notarization
- macOS “Timbre is ready” notifications
- Menu-bar visual polish (aligned with onboarding)

## Architecture

The app is small and layered.

### Layers

1. Views and the global shortcut coordinator call `AssistantController` (dictation) and optionally `SetupCoordinator` (first-run).
2. `AssistantController` owns the session workflow.
3. Transcription uses `TranscriptionServicing`.
4. Clipboard uses `ClipboardServicing`.
5. Transcript delivery uses `TranscriptDeliveryServicing` (clipboard + Accessibility + Command-V).
6. `ParakeetModelManager` owns model install/load; setup and Parakeet dictation share it.
7. `ParakeetPrewarmCoordinator` loads the installed model after setup readiness (no download).
8. `DictationShortcutCoordinator` maps hotkey presses to Start/Stop/setup (no FluidAudio coupling).

Backends:

- `ParakeetTranscriptionService` — **default** (Debug and Release; no launch flag required)
- `MockTranscriptionService` — DEBUG `--mock-transcription`
- `SpeechRecognitionService` — DEBUG `--apple-speech` only

Views must not import FluidAudio, AVFoundation, Core ML, or `AsrManager`.

FluidAudio 0.15.5 is linked to both the **Timbre** app target and **ParakeetSmokeTest**.  
KeyboardShortcuts 2.4.0 is linked to the **Timbre** app target only.  
Launch construction is side-effect-free: no mic prompt, download, or model load until setup / prewarm / Start.

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
    ParakeetPrewarmCoordinator.swift
    ModelPreparationState.swift
    MicrophonePermissionProviding.swift
    AccessibilityPermissionProviding.swift
    DictationTargetProviding.swift
    TranscriptDeliveryServicing.swift
    FocusedApplicationTextOutputService.swift
    ClipboardServicing.swift
    ClipboardService.swift
  Shortcuts/
    DictationShortcutName.swift
    GlobalShortcutServicing.swift
    KeyboardShortcutsGlobalShortcutService.swift
    DictationShortcutAction.swift
    DictationShortcutCoordinator.swift
  Setup/
    TimbreSetupFeature.swift
    OnboardingPreferencesProviding.swift
    SetupCoordinator.swift
    SetupWindowController.swift
    SetupFlowView.swift
  Testing/
    IntegrationTestRuntime.swift       DEBUG persistent fake boundaries + JSON probe
  Fixtures/parakeet-smoke-test.wav
  Views/MenuBarDictationView.swift
  Assets.xcassets/OnboardingBackground.imageset/
Tools/ParakeetSmokeTest/
  Sources/                        Developer CLI
  Fixtures/                       WAV file and script notes
scripts/run-parakeet-smoke.sh
scripts/run-full-integration-test.sh
docs/PARAKEET_SMOKE_TEST.md
docs/PARAKEET_MICROPHONE_DICTATION.md
docs/SETUP_AND_MODEL_MANAGEMENT.md
docs/ONBOARDING_UX.md
docs/GLOBAL_DICTATION_SHORTCUT.md
docs/FOCUSED_APP_TEXT_INSERTION.md
docs/FULL_APPLICATION_INTEGRATION_TEST.md
TimbreTests/
TimbreUITests/
```

## Rules for changes

- Do not couple SwiftUI views to Speech or AVFoundation.
- New speech backends must implement `TranscriptionServicing` when they join the interactive app path.
- Prefer changes to `SessionState` over new controller flags.
- Keep mock transcription, Apple Speech override, fixture gate, debug window,
  setup bypass, and the full-app integration runtime inside DEBUG-only paths.
- Parakeet is the production default in Debug and Release; do not silently fall back to Apple Speech.
- Automatic setup is on in Release; DEBUG may bypass it for mock / fixture / `--apple-speech` / `--disable-setup`.
- Distinguish installed (on disk) from loaded (`AsrManager` retained).
- Do not request mic, download, or load the model from app/backend construction at launch.
- Keep the Parakeet smoke CLI working when changing FluidAudio usage.
- Keep permission strings in the Xcode target Info settings.
- Keep App Sandbox off unless a later task requires it.
- Do not paste when a different third-party app is frontmost; keep failed-insertion transcripts recoverable and never overwrite a detected newer clipboard generation.

## Out of scope

Do not start these items unless a task asks for them:

- Live Parakeet partials / streaming ASR
- Direct AX text replacement / selection rewrite
- Additional technical or advanced Settings controls
- Authentication
- Billing
- Packaging and notarization
- Menu-bar visual polish

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
11. The project added a global dictation toggle shortcut (temporary ⌃⇧D).
12. The project added focused-app text insertion (Accessibility + clipboard Command-V).
13. The project added model prewarming after setup readiness to reduce first-Start latency.
14. The project polished first-run onboarding (shortcut step, branded window, simulated onboarding).

## Related docs

- Local setup and commands: `README.md`
- Parakeet smoke test: `docs/PARAKEET_SMOKE_TEST.md`
- Parakeet app mic path: `docs/PARAKEET_MICROPHONE_DICTATION.md`
- Setup / model management: `docs/SETUP_AND_MODEL_MANAGEMENT.md`
- Onboarding UX: `docs/ONBOARDING_UX.md`
- Model prewarming: `docs/MODEL_PREWARMING.md`
- Global shortcut: `docs/GLOBAL_DICTATION_SHORTCUT.md`
- Focused-app insertion: `docs/FOCUSED_APP_TEXT_INSERTION.md`
- Repository: https://github.com/awd17/Timbre
