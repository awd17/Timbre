import SwiftUI

struct MenuBarMenuView: View {
    var controller: AssistantController
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
}
