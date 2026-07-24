import Foundation

enum SetupFlowStep: Equatable {
    case welcome
    case shortcut
    case microphone
    case microphoneDenied
    case textInsertion
    case textInsertionDenied
    case preparing
    case ready
    case failed
}

private struct SetupFacts: Equatable {
    let completedWelcome: Bool
    let dismissedReady: Bool
    let completedShortcutOnboarding: Bool
    let hasAssignedShortcut: Bool
    let microphone: MicrophonePermissionStatus
    let accessibility: AccessibilityTrustState
    let accessibilityPromptOffered: Bool
    let model: ModelPreparationState
}

private enum SetupEffect: Equatable {
    case none
    case requestMicrophone
    case requestAccessibility
    case installModel
}

private enum SetupIntent {
    case refresh
    case continueWelcome
    case continueShortcut
    case requestMicrophone
    case requestAccessibility
    case retryInstall
    case acknowledgeReady
}

private struct SetupDecision: Equatable {
    let step: SetupFlowStep
    let effect: SetupEffect
}

private struct SetupMenuChrome: Equatable {
    let actionTitle: String?
    let statusText: String?
}

private enum SetupPolicy {
    static func decision(for facts: SetupFacts) -> SetupDecision {
        guard facts.completedWelcome || facts.dismissedReady || facts.model.isInstalled else {
            return SetupDecision(step: .welcome, effect: .none)
        }

        if !facts.completedShortcutOnboarding || !facts.hasAssignedShortcut {
            return SetupDecision(step: .shortcut, effect: .none)
        }

        switch facts.microphone {
        case .undetermined:
            return SetupDecision(step: .microphone, effect: .requestMicrophone)
        case .denied:
            return SetupDecision(step: .microphoneDenied, effect: .none)
        case .granted:
            break
        }

        guard facts.accessibility == .trusted else {
            let step: SetupFlowStep = facts.accessibilityPromptOffered
                ? .textInsertionDenied
                : .textInsertion
            return SetupDecision(step: step, effect: .none)
        }

        switch facts.model {
        case .installed, .loaded:
            return SetupDecision(step: .ready, effect: .none)
        case .loading where facts.dismissedReady:
            return SetupDecision(step: .ready, effect: .none)
        case .loading, .downloading:
            return SetupDecision(step: .preparing, effect: .none)
        case .checking, .notInstalled:
            return SetupDecision(step: .preparing, effect: .installModel)
        case .failed:
            return SetupDecision(step: .failed, effect: .none)
        }
    }

    static func allowsDictation(_ facts: SetupFacts) -> Bool {
        guard facts.completedShortcutOnboarding,
              facts.hasAssignedShortcut,
              facts.microphone == .granted,
              facts.accessibility == .trusted
        else {
            return false
        }
        switch facts.model {
        case .installed, .loaded:
            return true
        case .loading:
            return facts.dismissedReady
        case .checking, .notInstalled, .downloading, .failed:
            return false
        }
    }

    static func shouldAutoPresent(_ facts: SetupFacts) -> Bool {
        !facts.dismissedReady || !allowsDictation(facts)
    }

    static func menuChrome(for facts: SetupFacts) -> SetupMenuChrome {
        if allowsDictation(facts) {
            return SetupMenuChrome(actionTitle: nil, statusText: nil)
        }

        if facts.model.isInstalling {
            return SetupMenuChrome(
                actionTitle: "Getting Ready…",
                statusText: "Getting ready…"
            )
        }

        if case .failed = facts.model,
           facts.completedShortcutOnboarding,
           facts.microphone == .granted,
           facts.accessibility == .trusted
        {
            return SetupMenuChrome(
                actionTitle: "Setup Failed — Try Again…",
                statusText: "Setup failed"
            )
        }

        let status: String?
        if !facts.completedShortcutOnboarding || !facts.hasAssignedShortcut {
            status = "Choose your dictation shortcut"
        } else if facts.model.isInstalled || facts.model == .loading {
            switch facts.microphone {
            case .denied:
                status = "Microphone access required"
            case .undetermined:
                status = "Microphone permission needed"
            case .granted where facts.accessibility == .notTrusted:
                status = "Text insertion permission needed"
            case .granted:
                status = "Ready"
            }
        } else if facts.model == .checking {
            status = nil
        } else {
            status = "Setup required"
        }

        return SetupMenuChrome(actionTitle: "Finish Setup…", statusText: status)
    }
}

