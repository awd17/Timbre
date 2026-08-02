# Model prewarming

Developer notes for Timbre’s background Parakeet load that reduces first-Start latency.

## Status

As soon as the model is installed, Timbre loads it into memory in the background. The production hotkey is registered only after that retained load completes. This hides the one-time compile in app startup and guarantees both Start and Processing use the warm manager.

The DEBUG full-app integration runtime prewarms its persistent fake model. It
never accesses FluidAudio or the network, but exercises the same readiness and
prewarm orchestration as production.

## Why first Start was previously slow

Setup only calls `ensureInstalled()`: download/verify, then **release** the in-memory `AsrManager` (state → `installed`).

The first Start called `ensureLoaded()`, which compiled/loaded Core ML models into memory. That cost showed up as a long Preparing phase before Listening. Later Starts in the same process reused the retained manager and were much faster.

## When prewarming begins

```text
App launches
→ Setup reconciles readiness
→ Model detected on disk (cacheExists → installed)
→ ParakeetPrewarmCoordinator calls loadInstalledAndRetain()
→ AsrManager retained (state → loaded)
```

Loading the model into memory needs no microphone or Accessibility permission,
so prewarming is **not** gated on full setup readiness. It starts as soon as the
model is known to be on disk:

- Launch readiness (if the model is already installed)
- The model becoming installed during setup (including a background download
  that finishes after the setup window was closed)
- Setup becoming Ready (first-install completion)

This means the first-ever cold Core ML/ANE compile (~35s on a fresh bundle,
`~/Library/Caches/<bundle>/com.apple.e5rt.e5bundlecache`) happens in the
background during first-run setup instead of stalling the first dictation's
Preparing phase.

First-run onboarding also loads the model inside its "Preparing" step
(`SetupCoordinator.perform(.installModel)` calls `loadInstalledAndRetain()`
after `ensureInstalled()`), so the first dictation after Ready reuses the
retained manager. That call and the coordinator's load share one single-flight
load, so they never compile twice.

Prewarming does **not** start from SwiftUI `onAppear`, object construction, or
stale readiness checked before an async refresh finishes.

Repeated activations and readiness notifications are deduplicated: only a
transition into eligibility starts proactive load.

## Never downloads

Prewarm uses `ParakeetModelManaging.loadInstalledAndRetain()`:

1. Rechecks the real on-disk cache
2. Loads only from verified local files (`AsrModels.load(from:)`)
3. If loading fails, validates the cache instead of treating file presence as validity
4. If missing/invalid → removes the invalid cache, throws `ParakeetModelError.modelNotInstalled`, sets `notInstalled`, **does not download**
5. Setup reconciles through the normal recovery path

Dictation Start still uses `ensureLoaded()`, which may download if the user starts while the cache is missing.

## Installed vs loaded

| State | Meaning |
|-------|---------|
| `installed` | On disk; no retained manager |
| `loading` | Install/verify compile (setup Preparing UI) |
| `loaded` | `AsrManager` retained |

An in-memory load from an existing cache leaves the public state at `installed`; the private
single-flight record represents that work. This keeps disk readiness separate from memory activity,
so setup stays Ready without adding a second lifecycle axis. Microphone and Accessibility remain
independent readiness requirements while the load is in flight.

## Single-flight with Start

`ensureLoaded()` and `loadInstalledAndRetain()` share one owned load flight and one retained manager.
The flight records its capability (installed-only or download-if-missing), classifies its result once,
and is the only code allowed to clear itself.

| Scenario | Behavior |
|----------|----------|
| Prewarm completes | Hotkey registers; Start and Stop reuse the loaded manager |
| Prewarm is active | Menu shows “Starting dictation engine…”; production hotkey is not registered yet |
| Load succeeds | One manager; later Starts reuse it |
| Cached-only flight finds corruption while Start is waiting | Start performs one clean repair download |
| Coordinator await cancelled | Shared manager load continues |

## Failure policy

**Transient** (cache still valid):

- Log the error
- State → `installed`
- Dictation controls stay available
- Next Start retries via `ensureLoaded()`
- No launch alert

