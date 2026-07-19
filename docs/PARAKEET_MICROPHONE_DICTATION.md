# Parakeet microphone dictation (DEBUG)

Opt-in batch Parakeet v2 dictation in the Timbre menu-bar app via FluidAudio 0.15.5.

Apple Speech remains the default engine. Live Parakeet partials are **not** implemented.

## Launch arguments (DEBUG only)

| Argument | Effect |
|----------|--------|
| *(none)* | Apple Speech + microphone |
| `--mock-transcription` | Fake transcript (no mic). Wins if combined with `--parakeet-transcription`. |
| `--parakeet-transcription` | Parakeet v2 batch transcription after Stop |
| `--parakeet-fixture` | With `--parakeet-transcription`: run the committed WAV through the full app path (service → controller → clipboard). No microphone. |
| `--debug-window` | Opens the Timbre Debug window |

Release builds always use Apple Speech and ignore these flags.

### Examples

```bash
# Path depends on DerivedData
Timbre.app/Contents/MacOS/Timbre --debug-window --parakeet-transcription

# Deterministic app-path gate (no speaking required)
Timbre.app/Contents/MacOS/Timbre --debug-window --parakeet-transcription --parakeet-fixture
```

Backend selection is centralized in `TranscriptionBackendSelection`.

## Backend selection priority (DEBUG)

1. `--mock-transcription` → mock (explicit priority over Parakeet)
2. `--parakeet-transcription` → Parakeet
3. else → Apple Speech

## Model preparation

Shared `ParakeetModelManager` owns the lifecycle:

- Cache probe: `AsrModels.modelsExist` / `defaultCacheDirectory(for: .v2)`
- Download/load: `AsrModels.downloadAndLoad(version: .v2)`
- Cache: `~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v2`
- Dictation calls `ensureLoaded()` and **retains** `AsrManager` across sessions.
- DEBUG first-run setup (when gated on) calls `ensureInstalled()`: verify then **release** memory so Apple Speech builds do not keep Parakeet resident after setup.
- Cancelling a dictation session does **not** cancel shared model preparation.

Requires Apple Silicon.

See [`SETUP_AND_MODEL_MANAGEMENT.md`](SETUP_AND_MODEL_MANAGEMENT.md).

## Fixture gate (Checkpoint 2)

Before relying on microphone capture, verify:

```bash
xcodebuild -scheme Timbre -destination 'platform=macOS' -derivedDataPath .derivedData/Timbre build
.derivedData/Timbre/Build/Products/Debug/Timbre.app/Contents/MacOS/Timbre \
  --debug-window --parakeet-transcription --parakeet-fixture
```

Look for `Timbre Parakeet fixture: PASS` in the console. Soft checks match the smoke fixture (non-empty; contains `quick brown fox`, `lazy dog`, and one of `timbre` / `smoke test` / `parakeet`).

The fixture WAV is bundled from `Timbre/Fixtures/parakeet-smoke-test.wav` (copy of the smoke-test fixture).

## Microphone dictation flow

1. Start → Preparing (mic permission + model readiness)
2. Listening (no live transcript text)
3. Stop → Processing (convert snapshot → Parakeet inference)
4. Completed → transcript copied to clipboard
5. Copy Again works as usual

Permissions: **microphone only** (no Speech Recognition authorization on this path).

Capture uses `AVAudioEngine` with a serial queue for converted mono Float32 @ 16 kHz samples. On Stop: remove tap → stop engine → drain queue → immutable snapshot → clear → transcribe.

## Minimum recording length (experimental)

FluidAudio 0.15.5 defines:

- `ASRConstants.minimumAudioDurationSeconds = 0.3`
- `ASRConstants.minimumRequiredSamples(forSampleRate:)` → 4800 samples at 16 kHz

Timbre maps shorter captures to `TranscriptionError.emptyResult` (no clipboard write). This threshold comes from the pinned FluidAudio source, not a Timbre product requirement. Re-check after upgrading FluidAudio.

## Termination and cancel

- Session `cancel` / Stop cleanup releases the microphone and invalidates that session.
- Shared model download/load is left running.
- App quit calls synchronous `shutdownForTermination()` from `applicationShouldTerminate` so the mic indicator can turn off before exit.

## Limitations

- DEBUG opt-in only; not the production default
- Batch after Stop only (no live partials, streaming, VAD, or auto-stop)
- FluidAudio is linked into the Timbre app target for both Debug and Release in this milestone so the DEBUG Parakeet path can share the same package pin. Release builds never select Parakeet at runtime, but the Release binary still links FluidAudio (observed via linked symbols). Accept that link cost for now; gating the dependency by configuration is a follow-up.
- First-run setup / install UI is DEBUG-gated; not shown automatically in Release

## Related

- Smoke CLI (file-only): [`PARAKEET_SMOKE_TEST.md`](PARAKEET_SMOKE_TEST.md)
- Setup / model management: [`SETUP_AND_MODEL_MANAGEMENT.md`](SETUP_AND_MODEL_MANAGEMENT.md)
- Project status: [`PROJECT_STATUS.md`](PROJECT_STATUS.md)
