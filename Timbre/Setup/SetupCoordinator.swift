import Foundation

enum SetupFlowStep: Equatable {
    case welcome
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
        guard facts.microphone == .granted, facts.accessibility == .trusted else {
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
           facts.microphone == .granted,
           facts.accessibility == .trusted
        {
            return SetupMenuChrome(
                actionTitle: "Setup Failed — Try Again…",
                statusText: "Setup failed"
            )
        }

        let status: String?
        if facts.model.isInstalled || facts.model == .loading {
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

/// Coordinates first-run setup: welcome → mic → text insertion → install → ready.
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
    private let accessibility: any AccessibilityPermissionProviding
    private let defaults: UserDefaults
    private let featureEnabled: Bool
    private var inFlightEffect: SetupEffect?
    private var effectTask: Task<Void, Never>?
    private var previousAllowsDictation: Bool?

    var onReadinessChanged: ((Bool) -> Void)?

    init(
        modelManager: any ParakeetModelManaging,
        microphone: any MicrophonePermissionProviding,
        accessibility: any AccessibilityPermissionProviding,
        defaults: UserDefaults = .standard,
        featureEnabled: Bool
    ) {
        self.modelManager = modelManager
        self.microphone = microphone
        self.accessibility = accessibility
        self.defaults = defaults
        self.featureEnabled = featureEnabled
        reconcileInitialStep()
    }

    var modelState: ModelPreparationState { modelManager.state }

    var preparationProgress: ModelPreparationProgress { modelManager.progress }

    private var facts: SetupFacts {
        SetupFacts(
            completedWelcome: defaults.bool(forKey: Self.completedWelcomeKey),
            dismissedReady: defaults.bool(forKey: Self.dismissedReadyKey),
            microphone: microphone.status,
            accessibility: accessibility.trustState,
            accessibilityPromptOffered: accessibility.hasOfferedPrompt,
            model: modelManager.state
        )
    }

    /// Dictation requires an installed model, microphone, and Accessibility trust.
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
            windowDidBecomeActive()
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
        modelManager.refreshAvailability()
        reconcile(intent: .refresh)
    }

    func continueFromWelcome() {
        reconcile(intent: .continueWelcome)
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

    /// Call when the user chooses Done on the Ready screen.
    func acknowledgeReadyAndDismiss() {
        reconcile(intent: .acknowledgeReady)
    }

    func presentRequestedFromMenu() {
        modelManager.refreshAvailability()
        reconcile(intent: .refresh)
    }

    // MARK: - Private

    private func reconcileInitialStep() {
        guard featureEnabled else {
            step = .welcome
            return
        }

        modelManager.refreshAvailability()
        reconcile(intent: .refresh)
    }

    private func reconcile(intent: SetupIntent) {
        let requestedEffect: SetupEffect?
        switch intent {
        case .refresh:
            requestedEffect = nil
        case .continueWelcome:
            defaults.set(true, forKey: Self.completedWelcomeKey)
            requestedEffect = microphone.status == .undetermined
                ? .requestMicrophone
                : nil
        case .requestMicrophone:
            requestedEffect = .requestMicrophone
        case .requestAccessibility:
            requestedEffect = .requestAccessibility
        case .retryInstall:
            requestedEffect = .installModel
        case .acknowledgeReady:
            defaults.set(true, forKey: Self.dismissedReadyKey)
            defaults.set(true, forKey: Self.completedWelcomeKey)
            requestedEffect = nil
        }

        clearStaleReadyPreferenceIfNeeded()
        let decision = SetupPolicy.decision(for: facts)
        step = intent == .retryInstall ? .preparing : decision.step

        let effect = requestedEffect ?? decision.effect
        if effect != .none {
            start(effect)
        }
        notifyReadinessIfNeeded()
    }

    private func clearStaleReadyPreferenceIfNeeded() {
        guard defaults.bool(forKey: Self.dismissedReadyKey),
              !modelManager.state.isInstalled,
              !modelManager.state.isInstalling
        else {
            return
        }
        defaults.set(false, forKey: Self.dismissedReadyKey)
    }

    private func start(_ effect: SetupEffect) {
        guard inFlightEffect == nil else { return }
        inFlightEffect = effect
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
            guard currentFacts.microphone == .granted,
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
