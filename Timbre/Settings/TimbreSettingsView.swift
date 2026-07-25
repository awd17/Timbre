import KeyboardShortcuts
import SwiftUI

struct TimbreSettingsView: View {
    @ObservedObject var preferences: UserDefaultsAppPreferences
    @ObservedObject var inputDevices: CoreAudioInputDeviceManager
    @ObservedObject var playbackController: DictationPlaybackController
    var controller: AssistantController
    let shortcutState: KeyboardShortcutsOnboardingAdapter
    let shortcutName: KeyboardShortcuts.Name
    let bundleInformation: any BundleInformationProviding
    let onResetOverlayPosition: () -> Void
    let onResetAllSettings: () -> Void
    let onQuit: () -> Void
    let onClose: () -> Void

    @State private var isConfirmingReset = false

    var body: some View {
        Form {
            Section("General") {
                LabeledContent {
                    KeyboardShortcuts.Recorder(
                        for: shortcutName,
                        onChange: { shortcut in
                            shortcutState.applySettingsRecorderChange(shortcut)
                        }
                    )
                } label: {
                    settingLabel(
                        "Dictation Shortcut",
                        help: "Required to start and stop dictation from anywhere."
                    )
                }
                .accessibilityIdentifier("settingsDictationShortcut")

                LabeledContent {
                    Picker("", selection: $preferences.microphoneSelection) {
                        Text("System Default")
                            .tag(MicrophoneSelection.systemDefault)
                        ForEach(inputDevices.devices) { device in
                            Text(device.name)
                                .tag(device.selection)
                        }
                        if let unavailable = inputDevices.unavailableSelection,
                           let name = unavailable.deviceName
                        {
                            Text("\(name) (Unavailable)")
                                .tag(unavailable)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                    .disabled(!controller.canStart)
                    .accessibilityIdentifier("settingsMicrophoneInput")
                } label: {
                    settingLabel("Microphone Input", help: microphoneHelp)
                }

                Toggle(
                    isOn: $preferences.showInDock,
                    label: {
                        settingLabel(
                            "Show Timbre in Dock",
                            help: "Show Timbre in the Dock and when switching apps."
                        )
                    }
                )
                .accessibilityIdentifier("settingsShowInDock")
            }

            Section("Dictation") {
                LabeledContent {
                    Picker("", selection: $preferences.playbackDuringDictation) {
                        ForEach(PlaybackDuringDictation.allCases) { behavior in
                            Text(behavior.title).tag(behavior)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                    .disabled(!controller.canStart)
                    .accessibilityIdentifier("settingsPlaybackBehavior")
                } label: {
                    settingLabel(
                        "Playback While Listening",
                        help: playbackHelp
                    )
                }

                Toggle(
                    isOn: $preferences.keepTranscriptOnClipboardAfterInsertion,
                    label: {
                        settingLabel(
                            "Keep transcript on clipboard",
                            help: "Keep a copy after Timbre inserts the text. Timbre always uses the clipboard briefly for insertion."
                        )
                    }
                )
                .accessibilityIdentifier("settingsKeepTranscript")
            }

            Section("Overlay") {
                LabeledContent {
                    Button("Reset Overlay Position") {
                        onResetOverlayPosition()
                    }
                    .accessibilityIdentifier("settingsResetOverlayPosition")
                } label: {
                    settingLabel(
                        "Position",
                        help: "Move the dictation overlay back to its default position."
                    )
                }
            }

            Section("Reset") {
                Button("Reset All Settings…", role: .destructive) {
                    isConfirmingReset = true
                }
                .disabled(!controller.canStart)
                .accessibilityIdentifier("settingsResetAll")
            }

            Section("About") {
                LabeledContent("Application", value: bundleInformation.appName)
                LabeledContent("Version", value: bundleInformation.versionDescription)
                    .accessibilityIdentifier("settingsVersion")

                Button("Quit Timbre") {
                    onQuit()
                }
                .accessibilityIdentifier("settingsQuit")
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460, idealWidth: 500, maxWidth: 560)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            SettingsWindowLifecycleObserver {
                shortcutState.finishSettingsShortcutEditing()
                onClose()
            }
                .frame(width: 0, height: 0)
        )
        .onAppear {
            inputDevices.refresh()
            shortcutState.refreshFromStorage()
            shortcutState.beginSettingsShortcutEditing()
        }
        .alert("Reset All Settings?", isPresented: $isConfirmingReset) {
            Button("Cancel", role: .cancel) {}
            Button("Reset Settings", role: .destructive) {
                onResetAllSettings()
            }
        } message: {
            Text(
                "This resets Timbre’s shortcut, microphone, playback, Dock, clipboard, and overlay settings. Setup and downloaded models are kept."
            )
        }
    }

    private var microphoneHelp: String {
        if inputDevices.unavailableSelection != nil {
            return "The saved microphone is unavailable. Timbre will use the current macOS default until it reconnects."
        }
        return "Choose a Mac or USB microphone to preserve Bluetooth headphone playback quality."
    }

    private var playbackHelp: String {
        if preferences.playbackDuringDictation != .keepUnchanged,
           !playbackController.isCurrentOutputControllable
        {
            return "The current output controls volume externally, so Timbre cannot change it."
        }
        switch preferences.playbackDuringDictation {
        case .keepUnchanged:
            return "Leave other audio at its current volume."
        case .lower:
            return "Temporarily reduce the current output to 25% while listening."
        case .mute:
            return "Temporarily mute the current output while listening."
        }
    }

    private func settingLabel(_ title: String, help: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(help)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