/// Coordinates first-run setup: welcome → shortcut → mic → text insertion → install → ready.
/// Closing the UI must not cancel `ParakeetModelManaging.ensureInstalled()`.
@MainActor
@Observable
final class SetupCoordinator {
    static let completedWelcomeKey = UserDefaultsOnboardingPreferences.completedWelcomeKey
    static let dismissedReadyKey = UserDefaultsOnboardingPreferences.dismissedReadyKey
    static let completedShortcutOnboardingKey =
        UserDefaultsOnboardingPreferences.completedShortcutOnboardingKey

    private(set) var step: SetupFlowStep = .welcome
    private(set) var isWindowVisible = false

    private let modelManager: any ParakeetModelManaging
    private let microphone: any MicrophonePermissionProviding
    private let accessibility: any AccessibilityPermissionProviding
    private let preferences: any OnboardingPreferencesProviding
    let shortcutOnboarding: any ShortcutOnboardingProviding
    private let featureEnabled: Bool
    private var inFlightEffect: SetupEffect?
    private var effectTask: Task<Void, Never>?
    private var previousAllowsDictation: Bool?

    var onReadinessChanged: ((Bool) -> Void)?

    init(
        modelManager: any ParakeetModelManaging,
        microphone: any MicrophonePermissionProviding,
        accessibility: any AccessibilityPermissionProviding,
        preferences: any OnboardingPreferencesProviding,
        shortcutOnboarding: any ShortcutOnboardingProviding,
        featureEnabled: Bool
    ) {
        self.modelManager = modelManager
        self.microphone = microphone
        self.accessibility = accessibility
        self.preferences = preferences
        self.shortcutOnboarding = shortcutOnboarding
        self.featureEnabled = featureEnabled
        reconcileInitialStep()
    }

    /// Convenience for production wiring and tests that pass a `UserDefaults` suite.
    convenience init(
        modelManager: any ParakeetModelManaging,
        microphone: any MicrophonePermissionProviding,
        accessibility: any AccessibilityPermissionProviding,
        defaults: UserDefaults,
        shortcutOnboarding: any ShortcutOnboardingProviding,
        featureEnabled: Bool
    ) {
        self.init(
            modelManager: modelManager,
            microphone: microphone,
            accessibility: accessibility,
            preferences: UserDefaultsOnboardingPreferences(defaults: defaults),
            shortcutOnboarding: shortcutOnboarding,
            featureEnabled: featureEnabled
        )
    }

    /// Production convenience using standard preferences and KeyboardShortcuts adapter.
    convenience init(
        modelManager: any ParakeetModelManaging,
        microphone: any MicrophonePermissionProviding,
        accessibility: any AccessibilityPermissionProviding,
        featureEnabled: Bool
    ) {
        self.init(
            modelManager: modelManager,
            microphone: microphone,
            accessibility: accessibility,
            preferences: UserDefaultsOnboardingPreferences(),
            shortcutOnboarding: KeyboardShortcutsOnboardingAdapter(),
            featureEnabled: featureEnabled
        )
    }

    var modelState: ModelPreparationState { modelManager.state }

    var preparationProgress: ModelPreparationProgress { modelManager.progress }

    var shortcutDisplayString: String? { shortcutOnboarding.displayString }

    var canContinueFromShortcut: Bool { shortcutOnboarding.hasAssignedShortcut }

