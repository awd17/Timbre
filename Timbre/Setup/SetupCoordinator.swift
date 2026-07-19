import Foundation

enum SetupFlowStep: Equatable {
    case welcome
    case microphone
    case microphoneDenied
    case preparing
    case ready
    case failed
}

/// Coordinates first-run setup: welcome → mic → install → ready.
/// Closing the UI must not cancel `ParakeetModelManaging.ensureInstalled()`.
@MainActor
@Observable
final class SetupCoordinator {
    static let completedWelcomeKey = "timbre.hasCompletedSetupWelcome"
    static let dismissedReadyKey = "timbre.hasDismissedSetupReady"

    private(set) var step: SetupFlowStep = .welcome
    private(set) var isWindowVisible = false

    private let modelManager: any ParakeetModelManaging
    private let microphone: any MicrophonePermissionProviding
    private let defaults: UserDefaults
    private let featureEnabled: Bool

    init(
        modelManager: any ParakeetModelManaging,
        microphone: any MicrophonePermissionProviding,
        defaults: UserDefaults = .standard,
        featureEnabled: Bool
    ) {
        self.modelManager = modelManager
        self.microphone = microphone
        self.defaults = defaults
        self.featureEnabled = featureEnabled
        reconcileInitialStep()
    }

    var modelState: ModelPreparationState { modelManager.state }

    var preparationProgress: ModelPreparationProgress { modelManager.progress }

    /// When setup is enabled, dictation is blocked until the model is installed.
    var allowsDictation: Bool {
        guard featureEnabled else { return true }
        switch modelManager.state {
        case .installed, .loaded:
            return true
        case .loading:
            // After setup is done, Parakeet may load into memory without blocking the menu.
            return defaults.bool(forKey: Self.dismissedReadyKey)
        case .checking, .notInstalled, .downloading, .failed:
            return false
        }
    }

    /// True while setup must complete before the normal dictation UI is shown.
    var blocksDictationUI: Bool {
        featureEnabled && !allowsDictation
    }

    var shouldAutoPresent: Bool {
        guard featureEnabled else { return false }
        if defaults.bool(forKey: Self.dismissedReadyKey), modelManager.state.isInstalled {
            return false
        }
        return true
    }

    /// Menu label when setup chrome should appear; nil hides the control.
    var menuActionTitle: String? {
        guard featureEnabled else { return nil }
        // Touch observable model state so SwiftUI refreshes during install.
        let state = modelManager.state

        switch state {
        case .downloading, .loading:
            return "Getting Ready…"
        case .failed:
            return "Setup Failed — Try Again…"
        case .installed, .loaded:
            if defaults.bool(forKey: Self.dismissedReadyKey) {
                return nil
            }
            return "Finish Setup…"
        case .notInstalled, .checking:
            return "Finish Setup…"
        }
    }

    var showsMenuSetupChrome: Bool {
        menuActionTitle != nil
    }

    var menuStatusText: String? {
        guard featureEnabled else { return nil }
        let state = modelManager.state
        switch state {
        case .downloading, .loading:
            return "Getting ready…"
        case .failed:
            return "Setup failed"
        case .installed, .loaded:
            if defaults.bool(forKey: Self.dismissedReadyKey) {
                return nil
            }
            return "Ready"
        case .notInstalled:
            return "Setup required"
        case .checking:
            return nil
        }
    }

    func markWindowVisible(_ visible: Bool) {
        isWindowVisible = visible
        if visible {
            windowDidBecomeActive()
        }
    }

    func windowDidBecomeActive() {
        guard featureEnabled else { return }
        modelManager.refreshAvailability()
        if step == .microphoneDenied {
            switch microphone.status {
            case .granted:
                beginPreparationAfterMicrophoneGranted()
            case .denied, .undetermined:
                break
            }
        }
        reconcileIfModelAlreadyReady()
    }

    func continueFromWelcome() {
        defaults.set(true, forKey: Self.completedWelcomeKey)
        step = .microphone
        Task { await requestMicrophoneAndContinue() }
    }

    func openMicrophoneSettings() {
        microphone.openSystemSettings()
    }

    func retryAfterFailure() {
        step = .preparing
        Task { await runInstall() }
    }

    func retryMicrophone() {
        Task { await requestMicrophoneAndContinue() }
    }

    func completeReady() {
        defaults.set(true, forKey: Self.dismissedReadyKey)
        defaults.set(true, forKey: Self.completedWelcomeKey)
        step = .ready
    }

    /// Call when the user chooses Done on the Ready screen.
    func acknowledgeReadyAndDismiss() {
        completeReady()
    }

    func presentRequestedFromMenu() {
        modelManager.refreshAvailability()
        switch modelManager.state {
        case .failed:
            step = .failed
        case .downloading, .loading:
            step = .preparing
        case .installed, .loaded:
            step = .ready
        case .notInstalled, .checking:
            if defaults.bool(forKey: Self.completedWelcomeKey) {
                switch microphone.status {
                case .granted:
                    beginPreparationAfterMicrophoneGranted()
                case .denied:
                    step = .microphoneDenied
                case .undetermined:
                    step = .microphone
                    Task { await requestMicrophoneAndContinue() }
                }
            } else {
                step = .welcome
            }
        }
    }

    // MARK: - Private

    private func reconcileInitialStep() {
        guard featureEnabled else {
            step = .welcome
            return
        }

        modelManager.refreshAvailability()

        if modelManager.state.isInstalled {
            if defaults.bool(forKey: Self.dismissedReadyKey) {
                step = .ready
            } else {
                // Cache present but setup not dismissed — skip download; show Ready soon.
                defaults.set(true, forKey: Self.completedWelcomeKey)
                step = .ready
            }
            return
        }

        if case .failed = modelManager.state {
            step = .failed
            return
        }

        if defaults.bool(forKey: Self.completedWelcomeKey) {
            step = .microphone
        } else {
            step = .welcome
        }
    }

    private func reconcileIfModelAlreadyReady() {
        if modelManager.state.isInstalled, step == .preparing || step == .failed {
            step = .ready
        }
    }

    private func requestMicrophoneAndContinue() async {
        let status = await microphone.requestAccessIfNeeded()
        switch status {
        case .granted:
            beginPreparationAfterMicrophoneGranted()
        case .denied:
            step = .microphoneDenied
        case .undetermined:
            step = .microphone
        }
    }

    private func beginPreparationAfterMicrophoneGranted() {
        step = .preparing
        Task { await runInstall() }
    }

    private func runInstall() async {
        if modelManager.state.isInstalled {
            step = .ready
            return
        }

        step = .preparing
        do {
            try await modelManager.ensureInstalled()
            step = .ready
        } catch {
            step = .failed
        }
    }
}
