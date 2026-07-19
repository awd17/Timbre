# Parakeet microphone dictation

Production Parakeet v2 batch dictation in the Timbre menu-bar app via FluidAudio 0.15.5.

Live Parakeet partials are **not** implemented. After Stop, Timbre runs local inference and copies the transcript.

## Launch arguments

| Argument | Effect |
|----------|--------|
| *(none)* | **Parakeet** + microphone (Debug and Release default) |
| `--mock-transcription` | Debug only. Fake transcript (no mic). Disables setup. |
| `--apple-speech` | Debug only. Apple Speech comparison backend. Disables Parakeet setup. |
| `--parakeet-fixture` | Debug only. Run the committed WAV through the full app path (no mic). Disables setup. |
| `--parakeet-transcription` | Deprecated no-op; Parakeet is already the default (logged once). |
| `--debug-window` | Debug only. Opens the Timbre Debug window |
| `--disable-setup` | Debug only. Disables automatic first-run setup |

Release builds ignore DEBUG-only flags and always use Parakeet with setup enabled when needed.

### Examples

```bash
# Path depends on DerivedData — normal production path (no flags)
Timbre.app/Contents/MacOS/Timbre

# Deterministic app-path gate (no speaking required)
Timbre.app/Contents/MacOS/Timbre --debug-window --parakeet-fixture

# Apple Speech comparison (DEBUG)
Timbre.app/Contents/MacOS/Timbre --debug-window --apple-speech
```

Backend selection is centralized in `TranscriptionBackendSelection`.

## Backend selection priority (DEBUG)

1. `--parakeet-fixture` → Parakeet (fixture audio source)
2. `--mock-transcription` → mock
3. `--apple-speech` → Apple Speech
4. else → Parakeet default

Release always resolves to Parakeet.

There is **no silent fallback** to Apple Speech when Parakeet setup, loading, or transcription fails.

## Model preparation

Shared `ParakeetModelManager` owns the lifecycle:

- Cache probe: `AsrModels.modelsExist` / `defaultCacheDirectory(for: .v2)`
- Download/load: `AsrModels.downloadAndLoad(version: .v2)`
- Cache: `~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v2`
- Constructing the manager/service at launch does **not** download or load the model.
- Setup calls `ensureInstalled()`: verify then **release** memory.
- Dictation `prepare()` calls `ensureLoaded()` and **retains** `AsrManager` across sessions.
- Cancelling a dictation session does **not** cancel shared model preparation.

Requires Apple Silicon.

See [`SETUP_AND_MODEL_MANAGEMENT.md`](SETUP_AND_MODEL_MANAGEMENT.md).

## Fixture gate

Before relying on microphone capture, verify (DEBUG):

```bash
xcodebuild -scheme Timbre -destination 'platform=macOS' -derivedDataPath .derivedData/Timbre build
.derivedData/Timbre/Build/Products/Debug/Timbre.app/Contents/MacOS/Timbre \
  --debug-window --parakeet-fixture
```

Look for `Timbre Parakeet fixture: PASS` in the console. Soft checks match the smoke fixture (non-empty; contains `quick brown fox`, `lazy dog`, and one of `timbre` / `smoke test` / `parakeet`).

The fixture WAV is bundled from `Timbre/Fixtures/parakeet-smoke-test.wav` (copy of the smoke-test fixture).

## Microphone dictation flow

Start and Stop may come from the menu or the global shortcut (`⌃⇧D`; see [`GLOBAL_DICTATION_SHORTCUT.md`](GLOBAL_DICTATION_SHORTCUT.md)). Both paths use `AssistantController`.

1. Start → Preparing (mic permission + `ensureLoaded()`)
2. Listening (no live transcript text)
3. Stop → Processing (convert snapshot → Parakeet inference)
4. Completed → transcript copied to clipboard
5. Copy Again works as usual
6. A second Start reuses the loaded manager (no redownload)

Permissions: **microphone only** (no Speech Recognition authorization on the production path).

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

- Batch after Stop only (no live partials, streaming, VAD, or auto-stop)
- Apple Silicon required
- First model download is large (~464 MB)
- No global shortcut, floating panel, or focused-app paste yet

## Related

- Smoke CLI (file-only): [`PARAKEET_SMOKE_TEST.md`](PARAKEET_SMOKE_TEST.md)
- Setup / model management: [`SETUP_AND_MODEL_MANAGEMENT.md`](SETUP_AND_MODEL_MANAGEMENT.md)
- Project status: [`PROJECT_STATUS.md`](PROJECT_STATUS.md)
