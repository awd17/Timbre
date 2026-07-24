# Full application integration test

Timbre has one UI integration test method:
`TimbreUITests.testFullApplicationLifecycle`. Focused unit tests remain in
`TimbreTests`.

Run the complete suite from Terminal:

```bash
scripts/run-full-integration-test.sh
```

The script uses `build-for-testing` once and then `test-without-building`.
Every terminate/relaunch inside the UI test therefore opens the exact app
binary produced by the first command.

## What the lifecycle covers

The test runs without microphone, Accessibility, model downloads, or manual
input. It verifies:

- foreground onboarding, shortcut recording, permission denial/recovery,
  fake progress, one failed install, retry, Ready, and Done;
- background onboarding, setup dismissal/reopen, conditional setup command, the real
  status item, and a single uninterrupted install;
- the native compact menu and real Carbon registration of the isolated
  `⌃⇧K` shortcut;
- deterministic partial/final transcription, captured TextEdit identity,
  isolated pasteboard output, the Command-V probe, and Copy Last Dictation;
- busy-state deduplication, menu-bar-only relaunch without rebuilding,
  persisted shortcut/model state, and setup recovery without redownload;
- safe clipboard fallback for target changes, terminated targets,
  Accessibility revocation, secure input, pasteboard races, and event-post
  failure;
- clean Quit behavior.

Global shortcut start/stop events are sent through XCTest's keyboard API, so
the runner does not need Accessibility or Input Monitoring authorization.
Busy-state bursts are armed through the integration probe sidecar and replayed
immediately after the next real Carbon key-up.

The test stops at the final Command-V posting boundary. It proves Timbre
validated the original target and issued the insertion request with the exact
the isolated pasteboard text; it does not read or overwrite the developer's
general pasteboard and does not claim macOS accepted a synthetic paste.

## DEBUG integration runtime

The runtime is selected only when the Debug app receives
`--integration-test`. It uses these environment variables:

| Variable | Purpose |
|----------|---------|
| `TIMBRE_INTEGRATION_PROFILE` | Unique persistent defaults profile |
| `TIMBRE_INTEGRATION_SCENARIO` | Typed scripted scenario |
| `TIMBRE_INTEGRATION_RESET` | Clear only the selected profile and isolated shortcut |
| `TIMBRE_INTEGRATION_MENU_HOST` | Show the production menu view in a stable window |
| `TIMBRE_INTEGRATION_PROBE` | Absolute path for atomic JSON probe output |

Scenarios are `foregroundOnboarding`, `backgroundOnboarding`, `normal`,
`clearShortcut`, `microphoneRevoked`, `accessibilityRevoked`,
`accessibilityRevokedDuringDelivery`, `secureInput`, `pasteboardRace`, and
`eventPostFailure`. The final internal `cleanup` scenario removes the selected
profile, probe, and isolated shortcut during controlled Quit.

The runtime uses a dedicated defaults suite and
`KeyboardShortcuts.Name.integrationTestToggleDictation`; it never changes
`.toggleDictation`, production onboarding preferences, or the FluidAudio
cache. Model and permission providers are scripted, transcription is
deterministic, and only `PasteCommandEventPosting` is replaced in the
production delivery path. The JSON probe persists across relaunches and
records generation, model state, install/session counts, paste attempts,
paste text, and the exact delivery result.

The optional host is not a test-specific menu implementation. It renders the
same `MenuBarMenuView` commands used by `MenuBarExtra`; the test also
asserts the real `timbreStatusItem` exists.

Release builds do not include the integration runtime code or controls.
