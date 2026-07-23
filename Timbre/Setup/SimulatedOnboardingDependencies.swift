import Foundation

#if DEBUG
/// In-memory onboarding prefs for simulated / UI-test launches (never touches production defaults).
@MainActor
final class InMemoryOnboardingPreferences: OnboardingPreferencesProviding {
    var completedWelcome: Bool
    var dismissedReady: Bool
    var completedShortcutOnboarding: Bool

    init(
        completedWelcome: Bool = false,
        dismissedReady: Bool = false,
        completedShortcutOnboarding: Bool = false
    ) {
        self.completedWelcome = completedWelcome
        self.dismissedReady = dismissedReady
        self.completedShortcutOnboarding = completedShortcutOnboarding
    }
}

/// Deterministic shortcut state for simulated onboarding and UI tests.
@MainActor
@Observable
final class SimulatedShortcutOnboarding: ShortcutOnboardingProviding {
    private(set) var hasAssignedShortcut: Bool
    private(set) var displayString: String

    init(
        hasAssignedShortcut: Bool = true,
        displayString: String = DictationShortcutName.temporaryDefaultDisplayString
    ) {
        self.hasAssignedShortcut = hasAssignedShortcut
        self.displayString = displayString
    }

    func applyRecorderChange(isAssigned: Bool, displayString: String?) {
        hasAssignedShortcut = isAssigned
        if let displayString, !displayString.isEmpty {
            self.displayString = displayString
        } else if !isAssigned {
            self.displayString = DictationShortcutName.temporaryDefaultDisplayString
        }
    }

    func refreshFromStorage() {
        // In-memory only; nothing to reload.
    }

    func setAssigned(_ assigned: Bool, displayString: String? = nil) {
        hasAssignedShortcut = assigned
        if let displayString {
            self.displayString = displayString
        }
    }
}

@MainActor
final class SimulatedMicrophonePermission: MicrophonePermissionProviding {
    var status: MicrophonePermissionStatus
    private(set) var requestCallCount = 0
    private(set) var openSettingsCallCount = 0
    var statusAfterRequest: MicrophonePermissionStatus

    init(
        status: MicrophonePermissionStatus = .granted,
        statusAfterRequest: MicrophonePermissionStatus = .granted
    ) {
        self.status = status
        self.statusAfterRequest = statusAfterRequest
    }

    func requestAccessIfNeeded() async -> MicrophonePermissionStatus {
        requestCallCount += 1
        switch status {
        case .granted, .denied:
            return status
        case .undetermined:
            status = statusAfterRequest
            return status
        }
    }

    func openSystemSettings() {
        openSettingsCallCount += 1
        TimbreLog.line("Timbre onboarding: SIMULATED open microphone settings (no-op)")
    }
}

@MainActor
final class SimulatedAccessibilityPermission: AccessibilityPermissionProviding {
    var trustState: AccessibilityTrustState
    private(set) var hasOfferedPrompt: Bool
    private(set) var requestCallCount = 0
    private(set) var openSettingsCallCount = 0
    var trustAfterRequest: AccessibilityTrustState

    init(
        trustState: AccessibilityTrustState = .trusted,
        hasOfferedPrompt: Bool = false,
        trustAfterRequest: AccessibilityTrustState = .trusted
    ) {
        self.trustState = trustState
        self.hasOfferedPrompt = hasOfferedPrompt
        self.trustAfterRequest = trustAfterRequest
    }

    func requestAccessIfNeeded() async -> AccessibilityTrustState {
        requestCallCount += 1
        if trustState == .trusted {
            return .trusted
        }
        hasOfferedPrompt = true
        trustState = trustAfterRequest
        return trustState
    }

    func openSystemSettings() {
        openSettingsCallCount += 1
        TimbreLog.line("Timbre onboarding: SIMULATED open Accessibility settings (no-op)")
    }
}

/// In-memory model preparation for DEBUG simulated onboarding. Never touches FluidAudio or disk.
@MainActor
final class SimulatedParakeetModelManager: ParakeetModelManaging {
    private(set) var state: ModelPreparationState
    private(set) var progress: ModelPreparationProgress = .idle
    private(set) var ensureInstalledCallCount = 0
    private(set) var loadInstalledAndRetainCallCount = 0
    private(set) var unloadCallCount = 0
    private(set) var refreshCallCount = 0

    private let durationSeconds: TimeInterval
    private var failOnce: Bool
    private var installTask: Task<Void, Error>?

    init(
        initialState: ModelPreparationState = .notInstalled,
        durationSeconds: TimeInterval = 6,
        failOnce: Bool = false
    ) {
        self.state = initialState
        self.durationSeconds = max(0.2, durationSeconds)
        self.failOnce = failOnce
    }

    func refreshAvailability() {
        refreshCallCount += 1
    }

    func ensureInstalled() async throws {
        ensureInstalledCallCount += 1
        if let installTask {
            try await installTask.value
            return
        }

        let task = Task<Void, Error> { @MainActor in
            TimbreLog.line("Timbre onboarding: SIMULATED preparation started")
            self.state = .downloading
            let steps = 20
            let stepDuration = self.durationSeconds / Double(steps)
            for index in 0..<steps {
                try Task.checkCancellation()
                let fraction = Double(index) / Double(steps)
                self.progress = ModelPreparationProgress(
                    fraction: fraction,
                    detail: "Getting ready…",
                    estimatedSecondsRemaining: self.durationSeconds * (1 - fraction)
                )
                try await Task.sleep(nanoseconds: UInt64(stepDuration * 1_000_000_000))
            }

            if self.failOnce {
                self.failOnce = false
                self.state = .failed(message: "Something went wrong while getting Timbre ready.")
                self.progress = .idle
                TimbreLog.line("Timbre onboarding: SIMULATED preparation failed")
                throw TranscriptionError.recognitionFailed("simulated failure")
            }

            self.state = .installed
            self.progress = .idle
            TimbreLog.line("Timbre onboarding: SIMULATED preparation complete")
        }
        installTask = task

        do {
            try await task.value
            installTask = nil
        } catch {
            installTask = nil
            if state != .failed(message: "Something went wrong while getting Timbre ready.") {
                state = .failed(message: "Something went wrong while getting Timbre ready.")
                progress = .idle
            }
            throw error
        }
    }

    func loadInstalledAndRetain() async throws {
        loadInstalledAndRetainCallCount += 1
        guard state.isInstalled || state == .installed || state == .loaded else {
            throw ParakeetModelError.modelNotInstalled
        }
        state = .loaded
    }

    func unload() {
        unloadCallCount += 1
        if state.isLoaded || state == .loading {
            state = .installed
        }
    }
}
#endif
