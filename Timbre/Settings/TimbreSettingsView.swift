import KeyboardShortcuts
import SwiftUI

struct TimbreSettingsView: View {
    @ObservedObject var preferences: UserDefaultsAppPreferences
    let shortcutState: KeyboardShortcutsOnboardingAdapter
    let shortcutName: KeyboardShortcuts.Name
    let bundleInformation: any BundleInformationProviding
    let onClose: () -> Void

    var body: some View {
        Form {
            Section("General") {
                LabeledContent {
                    VStack(alignment: .trailing, spacing: 4) {
                        KeyboardShortcuts.Recorder(
                            for: shortcutName,
                            onChange: { shortcut in
                                shortcutState.applySettingsRecorderChange(shortcut)
                            }
                        )
                    }
                } label: {
                    settingLabel(
                        "Dictation Shortcut",
                        help: "Required to start and stop dictation from anywhere."
                    )
                }
                .accessibilityIdentifier("settingsDictationShortcut")

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

            Section("About") {
                LabeledContent("Application", value: bundleInformation.appName)
                LabeledContent("Version", value: bundleInformation.versionDescription)
                    .accessibilityIdentifier("settingsVersion")
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
            shortcutState.refreshFromStorage()
            shortcutState.beginSettingsShortcutEditing()
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
