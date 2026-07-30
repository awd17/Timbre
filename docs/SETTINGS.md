# Settings

Timbre provides one native macOS Settings window, opened from the compact
menu-bar menu, the application menu, Command-comma, or the Dock icon when Dock
visibility is enabled. Repeated actions focus the same window.

## User settings

| Setting | Default | Behavior |
|---|---:|---|
| Dictation shortcut | Existing `⌃⇧D` default | Required for dictation and shared with onboarding. Clearing is a temporary editing state; closing Settings without a replacement restores the previous shortcut. |
| Microphone input | System Default | Stores a stable Core Audio device UID. A disconnected saved microphone falls back to the current macOS default without forgetting the choice and is reused when it reconnects. |
| Show Timbre in Dock | Off | Switches Timbre between regular and accessory activation policy immediately. The menu-bar item remains available. |
| Playback while listening | Keep Unchanged | After Timbre's global dictation hotkey starts listening, can leave playback alone or mute it until listening ends. Other microphone activity never triggers it. |
| Keep transcript on clipboard | Off | Leaves a successfully inserted transcript on the clipboard when enabled. |

The Overlay section can clear the saved panel placement and immediately move an
existing panel to the default bottom-center position on the pointer's display.
Reset All Settings restores the shortcut, microphone, playback, Dock, clipboard,
and overlay defaults. It deliberately keeps onboarding completion, downloaded
models, permissions, and the last transcript.

The About section reads the marketing version and build from the app bundle and
provides Quit Timbre through the normal application termination path.
Launch at Login is deferred until the packaging/signing release work, where
`SMAppService.mainApp` can be verified with an installed, signed bundle.

Microphone, playback, and full-reset controls are disabled during an active
dictation. A microphone choice is resolved and bound immediately before each
recording, before the input format is read or an audio tap is installed.

## Audio routing and restoration

The menu-bar menu includes a native Microphone submenu with System Default first
and every connected usable input after it. A remembered but disconnected device
remains visible as unavailable while Timbre uses System Default. Selecting the
Mac or a USB microphone while AirPods remain the output avoids activating the
Bluetooth microphone path that reduces playback quality.

Mute operates on the default output's Core Audio mute control; it does not
capture system audio or require another privacy permission. Outputs without a
software mute control are left unchanged.

Before changing playback, Timbre writes a restoration record containing the
output UID, starting state, and applied state. Only a dictation session started
by Timbre's global hotkey creates this transaction; global microphone and audio
device notifications never create one. Timbre restores the original mute state
on stop, output switching, failure, reset, or termination. A later launch also
recovers an interrupted mute transaction when the output still matches the
state Timbre applied. Timbre verifies mute briefly while a route settles and
retries failed restoration writes so Bluetooth and virtual outputs do not
rebound or remain muted.

## Clipboard semantics

Timbre always uses the pasteboard internally to insert text by posting
Command-V. When retention is off, it snapshots every materializable
representation of every pasteboard item (up to 64 MiB), writes the transcript
as promised string data, and restores the complete snapshot only after the
target requests the paste and Timbre still owns the same pasteboard generation.

If the snapshot is incomplete, the target never consumes the promised data, or
another process changes the pasteboard, Timbre does not perform a restoration.
A bounded 150 ms post-consumption grace period lets editors finish a paste they
commit on a later run-loop turn. An unsafe target or failed insertion leaves
the transcript copied for recovery. AppKit has no compare-and-swap pasteboard
operation, so a very small check-to-restore race remains. The grace period is
isolated in the pasteboard service and does not delay Command-V posting.

## Activation lifecycle

The stored Dock preference and temporary window presentation are separate.
Onboarding and Settings temporarily use regular activation without changing the
preference. If Dock visibility is turned off while Settings is open, Timbre
returns to accessory mode when the window closes. The existing AppIcon catalog
contains all macOS sizes; visual redesign remains release work if desired.

The native menu contains the Microphone submenu, Settings, Copy Last Dictation,
and Quit. Check for Updates remains later work.