    private var facts: SetupFacts {
        SetupFacts(
            completedWelcome: preferences.completedWelcome,
            dismissedReady: preferences.dismissedReady,
            completedShortcutOnboarding: preferences.completedShortcutOnboarding,
            hasAssignedShortcut: shortcutOnboarding.hasAssignedShortcut,
            microphone: microphone.status,
            accessibility: accessibility.trustState,
            accessibilityPromptOffered: accessibility.hasOfferedPrompt,
            model: modelManager.state
        )
    }

    /// Dictation requires confirmed shortcut, assigned chord, installed model, mic, and Accessibility.
    var allowsDictation: Bool {
        guard featureEnabled else { return true }
        return SetupPolicy.allowsDictation(facts)
    }

    /// True while setup must complete before the normal dictation UI is shown.
    var blocksDictationUI: Bool {
        featureEnabled && !allowsDictation
    }

    var shouldAutoPresent: Bool {
        guard featureEnabled else { return false }
        return SetupPolicy.shouldAutoPresent(facts)
    }

    /// Menu label when setup chrome should appear; nil hides the control.
    var menuActionTitle: String? {
        guard featureEnabled else { return nil }
        return SetupPolicy.menuChrome(for: facts).actionTitle
    }

    var showsMenuSetupChrome: Bool {
        menuActionTitle != nil
    }

    var menuStatusText: String? {
        guard featureEnabled else { return nil }
        return SetupPolicy.menuChrome(for: facts).statusText
    }

    func markWindowVisible(_ visible: Bool) {
        isWindowVisible = visible
        if visible {
            TimbreLog.line("Timbre onboarding: window shown step=\(step)")
            windowDidBecomeActive()
        } else {
            TimbreLog.line("Timbre onboarding: window closed step=\(step)")
        }
    }

    /// Refresh model + permission facts when the app (or setup window) becomes active.
    func applicationDidBecomeActive() {
        windowDidBecomeActive()
    }

    /// Reconciles a lifecycle change that the setup effect did not initiate, such
    /// as prewarm discovering and invalidating an unusable on-disk model cache.
    func modelPreparationDidChange() {
        guard featureEnabled else { return }
        reconcile(intent: .refresh)
    }

    func windowDidBecomeActive() {
        guard featureEnabled else { return }
        shortcutOnboarding.refreshFromStorage()
        modelManager.refreshAvailability()
        reconcile(intent: .refresh)
    }

    /// Call when the Recorder reports a shortcut change so Continue updates immediately.
    func shortcutRecorderDidChange(isAssigned: Bool, displayString: String?) {
        shortcutOnboarding.applyRecorderChange(
            isAssigned: isAssigned,
            displayString: displayString
        )
        reconcile(intent: .refresh)
    }

    func continueFromWelcome() {
        TimbreLog.line("Timbre onboarding: continue from welcome")
        reconcile(intent: .continueWelcome)
    }

    func continueFromShortcut() {
        guard shortcutOnboarding.hasAssignedShortcut else {
            TimbreLog.line("Timbre onboarding: continue from shortcut blocked (none assigned)")
            return
        }
        TimbreLog.line("Timbre onboarding: continue from shortcut")
        reconcile(intent: .continueShortcut)
    }

    func openMicrophoneSettings() {
        microphone.openSystemSettings()
    }

    func openAccessibilitySettings() {
        accessibility.openSystemSettings()
    }

    func requestTextInsertionAccess() {
        reconcile(intent: .requestAccessibility)
    }

    func retryAfterFailure() {
        reconcile(intent: .retryInstall)
    }

    func retryMicrophone() {
        reconcile(intent: .requestMicrophone)
    }

    /// Keeps model preparation running while suppressing a later Ready-only launch.
    /// A failed or missing install clears this preference during reconciliation.
    func continuePreparationInBackground() {
        guard modelManager.state.isInstalling else { return }
        preferences.dismissedReady = true
        preferences.completedWelcome = true
        TimbreLog.line("Timbre onboarding: continuing preparation in background")
    }

