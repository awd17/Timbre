# Timbre

Private, fast voice dictation for your Mac.

Timbre lives in your menu bar and turns speech into text in the app you are
already using. Press your shortcut, speak, and press it again—Timbre transcribes
your audio locally and inserts the result at your cursor.

[Download the latest version](https://github.com/awd17/Timbre/releases/latest/download/Timbre.dmg)

## Why Timbre?

- **Private by design.** Transcription runs locally on your Mac.
- **Works where you work.** Dictate into most apps that accept text.
- **One global shortcut.** Start and stop without leaving the keyboard.
- **Out of the way.** Timbre stays in the menu bar and shows a compact listening
  indicator while you dictate.
- **Useful controls.** Choose your microphone, play back the last recording,
  copy the last dictation, and customize app behavior in Settings.

## Requirements

- A Mac with Apple silicon
- macOS 14.6 or later
- An internet connection during first-time setup to download the transcription
  model; dictation runs locally after that

## Install

1. [Download Timbre](https://github.com/awd17/Timbre/releases/latest/download/Timbre.dmg).
2. Open the disk image and drag **Timbre** to the **Applications** shortcut.
3. Open Timbre. Its seven-bar icon will appear in your menu bar.
4. Follow the setup guide to choose a shortcut, grant Microphone and
   Accessibility permissions, and download the speech model.

The current release is not signed or notarized with Apple. The first time you
open it, macOS will block it because it cannot verify the developer. After the
blocked-open message appears, go to **System Settings → Privacy & Security**,
scroll down, click **Open Anyway** for Timbre, and confirm. You only need to do
this once for each downloaded version.

Timbre needs Microphone access to hear your dictation. Accessibility access lets
it insert the finished text into the app you were using. You can change either
permission later in **System Settings → Privacy & Security**.

## Use

1. Put the cursor where you want the text to appear.
2. Press your Timbre shortcut (initially `Control` + `Shift` + `D`).
3. Speak normally.
4. Press the shortcut again to stop and insert the transcription.

Press `Escape` at any point to cancel the current dictation immediately. Timbre
discards any speech already detected and inserts nothing.

Click the Timbre icon in the menu bar for Settings, setup recovery, your last
dictation, or Quit. If text cannot be inserted safely, Timbre preserves the
transcript so you can copy it yourself.

## Privacy

Your microphone audio is processed on your Mac by the Parakeet speech model.
Timbre does not send recordings or transcripts to a Timbre server. The speech
model itself is downloaded during setup.

## Help and feedback

If something is not working, check that Timbre still has Microphone and
Accessibility access, then reopen its setup from the menu bar. You can also
[open an issue](https://github.com/awd17/Timbre/issues) with your macOS version,
Mac model, and a short description of what happened.

---

## For developers

Timbre is a native macOS menu-bar app written in Swift and SwiftUI. It uses
[FluidAudio](https://github.com/FluidInference/FluidAudio) for local NVIDIA
Parakeet v2 batch transcription and
[KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) for the
global shortcut.

### Development requirements

- macOS 14.6 or later
- Apple silicon
- Xcode 16 or later
- An Apple Development signing team

### Set up and run

```bash
git clone https://github.com/awd17/Timbre.git
cd Timbre
open Timbre.xcodeproj
```

Select the **Timbre** scheme, choose your Development Team under **Signing &
Capabilities**, and press `Command` + `R`.

From the command line:

```bash
xcodebuild \
  -project Timbre.xcodeproj \
  -scheme Timbre \
  -configuration Debug \
  -destination 'platform=macOS' \
  build
```

Run the unit and full-app integration suite with:

```bash
scripts/run-full-integration-test.sh
```

More implementation and test documentation lives in [`docs/`](docs/). Start
with [`docs/PROJECT_STATUS.md`](docs/PROJECT_STATUS.md) for the current
architecture and feature map.

### Publishing a release

The [`Release` workflow](.github/workflows/release.yml) builds the app, applies
an ad-hoc signature, packages it in an unsigned disk image, and creates a GitHub
Release containing `Timbre.dmg` and its SHA-256 checksum. It does not require
repository secrets. Because the app is not Developer ID-signed or notarized,
users must approve it in Privacy & Security on first launch.

Make sure `MARKETING_VERSION` in the Xcode project matches the release tag
without the leading `v`. To publish version 1.0.1:

```bash
git tag v1.0.1
git push origin v1.0.1
```

Pushing the tag starts the workflow. When it completes, the release appears on
the repository's **Releases** page and the download link at the top of this
README automatically points to the new build.
