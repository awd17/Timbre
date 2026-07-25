import SwiftUI

struct MenuBarMenuView: View {
    var controller: AssistantController
    @ObservedObject var preferences: UserDefaultsAppPreferences
    @ObservedObject var inputDevices: CoreAudioInputDeviceManager
    var setupCoordinator: SetupCoordinator?
    var onOpenSetup: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    var body: some View {
        if let setupActionTitle = setupCoordinator?.menuActionTitle {
            Button(setupActionTitle) {
                onOpenSetup?()
            }
            .accessibilityIdentifier("setupMenuItem")

            Divider()
        }

        Menu("Microphone") {
            microphoneButton(
                title: "System Default",
                selection: .systemDefault
            )

            ForEach(inputDevices.devices) { device in
                microphoneButton(
                    title: device.name,
                    selection: device.selection
                )
            }

            if let unavailable = inputDevices.unavailableSelection,
               let name = unavailable.deviceName
            {
                Divider()
                Label(
                    "\(name) (Unavailable — using System Default)",
                    systemImage: "checkmark"
                )
                .disabled(true)
            }
        }
        .disabled(!controller.canStart)
        .accessibilityIdentifier("microphoneMenu")

        Divider()

        Button("Settings…") {
            onOpenSettings?()
        }
        .accessibilityIdentifier("settingsMenuItem")

        Button("Copy Last Dictation") {
            controller.copyLastTranscript()
        }
        .disabled(!controller.canCopyLastTranscript)
        .accessibilityIdentifier("copyLastDictationMenuItem")

        Divider()

        Button("Quit Timbre") {
            controller.quit()
        }
        .accessibilityIdentifier("quitMenuItem")
    }

    @ViewBuilder
    private func microphoneButton(
        title: String,
        selection: MicrophoneSelection
    ) -> some View {
        Button {
            preferences.microphoneSelection = selection
        } label: {
            if preferences.microphoneSelection == selection {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }
}
