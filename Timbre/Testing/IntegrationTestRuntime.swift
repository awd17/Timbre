import AppKit
import Foundation
import KeyboardShortcuts

#if DEBUG
enum IntegrationTestScenario: String, CaseIterable {
    case foregroundOnboarding
    case backgroundOnboarding
    case normal
    case clearShortcut
    case microphoneRevoked
    case accessibilityRevoked
    case accessibilityRevokedDuringDelivery
    case secureInput
    case pasteboardRace
    case eventPostFailure
    case performance
    case coldPerformance
    case realPaste
    case cleanup
}

struct IntegrationTestConfiguration: Equatable {
    static let argument = "--integration-test"
    static let profileEnvironment = "TIMBRE_INTEGRATION_PROFILE"
    static let scenarioEnvironment = "TIMBRE_INTEGRATION_SCENARIO"
    static let resetEnvironment = "TIMBRE_INTEGRATION_RESET"
    static let menuHostEnvironment = "TIMBRE_INTEGRATION_MENU_HOST"
    static let probeEnvironment = "TIMBRE_INTEGRATION_PROBE"

    let profile: String
    let scenario: IntegrationTestScenario
    let shouldReset: Bool
    let showsMenuHost: Bool
    let probeURL: URL

    var shortcutBurstURL: URL {
        probeURL.deletingPathExtension()
            .appendingPathExtension("shortcut-burst.json")
    }

    static func isRequested(arguments: [String]) -> Bool {
        arguments.contains(argument)
    }

    static func resolve(
        arguments: [String],
        environment: [String: String]
    ) -> IntegrationTestConfiguration? {
        guard isRequested(arguments: arguments) else { return nil }

        let rawProfile = environment[profileEnvironment] ?? "manual"
        let profile = sanitizeProfile(rawProfile)
        let scenario = environment[scenarioEnvironment]
            .flatMap(IntegrationTestScenario.init(rawValue:)) ?? .normal
        let probeURL: URL
        if let path = environment[probeEnvironment], path.hasPrefix("/") {
            probeURL = URL(fileURLWithPath: path)
        } else {
            probeURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("timbre-integration-\(profile).json")
        }

        return IntegrationTestConfiguration(
            profile: profile,
            scenario: scenario,
            shouldReset: environment[resetEnvironment] == "1",
            showsMenuHost: environment[menuHostEnvironment] == "1",
            probeURL: probeURL
        )
    }

    private static func sanitizeProfile(_ profile: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = profile.unicodeScalars.filter { allowed.contains($0) }
        let sanitized = String(String.UnicodeScalarView(scalars)).prefix(80)
        return sanitized.isEmpty ? "manual" : String(sanitized)
    }
}

struct IntegrationProbeSnapshot: Codable, Equatable {
    var generation = 0
    var modelState = "notInstalled"
    var installAttempts = 0
    var sessionStarts = 0
    var sessionStops = 0
    var shortcutBurstsArmed = 0
    var shortcutBurstInvocations = 0
    var pasteAttempts = 0
    var successfulPastes = 0
    var lastPasteText: String?
    var lastDeliveryResult: String?
    var lastStartToPreparingMilliseconds: Double?
    var lastPreparingToListeningMilliseconds: Double?
    var lastStartToListeningMilliseconds: Double?
    var lastStopToCompletionMilliseconds: Double?
}

private struct IntegrationShortcutBurstCommand: Codable {
    let generation: Int
    let extraInvocations: Int
    let invoke: Bool?
}

@MainActor
@Observable
final class IntegrationTestProbe {
    private(set) var snapshot: IntegrationProbeSnapshot
    let url: URL

    init(url: URL, reset: Bool) {
        self.url = url
        if reset {
            try? FileManager.default.removeItem(at: url)
        }
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(IntegrationProbeSnapshot.self, from: data)
        {
            snapshot = decoded
        } else {
            snapshot = IntegrationProbeSnapshot()
        }
        snapshot.generation += 1
        persist()
    }

