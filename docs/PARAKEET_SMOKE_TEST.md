# Parakeet smoke test (developer only)

This proves FluidAudio can download, cache, load, and file-transcribe the English Parakeet TDT 0.6B v2 Core ML model inside the Timbre repository. It does **not** wire Parakeet into the menu-bar dictation app.

## Versions

| Item | Value |
|------|--------|
| FluidAudio (SPM) | **0.15.5** (`19600a485baa4998812e4654b70d2bab8f2c9949`) |
| Model | `FluidInference/parakeet-tdt-0.6b-v2-coreml` via `AsrModelVersion.v2` |
| Pin file | [`Timbre.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`](../Timbre.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved) |

## How to run

From the repository root:

```bash
./scripts/run-parakeet-smoke.sh
```

The script:

1. Locates the repo root from its own path
2. Builds the `ParakeetSmokeTest` Xcode scheme into `.derivedData/ParakeetSmokeTest`
3. Runs the executable with `--audio <absolute-path-to-fixture>`

Exit `0` only when model preparation, transcription, and soft validation all succeed.

## Fixture

| Item | Path / value |
|------|----------------|
| WAV | [`Tools/ParakeetSmokeTest/Fixtures/parakeet-smoke-test.wav`](../Tools/ParakeetSmokeTest/Fixtures/parakeet-smoke-test.wav) |
| Script notes | [`Tools/ParakeetSmokeTest/Fixtures/EXPECTED_TRANSCRIPT.md`](../Tools/ParakeetSmokeTest/Fixtures/EXPECTED_TRANSCRIPT.md) |
| Format | WAVE, 1 ch, 16 kHz, Int16 PCM |
| Duration | ~12.8 s (validated with `afinfo`) |

Spoken script:

```text
Timbre smoke test. The quick brown fox jumps over the lazy dog. Please recognize this clear English sentence for Parakeet. This is a local speech recognition proof using Fluid Audio and Core M L.
```

Soft validation (after normalizing case/punctuation/whitespace):

- Non-empty transcript
- Contains `quick brown fox`
- Contains `lazy dog`
- Contains at least one of `timbre`, `smoke test`, or `parakeet`

## Model cache

Measured on a clean first run (this machine):

| Item | Value |
|------|--------|
| Cache directory | `~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v2` |
| Measured recursive size | **464,413,250 bytes (~464.4 MB)** |
| Hugging Face listing size | ~2.5 GB is only an expectation; use the measured local size |

### First run vs cached run (observed)

| Metric | First run | Second run |
|--------|-----------|------------|
| `cache_directory_existed_before` | false | true |
| `models_available_before` | false | true |
| Cache size before → after | 0 → 464.4 MB | 464.4 MB → 464.4 MB |
| `cache_grew_meaningfully` | true | false |
| `likely_cache_reuse` | false | true |
| Download + model preparation | ~269.8 s | ~0.40 s |
| Transcription wall time | ~0.30 s | ~0.37 s |

FluidAudio logs on the second run included `ASR models already present` / `Found parakeet-tdt-0.6b-v2 locally, no download needed`.

### Clear the cache (tested)

To force a clean re-download:

```bash
rm -rf "$HOME/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v2"
```

This exact command was tested after the smoke runs: the directory was removed successfully. No FluidAudio cache-clearing API was used or documented here.

## Isolation from Timbre.app

- `ParakeetSmokeTest` is a separate macOS command-line target
- FluidAudio links **only** to that target
- The Timbre scheme does not build or archive `ParakeetSmokeTest`
- `otool -L` on `Timbre.app` shows no FluidAudio dylib; `nm` shows no FluidAudio/Parakeet symbols
- Ordinary Timbre unit tests do not download models

Xcode may still *resolve* the FluidAudio package when opening/building the project (project-level SPM reference), but Timbre does not link or execute it.

## Licensing / attribution

- FluidAudio: see the upstream repository license
- Parakeet TDT 0.6B v2 Core ML (`FluidInference/parakeet-tdt-0.6b-v2-coreml`): **CC-BY-4.0** on Hugging Face; based on NVIDIA Parakeet; Core ML conversion by FluidInference

## Intentionally unimplemented

- Parakeet microphone capture
- Live / partial Parakeet transcription
- `TranscriptionServicing` conformance for Parakeet
- Replacing Apple Speech in the normal app
- Onboarding / download progress UI
- Model selection, settings, hotkeys, insertion, LLM features

## Troubleshooting

If `./scripts/run-parakeet-smoke.sh` fails after a clean clone, inspect FluidAudio’s own CLI against the same fixture to separate package/model issues from Timbre Xcode wiring. The Timbre smoke target remains the supported repeatable proof.