**Invalid install** (missing/corrupt cache):

- No download from prewarm
- Validate and remove the corrupt cache
- State → `notInstalled` (setup reconciles)
- No separate prewarm error UI / launch alert

## Memory tradeoff

Prewarming keeps one `AsrManager` for the process lifetime (acceptable for this PR). No inactivity unload or memory-pressure policy yet.

Approximate expectations (measure on your machine; Core ML residency varies):

| Condition | What to record |
|-----------|----------------|
| Installed, unloaded | Activity Monitor memory for Timbre |
| After prewarm / first load | Same, after `Timbre model: loaded ASR manager retained` |
| After 2+ dictation sessions | Confirm no second load log and stable memory |

## DEBUG disable flag

```text
--disable-model-prewarm
```

- DEBUG only; ignored in Release
- Disables proactive background loading only
- Does not change Start’s `ensureLoaded()` behavior
- Useful for before/after latency comparison

## Measured latency

Record Start → Listening from stderr / Preparing UI. Example procedure:

1. Quit Timbre. Launch with `--disable-model-prewarm`. Wait until Ready. Press ⌃⇧D immediately. Note Preparing → Listening.
2. Quit. Launch normally (prewarm enabled). Wait for `Timbre prewarm: completed in …s`. Press ⌃⇧D. Note Start → Listening.
3. Quit. Launch normally and try ⌃⇧D during active prewarm. Confirm no dictation starts, the menu reports “Starting dictation engine…”, and the shortcut begins working after the retained load completes.

| Scenario | How to read |
|----------|-------------|
| Warm-cache load duration | `Timbre prewarm: completed in Xs` or model load logs |
| First Start → Listening (prewarm disabled) | Baseline |
| First Start → Listening (after prewarm) | Should be substantially shorter |
| Shortcut during prewarm | No session starts; registration waits for the retained load |

Fill in machine-specific numbers when verifying locally. Success requires measured improvement, not only a “loaded” log line.

### Captured in this PR’s automated verification

- Unit tests: TimbreTests green across repeated runs. The real `ParakeetModelManager` is exercised through an injected FluidAudio boundary for concurrent flights, corrupt-cache invalidation, transient failures, and install repair. A focused transcription startup test verifies Start reuses a retained prewarmed manager without another load.
- Debug and Release app builds succeed.
- Warm on-disk cache model preparation (ParakeetSmokeTest, cache reuse): **~0.66s** download/load preparation on the development machine (`download_and_model_preparation_seconds: 0.656`). This is a lower bound for in-process `ensureLoaded` / prewarm cost; app Start→Listening also includes mic prepare and UI transitions.
- GUI Start→Listening wall times and Activity Monitor memory: run the manual procedure above; record machine-specific before/after values when verifying interactively.

Example log lines to collect during manual timing:

```text
Timbre prewarm: requested (launchReadiness).
Timbre model: loading installed cache into memory.
Timbre model: loaded ASR manager retained.
Timbre prewarm: completed in N.NNs.
```

## Logging

Look for `Timbre prewarm:` and `Timbre model:` on stderr:

- Eligibility / ineligibility reason
- Trigger source
- Requested / duplicate ignored / already loaded / already in flight
- Completed duration
- Failure (transient vs missing)

## Known limitations

- Load still runs on the main actor (FluidAudio / manager are `@MainActor`); measure Ready/menu responsiveness during load.
- No unload-on-idle.
- Fixture, mock, Apple Speech, and setup-disabled DEBUG paths do not prewarm.
- The full-app integration path prewarms the persistent fake model through the production coordinator.
- Does not redesign the menu popover.

## Related

- [`SETUP_AND_MODEL_MANAGEMENT.md`](SETUP_AND_MODEL_MANAGEMENT.md)
- [`ONBOARDING_UX.md`](ONBOARDING_UX.md)
- [`PARAKEET_MICROPHONE_DICTATION.md`](PARAKEET_MICROPHONE_DICTATION.md)
- [`PROJECT_STATUS.md`](PROJECT_STATUS.md)
