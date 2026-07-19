# Parakeet smoke-test fixture

## Spoken script

```
Timbre smoke test. The quick brown fox jumps over the lazy dog. Please recognize this clear English sentence for Parakeet. This is a local speech recognition proof using Fluid Audio and Core M L.
```

## Source

This file is synthetic speech from macOS `say` (Samantha, rate 160).  
`afconvert` made a 16 kHz mono 16-bit PCM WAV file.

## Soft validation

Make the text simple before you compare:

1. Change all letters to lowercase.
2. Remove punctuation.
3. Make multiple spaces into one space.

Required checks:

- The transcript is not empty.
- The transcript contains `quick brown fox`.
- The transcript contains `lazy dog`.
- The transcript contains one or more of these phrases: `timbre`, `smoke test`, `parakeet`.

Do not require exact punctuation.  
Do not require exact capitalization.