    func setModelState(_ state: ModelPreparationState) {
        snapshot.modelState = state.integrationName
        persist()
    }

    func recordInstallAttempt() {
        snapshot.installAttempts += 1
        persist()
    }

    func recordSessionStarted() {
        snapshot.sessionStarts += 1
        persist()
    }

    func recordSessionStopped() {
        snapshot.sessionStops += 1
        persist()
    }

    func recordShortcutBurstArmed() {
        snapshot.shortcutBurstsArmed += 1
        persist()
    }

    func recordShortcutBurstInvocation() {
        snapshot.shortcutBurstInvocations += 1
        persist()
    }

    func recordPasteAttempt(text: String?, succeeded: Bool) {
        snapshot.pasteAttempts += 1
        snapshot.lastPasteText = text
        if succeeded {
            snapshot.successfulPastes += 1
        }
        persist()
    }

    func recordDeliveryResult(_ result: TranscriptDeliveryResult) {
        snapshot.lastDeliveryResult = result.integrationName
        persist()
    }

    func recordPerformance(_ event: DictationPerformanceEvent) {
        switch event {
        case .startToPreparing(let milliseconds):
            snapshot.lastStartToPreparingMilliseconds = milliseconds
            // Timing values describe one session. Clear downstream milestones
            // so a relaunch or restart cannot mistake an earlier session for
            // the current one reaching listening or completion.
            snapshot.lastPreparingToListeningMilliseconds = nil
            snapshot.lastStartToListeningMilliseconds = nil
            snapshot.lastStopToCompletionMilliseconds = nil
        case .preparingToListening(let milliseconds):
            snapshot.lastPreparingToListeningMilliseconds = milliseconds
        case .startToListening(let milliseconds):
            snapshot.lastStartToListeningMilliseconds = milliseconds
        case .stopToCompletion(let milliseconds):
            snapshot.lastStopToCompletionMilliseconds = milliseconds
        }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } catch {
            TimbreLog.line("Timbre integration: probe write failed (\(error.localizedDescription))")
        }
    }
}

private extension ModelPreparationState {
    var integrationName: String {
        switch self {
        case .checking: return "checking"
        case .notInstalled: return "notInstalled"
        case .downloading: return "downloading"
        case .installed: return "installed"
        case .loading: return "loading"
        case .loaded: return "loaded"
        case .failed: return "failed"
        }
    }
}

private extension TranscriptDeliveryResult {
    var integrationName: String {
        switch self {
        case .pasteEventPosted:
            return "pasteEventPosted"
        case .copiedByDesign:
            return "copiedByDesign"
        case .copiedAfterInsertFailure(let reason):
            return "copiedAfterInsertFailure.\(reason.integrationName)"
        case .failed(let failure):
            switch failure {
            case .clipboardUnavailable:
                return "failed.clipboardUnavailable"
            case .emptyTranscript:
                return "failed.emptyTranscript"
            }
        case .cancelled:
            return "cancelled"
        }
    }
}

private extension CopyFallbackReason {
    var integrationName: String {
        switch self {
        case .missingTarget: return "missingTarget"
        case .targetTerminated: return "targetTerminated"
        case .targetIsSelf: return "targetIsSelf"
        case .frontmostChanged: return "frontmostChanged"
        case .accessibilityUntrusted: return "accessibilityUntrusted"
        case .pasteboardChanged: return "pasteboardChanged"
        case .eventPostFailed: return "eventPostFailed"
        case .secureInputField: return "secureInputField"
        case .ambiguousTargetIdentity: return "ambiguousTargetIdentity"
        }
    }
}

@MainActor
final class IntegrationTestRuntime {
    static let modelInstalledKey = "integration.modelInstalled"
    static let modelFailureConsumedKey = "integration.modelFailureConsumed"
    static let microphoneGrantedKey = "integration.microphoneGranted"
    static let accessibilityTrustedKey = "integration.accessibilityTrusted"
    static let accessibilityOfferedKey = "integration.accessibilityOffered"

