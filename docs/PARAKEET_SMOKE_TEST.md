# Parakeet smoke test (for developers only)

This test shows that FluidAudio can download, store, load, and transcribe with the English Parakeet TDT 0.6B v2 Core ML model in this repository.

For DEBUG opt-in Parakeet batch dictation inside the menu-bar app (including a fixture-through-app gate), see [`PARAKEET_MICROPHONE_DICTATION.md`](PARAKEET_MICROPHONE_DICTATION.md).  
This smoke CLI remains the file-only developer check and must keep working.

## Versions

| Item | Value |
|------|--------|
| FluidAudio (SPM) | 0.15.5 (`19600a485baa4998812e4654b70d2bab8f2c9949`) |
| Model | `FluidInference/parakeet-tdt-0.6b-v2-coreml` through `AsrModelVersion.v2` |
| Pin file | [`Timbre.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`](../Timbre.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved) |

## How to run

Start from the root of the repository.

```bash
./scripts/run-parakeet-smoke.sh
```

The script does this work:

1. It finds the repository root from the script path.
2. It builds the `ParakeetSmokeTest` Xcode scheme into `.derivedData/ParakeetSmokeTest`.
3. It starts the program with `--audio <absolute-path-to-fixture>`.

The program returns exit code `0` only when these steps succeed:

- Model preparation
- Transcription
- Soft validation

## Fixture

| Item | Path or value |
|------|----------------|
| WAV | [`Tools/ParakeetSmokeTest/Fixtures/parakeet-smoke-test.wav`](../Tools/ParakeetSmokeTest/Fixtures/parakeet-smoke-test.wav) |
| Script notes | [`Tools/ParakeetSmokeTest/Fixtures/EXPECTED_TRANSCRIPT.md`](../Tools/ParakeetSmokeTest/Fixtures/EXPECTED_TRANSCRIPT.md) |
| Format | WAVE, 1 channel, 16 kHz, Int16 PCM |
| Duration | About 12.8 s (`afinfo` check) |

Spoken script:

```text
Timbre smoke test. The quick brown fox jumps over the lazy dog. Please recognize this clear English sentence for Parakeet. This is a local speech recognition proof using Fluid Audio and Core M L.
```

Soft validation rules (after you make case, punctuation, and spaces simple):

- The transcript is not empty.
- The transcript contains `quick brown fox`.
- The transcript contains `lazy dog`.
- The transcript contains one or more of these phrases: `timbre`, `smoke test`, `parakeet`.

## Model cache

Data from one clean first run on this computer:

| Item | Value |
|------|--------|
| Cache directory | `~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v2` |
| Local size (all files) | 464,413,250 bytes (about 464.4 MB) |
| Hugging Face size note | About 2.5 GB is only an estimate. Use the local size. |

### First run and second run

| Metric | First run | Second run |
|--------|-----------|------------|
| `cache_directory_existed_before` | false | true |
| `models_available_before` | false | true |
| Cache size before and after | 0 to 464.4 MB | 464.4 MB to 464.4 MB |
| `cache_grew_meaningfully` | true | false |
| `likely_cache_reuse` | false | true |
| Download and model preparation | About 269.8 s | About 0.40 s |
| Transcription time | About 0.30 s | About 0.37 s |

On the second run, FluidAudio wrote these messages:

- `ASR models already present`
- `Found parakeet-tdt-0.6b-v2 locally, no download needed`

### Remove the cache

Use this command to remove the cache and force a new download:

```bash
rm -rf "$HOME/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v2"
```

This command was tested after the smoke runs.  
The directory was removed.  
Do not use a FluidAudio cache API for this step. This document does not describe one.

## Isolation from Timbre.app

- `ParakeetSmokeTest` is a separate macOS command-line target.
- Only that target links FluidAudio.
- The Timbre scheme does not build or archive `ParakeetSmokeTest`.
- `otool -L` on `Timbre.app` does not show a FluidAudio library.
- `nm` on `Timbre.app` does not show FluidAudio or Parakeet symbols.
- Timbre unit tests do not download models.

Xcode can still resolve the FluidAudio package when you open or build the project.  
That occurs because the package reference is at the project level.  
The Timbre app does not link FluidAudio.  
The Timbre app does not run FluidAudio.

## License and credit

- FluidAudio: read the license in the FluidAudio repository.
- Parakeet TDT 0.6B v2 Core ML (`FluidInference/parakeet-tdt-0.6b-v2-coreml`): CC-BY-4.0 on Hugging Face. The model is based on NVIDIA Parakeet. FluidInference made the Core ML conversion.

## Work that is not in this task

- Parakeet microphone capture
- Live or partial Parakeet transcription
- Parakeet support for `TranscriptionServicing`
- Replacement of Apple Speech in the default app path
- Onboarding or download progress UI
- Model selection, settings, hotkeys, text insertion, or LLM features

## If the test fails

If `./scripts/run-parakeet-smoke.sh` fails after a clean clone, run FluidAudio CLI on the same fixture.  
Use that result to find if the fault is in FluidAudio or in the Timbre Xcode setup.  
Keep the Timbre smoke target as the standard repeatable test.
