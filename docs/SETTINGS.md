# Settings

Timbre provides one native macOS Settings window, opened from the menu-bar
popover, the application menu, Command-comma, or the Dock icon when Dock
visibility is enabled. Repeated actions focus the same window.

## User settings

| Setting | Default | Behavior |
|---|---:|---|
| Dictation shortcut | Existing `⌃⇧D` default | Uses the same KeyboardShortcuts `.toggleDictation` value as onboarding. Clearing is allowed and displays “Not set”; menu Start/Stop remains available. |
| Show Timbre in Dock | Off | Switches Timbre between regular and accessory activation policy immediately. The menu-bar item remains available. |
| Keep transcript on clipboard | Off | Leaves a successfully inserted transcript on the clipboard when enabled. |

The About section reads the marketing version and build from the app bundle.
Launch at Login is deferred until the packaging/signing release work, where
`SMAppService.mainApp` can be verified with an installed, signed bundle.

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

The menu-bar popover redesign is the next UI milestone. The floating dictation
indicator remains later work.