    let configuration: IntegrationTestConfiguration
    let defaultsSuiteName: String
    let defaults: UserDefaults
    let probe: IntegrationTestProbe
    let modelManager: PersistentIntegrationModelManager
    let microphone: IntegrationMicrophonePermission
    let accessibility: IntegrationAccessibilityPermission
    let shortcutName = KeyboardShortcuts.Name.integrationTestToggleDictation
    let shortcutOnboarding: KeyboardShortcutsOnboardingAdapter
    let shortcutService: KeyboardShortcutsGlobalShortcutService
    let transcription: IntegrationTranscriptionService
    let pasteboard: NSPasteboard
    let clipboard: ClipboardService
    private var shortcutBurstMonitorTask: Task<Void, Never>?

    init(configuration: IntegrationTestConfiguration) {
        self.configuration = configuration
        let suiteName = "com.augustdrakton.Timbre.integration.\(configuration.profile)"
        defaultsSuiteName = suiteName
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Unable to create integration-test defaults suite")
        }
        self.defaults = defaults

        if configuration.shouldReset {
            defaults.removePersistentDomain(forName: suiteName)
            KeyboardShortcuts.reset(.integrationTestToggleDictation)
        } else if configuration.scenario == .clearShortcut {
            KeyboardShortcuts.reset(.integrationTestToggleDictation)
        }

        if configuration.shouldReset {
            switch configuration.scenario {
            case .foregroundOnboarding, .backgroundOnboarding:
                defaults.set(false, forKey: Self.modelInstalledKey)
                defaults.set(false, forKey: Self.microphoneGrantedKey)
                defaults.set(false, forKey: Self.accessibilityTrustedKey)
                defaults.set(false, forKey: Self.accessibilityOfferedKey)
            case .normal,
                 .clearShortcut,
                 .microphoneRevoked,
                 .accessibilityRevoked,
                 .accessibilityRevokedDuringDelivery,
                 .secureInput,
                 .pasteboardRace,
                 .eventPostFailure,
                 .performance,
                 .coldPerformance,
                 .realPaste,
                 .cleanup:
                break
            }
        }

        if configuration.shouldReset,
           configuration.scenario == .performance
            || configuration.scenario == .coldPerformance
            || configuration.scenario == .realPaste
        {
            defaults.set(true, forKey: UserDefaultsOnboardingPreferences.completedWelcomeKey)
            defaults.set(true, forKey: UserDefaultsOnboardingPreferences.dismissedReadyKey)
            defaults.set(true, forKey: UserDefaultsOnboardingPreferences.completedShortcutOnboardingKey)
            defaults.set(true, forKey: Self.modelInstalledKey)
            defaults.set(true, forKey: Self.microphoneGrantedKey)
            defaults.set(true, forKey: Self.accessibilityTrustedKey)
            defaults.set(true, forKey: Self.accessibilityOfferedKey)
            KeyboardShortcuts.setShortcut(
                KeyboardShortcuts.Shortcut(.k, modifiers: [.control, .shift]),
                for: .integrationTestToggleDictation
            )
        }

        if configuration.scenario == .microphoneRevoked {
            defaults.set(false, forKey: Self.microphoneGrantedKey)
        }
        if configuration.scenario == .accessibilityRevoked {
            defaults.set(false, forKey: Self.accessibilityTrustedKey)
            defaults.set(true, forKey: Self.accessibilityOfferedKey)
        }

        let probe = IntegrationTestProbe(
            url: configuration.probeURL,
            reset: configuration.shouldReset
        )
        self.probe = probe

