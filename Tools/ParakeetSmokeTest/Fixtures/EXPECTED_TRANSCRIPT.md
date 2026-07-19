# Parakeet smoke-test fixture

## Spoken script

```
Timbre smoke test. The quick brown fox jumps over the lazy dog. Please recognize this clear English sentence for Parakeet. This is a local speech recognition proof using Fluid Audio and Core M L.
```

## Source

Synthetic macOS `say` speech (Samantha, rate 160), converted to 16 kHz mono 16-bit PCM WAV via `afconvert`.

## Soft validation

Normalization: lowercase, strip punctuation, collapse whitespace.

Required:

- Non-empty transcript
- Substring `quick brown fox`
- Substring `lazy dog`
- At least one of: `timbre`, `smoke test`, `parakeet`

Exact punctuation and capitalization are not required.
