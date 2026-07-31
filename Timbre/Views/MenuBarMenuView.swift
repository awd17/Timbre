import SwiftUI

struct MenuBarMenuView: View {
    var controller: AssistantController
    @ObservedObject var preferences: UserDefaultsAppPreferences
    @ObservedObject var inputDevices: CoreAudioInputDeviceManager
    var setupCoordinator: SetupCoordinator?
    @Bindable var authentication: AuthenticationController
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

        accountMenuSection

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
                Toggle(
                    "\(name) (Unavailable — using System Default)",
                    isOn: .constant(true)
                )
                .disabled(true)
            }
        }
        .disabled(!controller.canStart)
        .accessibilityIdentifier("microphoneMenu")

        Divider()

        if setupCoordinator?.settingsAreUnlocked != false {
            Button("Settings…") {
                onOpenSettings?()
            }
            .accessibilityIdentifier("settingsMenuItem")
        }

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
    private var accountMenuSection: some View {
        switch authentication.state {
        case .signedOut:
            Button("Sign In…") {
                authentication.signIn()
            }
            .accessibilityIdentifier("signInMenuItem")
        case .signingIn:
            Button("Signing In…") {}
                .disabled(true)
                .accessibilityIdentifier("signingInMenuItem")
        case .signedIn(let user):
            Text(user.email ?? user.displayName)
                .accessibilityIdentifier("signedInAccountMenuLabel")
            Button("Sign Out") {
                authentication.signOut()
            }
            .accessibilityIdentifier("signOutMenuItem")
        case .error:
            Button("Sign In…") {
                authentication.retry()
            }
            .accessibilityIdentifier("signInRetryMenuItem")
        }

        Divider()
    }

    @ViewBuilder
    private func microphoneButton(
        title: String,
        selection: MicrophoneSelection
    ) -> some View {
        Toggle(
            title,
            isOn: Binding(
                get: {
                    preferences.microphoneSelection == selection
                },
                set: { isSelected in
                    if isSelected {
                        preferences.microphoneSelection = selection
                    }
                }
            )
        )
    }
}