        let microphone = IntegrationMicrophonePermission(
            defaults: defaults,
            scenario: configuration.scenario
        )
        self.microphone = microphone
        let accessibility = IntegrationAccessibilityPermission(
            defaults: defaults,
            scenario: configuration.scenario
        )
        self.accessibility = accessibility
        modelManager = PersistentIntegrationModelManager(
            defaults: defaults,
            scenario: configuration.scenario,
            probe: probe,
            installationStepDelay: configuration.scenario == .backgroundOnboarding
                ? .milliseconds(500)
                : .milliseconds(100)
        )
        shortcutOnboarding = KeyboardShortcutsOnboardingAdapter(name: shortcutName)
        shortcutService = KeyboardShortcutsGlobalShortcutService(name: shortcutName)
        transcription = IntegrationTranscriptionService(
            scenario: configuration.scenario,
            accessibility: accessibility,
            probe: probe
        )
        // A real Command-V is handled by the destination application, which
        // always reads the system pasteboard. The other integration scenarios
        // stay isolated on a private pasteboard.
        let pasteboard = configuration.scenario == .realPaste
            ? NSPasteboard.general
            : NSPasteboard.withUniqueName()
        self.pasteboard = pasteboard
        clipboard = ClipboardService(pasteboard: pasteboard)