    /// Call when the user chooses Done on the Ready screen.
    func acknowledgeReadyAndDismiss() {
        guard step == .ready, allowsDictation else {
            TimbreLog.line("Timbre onboarding: ready acknowledgement ignored while setup is incomplete")
            return
        }
        TimbreLog.line("Timbre onboarding: ready acknowledged")
        reconcile(intent: .acknowledgeReady)
    }

    func presentRequestedFromMenu() {
        TimbreLog.line("Timbre onboarding: reopen requested from menu")
        modelManager.refreshAvailability()
        shortcutOnboarding.refreshFromStorage()
        reconcile(intent: .refresh)
    }

    // MARK: - Private

    private func reconcileInitialStep() {
        guard featureEnabled else {
            step = .welcome
            return
        }

        modelManager.refreshAvailability()
        shortcutOnboarding.refreshFromStorage()
        reconcile(intent: .refresh)
        TimbreLog.line("Timbre onboarding: initial step=\(step)")
    }

    private func reconcile(intent: SetupIntent) {
        let previousStep = step
        let requestedEffect: SetupEffect?
        switch intent {
        case .refresh:
            requestedEffect = nil
        case .continueWelcome:
            preferences.completedWelcome = true
            requestedEffect = nil
        case .continueShortcut:
            preferences.completedShortcutOnboarding = true
            preferences.completedWelcome = true
            requestedEffect = nil
        case .requestMicrophone:
            requestedEffect = .requestMicrophone
        case .requestAccessibility:
            requestedEffect = .requestAccessibility
        case .retryInstall:
            requestedEffect = .installModel
        case .acknowledgeReady:
            preferences.dismissedReady = true
            preferences.completedWelcome = true
            if !preferences.completedShortcutOnboarding,
               shortcutOnboarding.hasAssignedShortcut
            {
                preferences.completedShortcutOnboarding = true
            }
            requestedEffect = nil
        }

        clearStaleReadyPreferenceIfNeeded()
        let decision = SetupPolicy.decision(for: facts)
        step = intent == .retryInstall ? .preparing : decision.step
        if step != previousStep {
            TimbreLog.line("Timbre onboarding: step \(previousStep) → \(step)")
        }

        let effect = requestedEffect ?? decision.effect
        if effect != .none {
            start(effect)
        }
        notifyReadinessIfNeeded()
    }

    private func clearStaleReadyPreferenceIfNeeded() {
        guard preferences.dismissedReady,
              !modelManager.state.isInstalled,
              !modelManager.state.isInstalling
        else {
            return
        }
        TimbreLog.line("Timbre onboarding: clearing stale ready preference")
        preferences.dismissedReady = false
    }

    private func start(_ effect: SetupEffect) {
        guard inFlightEffect == nil else { return }
        inFlightEffect = effect
        if effect == .installModel {
            TimbreLog.line("Timbre onboarding: preparation started")
        }
        effectTask = Task { [weak self] in
            guard let self else { return }
            await self.perform(effect)
            self.finish(effect)
        }
    }

    private func perform(_ effect: SetupEffect) async {
        switch effect {
        case .none:
            break
        case .requestMicrophone:
            _ = await microphone.requestAccessIfNeeded()
        case .requestAccessibility:
            _ = await accessibility.requestAccessIfNeeded()
        case .installModel:
            let currentFacts = facts
            guard currentFacts.completedShortcutOnboarding,
                  currentFacts.microphone == .granted,
                  currentFacts.accessibility == .trusted,
                  !modelManager.state.isInstalled
            else {
                return
            }
            try? await modelManager.ensureInstalled()
        }
    }

    private func finish(_ effect: SetupEffect) {
        guard inFlightEffect == effect else { return }
        inFlightEffect = nil
        effectTask = nil
        // reconcile notifies readiness after facts settle.
        reconcile(intent: .refresh)
    }

    private func notifyReadinessIfNeeded() {
        let current = allowsDictation
        guard previousAllowsDictation != current else { return }
        previousAllowsDictation = current
        onReadinessChanged?(current)
    }
}