        startShortcutBurstMonitor()
    }

    deinit {
        shortcutBurstMonitorTask?.cancel()
    }

    private func startShortcutBurstMonitor() {
        let commandURL = configuration.shortcutBurstURL
        let initialGeneration = probe.snapshot.shortcutBurstsArmed
        shortcutBurstMonitorTask = Task { [weak self] in
            var consumedGeneration = initialGeneration
            while !Task.isCancelled {
                if let data = try? Data(contentsOf: commandURL),
                   let command = try? JSONDecoder().decode(
                       IntegrationShortcutBurstCommand.self,
                       from: data
                   ),
                   command.generation > consumedGeneration
                {
                    consumedGeneration = command.generation
                    self?.armShortcutBurst(command)
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func armShortcutBurst(_ command: IntegrationShortcutBurstCommand) {
        guard command.extraInvocations > 0 || command.invoke == true else { return }
        if command.extraInvocations > 0 {
            shortcutService.armIntegrationTestBurst(
                extraInvocations: command.extraInvocations
            ) { [weak probe] in
                probe?.recordShortcutBurstInvocation()
            }
        }
        probe.recordShortcutBurstArmed()
        if command.invoke == true {
            shortcutService.invokeKeyUpForUnitTesting()
        }
    }

    func cleanupPersistentStateIfRequested() {
        guard configuration.scenario == .cleanup else { return }
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        defaults.synchronize()
        KeyboardShortcuts.reset(.integrationTestToggleDictation)
        try? FileManager.default.removeItem(at: configuration.probeURL)
        try? FileManager.default.removeItem(at: configuration.shortcutBurstURL)
    }

    func makeDelivery(
        targetProvider: any DictationTargetProviding,
        preferences: any AppPreferencesProviding
    ) -> any TranscriptDeliveryServicing {
        let deliveryAccessibility: any AccessibilityPermissionProviding =
            configuration.scenario == .accessibilityRevokedDuringDelivery
            ? IntegrationUntrustedDeliveryAccessibility(base: accessibility)
            : accessibility
        let transcriptPasteboard = IntegrationTranscriptPasteboard(
            base: TranscriptPasteboardService(pasteboard: pasteboard),
            simulatesRace: configuration.scenario == .pasteboardRace
        )
        let poster: any PasteCommandEventPosting = configuration.scenario == .realPaste
            ? CGEventPasteCommandPoster()
            : IntegrationPasteCommandPoster(
                probe: probe,
                pasteboard: pasteboard,
                shouldFail: configuration.scenario == .eventPostFailure
            )
        let secureInput: any SecureInputDetecting = configuration.scenario == .secureInput
            ? IntegrationSecureInputDetector()
            : AccessibilitySecureInputDetector()
        let delivery = FocusedApplicationTextOutputService(
            clipboard: clipboard,
            accessibility: deliveryAccessibility,
            targetProvider: targetProvider,
            pastePoster: poster,
            secureInputDetector: secureInput,
            pasteboard: pasteboard,
            preferences: preferences,
            transcriptPasteboard: transcriptPasteboard
        )
        return IntegrationRecordingDelivery(base: delivery, probe: probe)
    }
}

@MainActor
@Observable
final class PersistentIntegrationModelManager: ParakeetModelManaging {
    private(set) var state: ModelPreparationState
    private(set) var progress: ModelPreparationProgress = .idle

    private let defaults: UserDefaults
    private let scenario: IntegrationTestScenario
    private let probe: IntegrationTestProbe
    private let installationStepDelay: Duration
    private var installTask: Task<Void, Error>?

    init(
        defaults: UserDefaults,
        scenario: IntegrationTestScenario,
        probe: IntegrationTestProbe,
        installationStepDelay: Duration = .milliseconds(100)
    ) {
        self.defaults = defaults
        self.scenario = scenario
        self.probe = probe
        self.installationStepDelay = installationStepDelay
        state = defaults.bool(forKey: IntegrationTestRuntime.modelInstalledKey)
            ? .installed
            : .notInstalled
        probe.setModelState(state)
    }

    func refreshAvailability() {
        guard !state.isInstalling, !state.isLoaded else { return }
        state = defaults.bool(forKey: IntegrationTestRuntime.modelInstalledKey)
            ? .installed
            : .notInstalled
        progress = .idle
        probe.setModelState(state)
    }

    func ensureInstalled() async throws {
        if state.isInstalled { return }
        if let installTask {
            try await installTask.value
            return
        }

        let task = Task<Void, Error> { @MainActor [self] in
            probe.recordInstallAttempt()
            state = .downloading
            probe.setModelState(state)
            let duration: TimeInterval = 2
            let steps = 20
            for index in 0..<steps {
                try Task.checkCancellation()
                let fraction = Double(index) / Double(steps)
                progress = ModelPreparationProgress(
                    fraction: fraction,
                    detail: "Getting ready…",
                    estimatedSecondsRemaining: duration * (1 - fraction)
                )
                try await Task.sleep(for: installationStepDelay)
            }

            if scenario == .foregroundOnboarding,
               !defaults.bool(forKey: IntegrationTestRuntime.modelFailureConsumedKey)
            {
                defaults.set(true, forKey: IntegrationTestRuntime.modelFailureConsumedKey)
                state = .failed(message: "Something went wrong while getting Timbre ready.")
                progress = .idle
                probe.setModelState(state)
                throw TranscriptionError.recognitionFailed("integration install failure")
            }

            defaults.set(true, forKey: IntegrationTestRuntime.modelInstalledKey)
            state = .installed
            progress = .idle
            probe.setModelState(state)
        }
        installTask = task
        defer { installTask = nil }
        try await task.value
    }

    func loadInstalledAndRetain() async throws {
        guard defaults.bool(forKey: IntegrationTestRuntime.modelInstalledKey) else {
            state = .notInstalled
            probe.setModelState(state)
            throw ParakeetModelError.modelNotInstalled
        }
        if scenario == .coldPerformance {
            state = .loading
            probe.setModelState(state)
            try await Task.sleep(for: .milliseconds(700))
        }
        state = .loaded
        probe.setModelState(state)
    }

    func unload() {
        if state.isLoaded {
            state = .installed
            probe.setModelState(state)
        }
    }
}

@MainActor
final class IntegrationMicrophonePermission: MicrophonePermissionProviding {
    private let defaults: UserDefaults
    private let scenario: IntegrationTestScenario
    private var initialForegroundRequestCompleted = false

    init(defaults: UserDefaults, scenario: IntegrationTestScenario) {
        self.defaults = defaults
        self.scenario = scenario
    }

    var status: MicrophonePermissionStatus {
        if defaults.bool(forKey: IntegrationTestRuntime.microphoneGrantedKey) {
            return .granted
        }
        if scenario == .foregroundOnboarding && initialForegroundRequestCompleted {
            return .denied
        }
        if scenario == .microphoneRevoked {
            return .denied
        }
        return .undetermined
    }

    func requestAccessIfNeeded() async -> MicrophonePermissionStatus {
        if status == .granted { return .granted }
        let requestDelay: Duration = scenario == .backgroundOnboarding
            ? .milliseconds(1_500)
            : .milliseconds(350)
        try? await Task.sleep(for: requestDelay)
        if scenario == .foregroundOnboarding && !initialForegroundRequestCompleted {
            initialForegroundRequestCompleted = true
            return .denied
        }
        if scenario == .microphoneRevoked {
            return status
        }
        defaults.set(true, forKey: IntegrationTestRuntime.microphoneGrantedKey)
        return .granted
    }

    func openSystemSettings() {
        defaults.set(true, forKey: IntegrationTestRuntime.microphoneGrantedKey)
        TimbreLog.line("Timbre integration: simulated microphone grant")
    }
}

@MainActor
final class IntegrationAccessibilityPermission: AccessibilityPermissionProviding {
    private let defaults: UserDefaults
    private let scenario: IntegrationTestScenario

    init(defaults: UserDefaults, scenario: IntegrationTestScenario) {
        self.defaults = defaults
        self.scenario = scenario
    }

    var trustState: AccessibilityTrustState {
        return defaults.bool(forKey: IntegrationTestRuntime.accessibilityTrustedKey)
            ? .trusted
            : .notTrusted
    }

    var hasOfferedPrompt: Bool {
        defaults.bool(forKey: IntegrationTestRuntime.accessibilityOfferedKey)
    }

    func requestAccessIfNeeded() async -> AccessibilityTrustState {
        if trustState == .trusted { return .trusted }
        defaults.set(true, forKey: IntegrationTestRuntime.accessibilityOfferedKey)
        try? await Task.sleep(for: .milliseconds(350))
        if scenario == .foregroundOnboarding || scenario == .accessibilityRevoked {
            return .notTrusted
        }
        defaults.set(true, forKey: IntegrationTestRuntime.accessibilityTrustedKey)
        return .trusted
    }

    func openSystemSettings() {
        defaults.set(true, forKey: IntegrationTestRuntime.accessibilityTrustedKey)
        TimbreLog.line("Timbre integration: simulated Accessibility grant")
    }
}

@MainActor
final class IntegrationUntrustedDeliveryAccessibility: AccessibilityPermissionProviding {
    private let base: IntegrationAccessibilityPermission

    init(base: IntegrationAccessibilityPermission) {
        self.base = base
    }

    var trustState: AccessibilityTrustState { .notTrusted }
    var hasOfferedPrompt: Bool { base.hasOfferedPrompt }

    func requestAccessIfNeeded() async -> AccessibilityTrustState {
        .notTrusted
    }

    func openSystemSettings() {
        base.openSystemSettings()
    }
}

@MainActor
final class IntegrationTranscriptionService: TranscriptionServicing {
    static let finalTranscript = "Integration dictation"

    private let probe: IntegrationTestProbe
    private var isRunning = false
    private var partialTask: Task<Void, Never>?
    private let prepareDelay: Duration
    private let stopDelay: Duration

    init(
        scenario: IntegrationTestScenario,
        accessibility: IntegrationAccessibilityPermission,
        probe: IntegrationTestProbe
    ) {
        _ = accessibility
        self.probe = probe
        switch scenario {
        case .performance, .realPaste:
            prepareDelay = .milliseconds(20)
        case .coldPerformance:
            prepareDelay = .seconds(5)
        default:
            prepareDelay = .milliseconds(300)
        }
        stopDelay = scenario == .performance || scenario == .realPaste
            ? .milliseconds(20)
            : .milliseconds(300)
    }

    func prepare() async throws {
        try await Task.sleep(for: prepareDelay)
    }

    func start(
        onPartialResult: @escaping @MainActor (String) -> Void,
        onAudioLevel: @escaping @MainActor (Float) -> Void
    ) async throws {
        guard !isRunning else { throw TranscriptionError.alreadyRunning }
        isRunning = true
        probe.recordSessionStarted()
        partialTask = Task {
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            onAudioLevel(0.35)
            onPartialResult("Integration")
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            onAudioLevel(0.75)
            onPartialResult(Self.finalTranscript)
        }
    }

    func stop() async throws -> String {
        guard isRunning else { throw TranscriptionError.notRunning }
        probe.recordSessionStopped()
        partialTask?.cancel()
        partialTask = nil
        try await Task.sleep(for: stopDelay)
        isRunning = false
        return Self.finalTranscript
    }

    func cancel() async {
        partialTask?.cancel()
        partialTask = nil
        isRunning = false
    }
}

@MainActor
final class IntegrationPasteCommandPoster: PasteCommandEventPosting {
    private let probe: IntegrationTestProbe
    private let pasteboard: NSPasteboard
    private let shouldFail: Bool

    init(
        probe: IntegrationTestProbe,
        pasteboard: NSPasteboard,
        shouldFail: Bool
    ) {
        self.probe = probe
        self.pasteboard = pasteboard
        self.shouldFail = shouldFail
    }

    func postCommandV() -> Bool {
        let text = pasteboard.string(forType: .string)
        probe.recordPasteAttempt(text: text, succeeded: !shouldFail)
        return !shouldFail
    }
}

@MainActor
final class IntegrationTranscriptPasteboard: TranscriptPasteboardServicing {
    private let base: any TranscriptPasteboardServicing
    private let simulatesRace: Bool

    init(base: any TranscriptPasteboardServicing, simulatesRace: Bool) {
        self.base = base
        self.simulatesRace = simulatesRace
    }

    func captureCompleteSnapshot() -> PasteboardSnapshotCapture {
        base.captureCompleteSnapshot()
    }

    func writeTranscript(
        _ transcript: String,
        restorationSnapshot: PasteboardSnapshot?,
        retainedOutcome: ClipboardRetentionOutcome,
        onOutcome: @escaping (ClipboardRetentionOutcome) -> Void
    ) -> TrackedTranscriptWrite? {
        base.writeTranscript(
            transcript,
            restorationSnapshot: restorationSnapshot,
            retainedOutcome: retainedOutcome,
            onOutcome: onOutcome
        )
    }

    func isCurrentWriteUnchanged(_ write: TrackedTranscriptWrite) -> Bool {
        !simulatesRace && base.isCurrentWriteUnchanged(write)
    }

    func pasteWasPosted(for write: TrackedTranscriptWrite) {
        base.pasteWasPosted(for: write)
    }

    func cancelRestoration(
        for write: TrackedTranscriptWrite,
        outcome: ClipboardRetentionOutcome
    ) {
        base.cancelRestoration(for: write, outcome: outcome)
    }
}

@MainActor
struct IntegrationSecureInputDetector: SecureInputDetecting {
    func isSecureInputFocused(processIdentifier: pid_t) -> Bool {
        _ = processIdentifier
        return true
    }
}

@MainActor
final class IntegrationRecordingDelivery: TranscriptDeliveryServicing {
    private let base: any TranscriptDeliveryServicing
    private let probe: IntegrationTestProbe

    init(base: any TranscriptDeliveryServicing, probe: IntegrationTestProbe) {
        self.base = base
        self.probe = probe
    }

    func deliver(
        _ transcript: String,
        to target: DictationTargetContext?,
        cancellation: TranscriptDeliveryCancellationToken
    ) async -> TranscriptDeliveryResult {
        let result = await base.deliver(
            transcript,
            to: target,
            cancellation: cancellation
        )
        probe.recordDeliveryResult(result)
        return result
    }
}
#endif
