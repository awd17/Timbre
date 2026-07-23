import Foundation
@testable import Timbre
import XCTest

final class TimbreSetupFeatureTests: XCTestCase {
    func testDebugBypassFlagsDisableSetup() {
        XCTAssertFalse(
            TimbreSetupFeature.isEnabled(
                arguments: ["--mock-transcription"],
                isDebug: true
            )
        )
        XCTAssertFalse(
            TimbreSetupFeature.isEnabled(
                arguments: ["--parakeet-fixture"],
                isDebug: true
            )
        )
        XCTAssertFalse(
            TimbreSetupFeature.isEnabled(
                arguments: ["--apple-speech"],
                isDebug: true
            )
        )
        XCTAssertFalse(
            TimbreSetupFeature.isEnabled(
                arguments: ["--disable-setup"],
                isDebug: true
            )
        )
    }

    func testDebugEnabledByDefault() {
        XCTAssertTrue(
            TimbreSetupFeature.isEnabled(arguments: ["/path/to/Timbre"], isDebug: true)
        )
    }

    func testReleaseIgnoresBypassFlags() {
        XCTAssertTrue(
            TimbreSetupFeature.isEnabled(arguments: ["/path/to/Timbre"], isDebug: false)
        )
        XCTAssertTrue(
            TimbreSetupFeature.isEnabled(
                arguments: ["--mock-transcription", "--disable-setup", "--apple-speech"],
                isDebug: false
            )
        )
        XCTAssertTrue(
            TimbreSetupFeature.isEnabled(
                arguments: ["--parakeet-fixture"],
                isDebug: false
            )
        )
    }

    func testSimulateOnboardingForcesSetupOnEvenWithMockFlag() {
        XCTAssertTrue(
            TimbreSetupFeature.isEnabled(
                arguments: ["--simulate-onboarding", "--mock-transcription"],
                isDebug: true
            )
        )
    }

    func testSimulateOnboardingRejectedWithDisableSetup() {
        XCTAssertFalse(
            TimbreSetupFeature.isEnabled(
                arguments: ["--simulate-onboarding", "--disable-setup"],
                isDebug: true
            )
        )
    }
}

@MainActor
final class SetupCoordinatorTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "TimbreSetupTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        if let suiteName {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func makeCoordinator(
        model: FakeParakeetModelManager,
        microphone: FakeMicrophonePermission? = nil,
        accessibility: FakeAccessibilityPermission? = nil,
        shortcut: FakeShortcutOnboarding? = nil,
        featureEnabled: Bool = true
    ) -> SetupCoordinator {
        SetupCoordinator(
            modelManager: model,
            microphone: microphone ?? FakeMicrophonePermission(status: .granted),
            accessibility: accessibility ?? FakeAccessibilityPermission(trustState: .trusted),
            defaults: defaults,
            shortcutOnboarding: shortcut ?? FakeShortcutOnboarding(),
            featureEnabled: featureEnabled
        )
    }

    private func confirmShortcut(_ coordinator: SetupCoordinator) {
        coordinator.continueFromShortcut()
    }

    private func advanceThroughWelcomeAndShortcut(_ coordinator: SetupCoordinator) {
        coordinator.continueFromWelcome()
        XCTAssertEqual(coordinator.step, .shortcut)
        confirmShortcut(coordinator)
    }

    func testFeatureOffNeverAutoPresents() {
        let model = FakeParakeetModelManager(initialState: .notInstalled)
        let mic = FakeMicrophonePermission()
        let coordinator = makeCoordinator(
            model: model,
            microphone: mic,
            featureEnabled: false
        )
        XCTAssertFalse(coordinator.shouldAutoPresent)
        XCTAssertNil(coordinator.menuActionTitle)
        XCTAssertNil(coordinator.menuStatusText)
        XCTAssertEqual(model.refreshCallCount, 0)
    }

    func testInitializationRefreshesAvailabilityOnceWhenEnabled() {
        let model = FakeParakeetModelManager(initialState: .notInstalled)
        _ = makeCoordinator(model: model, microphone: FakeMicrophonePermission())

        XCTAssertEqual(model.refreshCallCount, 1)
    }

    func testFreshInstallBeginsAtWelcome() {
        let coordinator = makeCoordinator(
            model: FakeParakeetModelManager(initialState: .notInstalled),
            microphone: FakeMicrophonePermission(status: .undetermined)
        )
        XCTAssertEqual(coordinator.step, .welcome)
    }

    func testDefaultShortcutWithoutConfirmationShowsShortcutStep() {
        defaults.set(true, forKey: SetupCoordinator.completedWelcomeKey)
        let shortcut = FakeShortcutOnboarding(hasAssignedShortcut: true)
        let coordinator = makeCoordinator(
            model: FakeParakeetModelManager(initialState: .installed),
            shortcut: shortcut
        )
        XCTAssertEqual(coordinator.step, .shortcut)
        XCTAssertFalse(defaults.bool(forKey: SetupCoordinator.completedShortcutOnboardingKey))
    }

    func testShortcutContinueRequiresAssignedShortcut() {
        defaults.set(true, forKey: SetupCoordinator.completedWelcomeKey)
        let shortcut = FakeShortcutOnboarding(hasAssignedShortcut: false)
        let coordinator = makeCoordinator(
            model: FakeParakeetModelManager(initialState: .notInstalled),
            shortcut: shortcut
        )
        XCTAssertEqual(coordinator.step, .shortcut)
        XCTAssertFalse(coordinator.canContinueFromShortcut)
        coordinator.continueFromShortcut()
        XCTAssertFalse(defaults.bool(forKey: SetupCoordinator.completedShortcutOnboardingKey))
        XCTAssertEqual(coordinator.step, .shortcut)
    }

    func testRecorderChangeUpdatesContinueImmediately() {
        defaults.set(true, forKey: SetupCoordinator.completedWelcomeKey)
        let shortcut = FakeShortcutOnboarding(hasAssignedShortcut: false)
        let coordinator = makeCoordinator(
            model: FakeParakeetModelManager(initialState: .notInstalled),
            shortcut: shortcut
        )
        XCTAssertFalse(coordinator.canContinueFromShortcut)

        coordinator.shortcutRecorderDidChange(isAssigned: true, displayString: "⌃⇧D")
        XCTAssertTrue(coordinator.canContinueFromShortcut)
        XCTAssertEqual(shortcut.applyCallCount, 1)

        coordinator.shortcutRecorderDidChange(isAssigned: false, displayString: nil)
        XCTAssertFalse(coordinator.canContinueFromShortcut)
    }

    func testShortcutConfirmationPersistsAndAdvances() async {
        let model = FakeParakeetModelManager(initialState: .notInstalled)
        model.suspendsInstallation = true
        let coordinator = makeCoordinator(model: model)
        advanceThroughWelcomeAndShortcut(coordinator)
        await model.waitForInstallStart()

        XCTAssertTrue(defaults.bool(forKey: SetupCoordinator.completedShortcutOnboardingKey))
        XCTAssertEqual(coordinator.step, .preparing)
        model.resumeInstallation()
        await waitUntil { coordinator.step == .ready }
    }

    func testClearingShortcutLaterRecoversWithoutRedownload() {
        defaults.set(true, forKey: SetupCoordinator.completedWelcomeKey)
        defaults.set(true, forKey: SetupCoordinator.completedShortcutOnboardingKey)
        defaults.set(true, forKey: SetupCoordinator.dismissedReadyKey)
        let model = FakeParakeetModelManager(initialState: .installed)
        let shortcut = FakeShortcutOnboarding(hasAssignedShortcut: true)
        let coordinator = makeCoordinator(model: model, shortcut: shortcut)
        XCTAssertTrue(coordinator.allowsDictation)

        coordinator.shortcutRecorderDidChange(isAssigned: false, displayString: nil)
        XCTAssertEqual(coordinator.step, .shortcut)
        XCTAssertFalse(coordinator.allowsDictation)
        XCTAssertEqual(model.ensureInstalledCallCount, 0)
        XCTAssertTrue(defaults.bool(forKey: SetupCoordinator.completedShortcutOnboardingKey))
    }

    func testMicGrantedStartsInstallAfterShortcut() async {
        let model = FakeParakeetModelManager(initialState: .notInstalled)
        model.suspendsInstallation = true
        let mic = FakeMicrophonePermission(status: .undetermined)
        mic.statusAfterRequest = .granted
        let coordinator = makeCoordinator(model: model, microphone: mic)

        advanceThroughWelcomeAndShortcut(coordinator)
        await model.waitForInstallStart()
        XCTAssertEqual(coordinator.step, .preparing)
        XCTAssertEqual(model.ensureInstalledCallCount, 1)

        model.resumeInstallation()
        await waitUntil { coordinator.step == .ready }
        XCTAssertEqual(coordinator.step, .ready)
        XCTAssertEqual(model.state, .installed)
    }

    func testMicDeniedDoesNotInstall() async {
        let model = FakeParakeetModelManager(initialState: .notInstalled)
        let mic = FakeMicrophonePermission(status: .undetermined)
        mic.statusAfterRequest = .denied
        let coordinator = makeCoordinator(model: model, microphone: mic)

        advanceThroughWelcomeAndShortcut(coordinator)
        await waitUntil { coordinator.step == .microphoneDenied }

        XCTAssertEqual(coordinator.step, .microphoneDenied)
        XCTAssertEqual(model.ensureInstalledCallCount, 0)
    }

    func testDeniedWaitsForExplicitRetry() async {
        let model = FakeParakeetModelManager(initialState: .notInstalled)
        let mic = FakeMicrophonePermission(status: .denied)
        let coordinator = makeCoordinator(model: model, microphone: mic)

        advanceThroughWelcomeAndShortcut(coordinator)
        await waitUntil { coordinator.step == .microphoneDenied }

        XCTAssertEqual(mic.requestCallCount, 0)
        XCTAssertEqual(coordinator.step, .microphoneDenied)

        coordinator.retryMicrophone()
        await waitUntil { mic.requestCallCount == 1 }
        XCTAssertEqual(mic.requestCallCount, 1)
        XCTAssertEqual(model.ensureInstalledCallCount, 0)
    }

    func testMenuReentryAfterMicrophoneDeniedShowsRecovery() async {
        let model = FakeParakeetModelManager(initialState: .notInstalled)
        let mic = FakeMicrophonePermission(status: .undetermined)
        mic.statusAfterRequest = .denied
        let coordinator = makeCoordinator(model: model, microphone: mic)

        advanceThroughWelcomeAndShortcut(coordinator)
        await waitUntil { coordinator.step == .microphoneDenied }
        coordinator.markWindowVisible(false)
        coordinator.presentRequestedFromMenu()

        XCTAssertEqual(coordinator.step, .microphoneDenied)
        XCTAssertEqual(mic.requestCallCount, 1)
        XCTAssertEqual(model.ensureInstalledCallCount, 0)
    }

    func testSingleFlightInstallFromCoordinator() async {
        let model = FakeParakeetModelManager(initialState: .notInstalled)
        model.suspendsInstallation = true
        let coordinator = makeCoordinator(model: model)

        advanceThroughWelcomeAndShortcut(coordinator)
        await model.waitForInstallStart()
        coordinator.retryAfterFailure()

        XCTAssertEqual(model.ensureInstalledCallCount, 1)
        XCTAssertEqual(model.installOperationCount, 1)
        model.resumeInstallation()
        await waitUntil { coordinator.step == .ready }

        XCTAssertEqual(coordinator.step, .ready)
        XCTAssertEqual(model.ensureInstalledCallCount, 1)
    }

    func testRetryAfterFailure() async {
        let model = FakeParakeetModelManager(initialState: .notInstalled)
        var shouldFail = true
        model.ensureInstalledHandler = {
            if shouldFail {
                shouldFail = false
                throw TranscriptionError.recognitionFailed("boom")
            }
        }
        let coordinator = makeCoordinator(model: model)

        advanceThroughWelcomeAndShortcut(coordinator)
        await waitUntil { coordinator.step == .failed }
        XCTAssertEqual(coordinator.step, .failed)

        coordinator.retryAfterFailure()
        await waitUntil { coordinator.step == .ready }
        XCTAssertEqual(coordinator.step, .ready)
        XCTAssertEqual(model.state, .installed)
    }

    func testInstalledCacheWithoutShortcutConfirmationShowsShortcut() {
        let model = FakeParakeetModelManager(initialState: .installed)
        let coordinator = makeCoordinator(model: model)
        XCTAssertEqual(coordinator.step, .shortcut)
        XCTAssertEqual(model.ensureInstalledCallCount, 0)
    }

    func testExistingUserShortcutOnlyThenReady() {
        defaults.set(true, forKey: SetupCoordinator.completedWelcomeKey)
        let model = FakeParakeetModelManager(initialState: .installed)
        let coordinator = makeCoordinator(model: model)
        XCTAssertEqual(coordinator.step, .shortcut)
        confirmShortcut(coordinator)
        XCTAssertEqual(coordinator.step, .ready)
        XCTAssertEqual(model.ensureInstalledCallCount, 0)
    }

    func testPrewarmInvalidationReconcilesSetupAndRepairsCache() async {
        defaults.set(true, forKey: SetupCoordinator.completedWelcomeKey)
        defaults.set(true, forKey: SetupCoordinator.completedShortcutOnboardingKey)
        defaults.set(true, forKey: SetupCoordinator.dismissedReadyKey)
        let model = FakeParakeetModelManager(initialState: .installed)
        model.retainLoadBehavior = .missing
        let coordinator = makeCoordinator(model: model)
        let prewarm = ParakeetPrewarmCoordinator(
            modelManager: model,
            isEligible: { coordinator.allowsDictation },
            isParakeetProductionBackend: true,
            onModelStateChanged: { coordinator.modelPreparationDidChange() }
        )

        prewarm.evaluate(source: .launchReadiness)
        await waitUntil { model.ensureInstalledCallCount == 1 }
        await waitUntil { coordinator.step == .ready }

        XCTAssertEqual(model.loadInstalledAndRetainCallCount, 1)
        XCTAssertEqual(model.installOperationCount, 1)
        XCTAssertEqual(model.state, .installed)
    }

    func testDismissedReadyDoesNotAutoPresent() {
        defaults.set(true, forKey: SetupCoordinator.dismissedReadyKey)
        defaults.set(true, forKey: SetupCoordinator.completedShortcutOnboardingKey)
        let model = FakeParakeetModelManager(initialState: .installed)
        let coordinator = makeCoordinator(model: model)
        XCTAssertFalse(coordinator.shouldAutoPresent)
        XCTAssertNil(coordinator.menuActionTitle)
    }

    func testReactivationWhileModelLoadsPreservesCompletedSetup() {
        defaults.set(true, forKey: SetupCoordinator.dismissedReadyKey)
        defaults.set(true, forKey: SetupCoordinator.completedShortcutOnboardingKey)
        let model = FakeParakeetModelManager(initialState: .installed)
        let coordinator = makeCoordinator(model: model)

        model.setState(.loading)
        coordinator.applicationDidBecomeActive()

        XCTAssertTrue(defaults.bool(forKey: SetupCoordinator.dismissedReadyKey))
        XCTAssertEqual(coordinator.step, .ready)
        XCTAssertEqual(model.ensureInstalledCallCount, 0)
        XCTAssertNil(coordinator.menuActionTitle)
        XCTAssertNil(coordinator.menuStatusText)
    }

    func testMissingModelOverridesStaleDismissedPref() async {
        defaults.set(true, forKey: SetupCoordinator.dismissedReadyKey)
        defaults.set(true, forKey: SetupCoordinator.completedWelcomeKey)
        defaults.set(true, forKey: SetupCoordinator.completedShortcutOnboardingKey)
        let model = FakeParakeetModelManager(initialState: .notInstalled)
        model.suspendsInstallation = true
        let coordinator = makeCoordinator(model: model)
        await model.waitForInstallStart()
        XCTAssertFalse(defaults.bool(forKey: SetupCoordinator.dismissedReadyKey))
        XCTAssertTrue(coordinator.shouldAutoPresent)
        XCTAssertEqual(coordinator.menuActionTitle, "Getting Ready…")
        XCTAssertEqual(coordinator.menuStatusText, "Getting ready…")
        XCTAssertFalse(coordinator.allowsDictation)
        model.resumeInstallation()
        await waitUntil { coordinator.step == .ready }
    }

    func testMenuStatusWhileDownloading() {
        defaults.set(true, forKey: SetupCoordinator.completedShortcutOnboardingKey)
        let model = FakeParakeetModelManager(initialState: .downloading)
        let coordinator = makeCoordinator(
            model: model,
            microphone: FakeMicrophonePermission()
        )
        XCTAssertEqual(coordinator.menuActionTitle, "Getting Ready…")
        XCTAssertEqual(coordinator.menuStatusText, "Getting ready…")
        XCTAssertTrue(coordinator.blocksDictationUI)
        XCTAssertFalse(coordinator.allowsDictation)
    }

    func testInstalledAllowsDictationOnlyWhenShortcutConfirmedAndPermissionsGranted() {
        defaults.set(true, forKey: SetupCoordinator.dismissedReadyKey)
        defaults.set(true, forKey: SetupCoordinator.completedShortcutOnboardingKey)
        let model = FakeParakeetModelManager(initialState: .installed)
        let coordinator = makeCoordinator(model: model)
        XCTAssertTrue(coordinator.allowsDictation)
        XCTAssertFalse(coordinator.blocksDictationUI)
    }

    func testInstalledBlocksDictationWhenAccessibilityNotTrusted() {
        defaults.set(true, forKey: SetupCoordinator.dismissedReadyKey)
        defaults.set(true, forKey: SetupCoordinator.completedShortcutOnboardingKey)
        let model = FakeParakeetModelManager(initialState: .installed)
        let accessibility = FakeAccessibilityPermission(trustState: .notTrusted)
        let coordinator = makeCoordinator(model: model, accessibility: accessibility)
        XCTAssertFalse(coordinator.allowsDictation)
        XCTAssertTrue(coordinator.blocksDictationUI)
        XCTAssertEqual(coordinator.step, .textInsertion)
        XCTAssertEqual(coordinator.menuActionTitle, "Finish Setup…")
        XCTAssertEqual(coordinator.menuStatusText, "Text insertion permission needed")
        XCTAssertEqual(model.ensureInstalledCallCount, 0)
    }

    func testAccessibilityBeforeDownloadWhenMicGranted() async {
        let model = FakeParakeetModelManager(initialState: .notInstalled)
        let mic = FakeMicrophonePermission(status: .undetermined)
        mic.statusAfterRequest = .granted
        let accessibility = FakeAccessibilityPermission(trustState: .notTrusted)
        let coordinator = makeCoordinator(
            model: model,
            microphone: mic,
            accessibility: accessibility
        )

        advanceThroughWelcomeAndShortcut(coordinator)
        await waitUntil { coordinator.step == .textInsertion }
        XCTAssertEqual(coordinator.step, .textInsertion)
        XCTAssertEqual(model.ensureInstalledCallCount, 0)

        accessibility.trustAfterRequest = .trusted
        coordinator.requestTextInsertionAccess()
        await model.waitForInstallStart()
        XCTAssertEqual(coordinator.step, .preparing)
        XCTAssertEqual(model.ensureInstalledCallCount, 1)
        model.resumeInstallation()
        await waitUntil { coordinator.step == .ready }
    }

    func testAccessibilityDeniedDoesNotStartDownload() async {
        let model = FakeParakeetModelManager(initialState: .notInstalled)
        let accessibility = FakeAccessibilityPermission(trustState: .notTrusted)
        accessibility.trustAfterRequest = .notTrusted
        let coordinator = makeCoordinator(model: model, accessibility: accessibility)

        advanceThroughWelcomeAndShortcut(coordinator)
        await waitUntil { coordinator.step == .textInsertion || coordinator.step == .textInsertionDenied }
        coordinator.requestTextInsertionAccess()
        await waitUntil { coordinator.step == .textInsertionDenied }
        XCTAssertEqual(coordinator.step, .textInsertionDenied)
        XCTAssertEqual(model.ensureInstalledCallCount, 0)
        XCTAssertTrue(accessibility.hasOfferedPrompt)
    }

    func testExistingInstalledModelRoutesToTextInsertionWithoutRedownload() {
        defaults.set(true, forKey: SetupCoordinator.completedShortcutOnboardingKey)
        let model = FakeParakeetModelManager(initialState: .installed)
        let accessibility = FakeAccessibilityPermission(
            trustState: .notTrusted,
            hasOfferedPrompt: true
        )
        let coordinator = makeCoordinator(model: model, accessibility: accessibility)
        XCTAssertEqual(coordinator.step, .textInsertionDenied)
        XCTAssertEqual(model.ensureInstalledCallCount, 0)
    }

    func testAccessibilityGrantRestoresReadyWithoutRedownload() {
        defaults.set(true, forKey: SetupCoordinator.dismissedReadyKey)
        defaults.set(true, forKey: SetupCoordinator.completedShortcutOnboardingKey)
        let model = FakeParakeetModelManager(initialState: .installed)
        let accessibility = FakeAccessibilityPermission(trustState: .notTrusted)
        let coordinator = makeCoordinator(model: model, accessibility: accessibility)
        XCTAssertFalse(coordinator.allowsDictation)

        accessibility.trustState = .trusted
        coordinator.applicationDidBecomeActive()
        XCTAssertTrue(coordinator.allowsDictation)
        XCTAssertEqual(coordinator.step, .ready)
        XCTAssertEqual(model.ensureInstalledCallCount, 0)
    }

    func testAccessibilityRevokeUpdatesReadinessWithoutClearingInstall() {
        defaults.set(true, forKey: SetupCoordinator.dismissedReadyKey)
        defaults.set(true, forKey: SetupCoordinator.completedShortcutOnboardingKey)
        let model = FakeParakeetModelManager(initialState: .installed)
        let accessibility = FakeAccessibilityPermission(trustState: .trusted)
        let coordinator = makeCoordinator(model: model, accessibility: accessibility)
        XCTAssertTrue(coordinator.allowsDictation)

        accessibility.trustState = .notTrusted
        coordinator.applicationDidBecomeActive()
        XCTAssertFalse(coordinator.allowsDictation)
        XCTAssertEqual(coordinator.step, .textInsertion)
        XCTAssertTrue(defaults.bool(forKey: SetupCoordinator.dismissedReadyKey))
        XCTAssertEqual(model.ensureInstalledCallCount, 0)
    }

    func testOfferedPromptDoesNotProveReadiness() {
        defaults.set(true, forKey: SetupCoordinator.dismissedReadyKey)
        defaults.set(true, forKey: SetupCoordinator.completedShortcutOnboardingKey)
        let model = FakeParakeetModelManager(initialState: .installed)
        let accessibility = FakeAccessibilityPermission(
            trustState: .notTrusted,
            hasOfferedPrompt: true
        )
        let coordinator = makeCoordinator(model: model, accessibility: accessibility)
        XCTAssertFalse(coordinator.allowsDictation)
        XCTAssertEqual(coordinator.step, .textInsertionDenied)
    }

    func testInstalledBlocksDictationWhenMicrophoneDenied() {
        defaults.set(true, forKey: SetupCoordinator.dismissedReadyKey)
        defaults.set(true, forKey: SetupCoordinator.completedShortcutOnboardingKey)
        let model = FakeParakeetModelManager(initialState: .installed)
        let mic = FakeMicrophonePermission(status: .denied)
        let coordinator = makeCoordinator(model: model, microphone: mic)
        XCTAssertFalse(coordinator.allowsDictation)
        XCTAssertTrue(coordinator.blocksDictationUI)
        XCTAssertEqual(coordinator.menuActionTitle, "Finish Setup…")
        XCTAssertEqual(coordinator.menuStatusText, "Microphone access required")
        XCTAssertTrue(coordinator.shouldAutoPresent)
    }

    func testMicrophoneRevokeAndRegrantUpdatesReadinessWithoutRelaunch() {
        defaults.set(true, forKey: SetupCoordinator.dismissedReadyKey)
        defaults.set(true, forKey: SetupCoordinator.completedShortcutOnboardingKey)
        let model = FakeParakeetModelManager(initialState: .installed)
        let mic = FakeMicrophonePermission(status: .granted)
        let coordinator = makeCoordinator(model: model, microphone: mic)
        XCTAssertTrue(coordinator.allowsDictation)

        mic.status = .denied
        coordinator.applicationDidBecomeActive()
        XCTAssertFalse(coordinator.allowsDictation)
        XCTAssertTrue(coordinator.blocksDictationUI)
        XCTAssertEqual(coordinator.step, .microphoneDenied)

        mic.status = .granted
        coordinator.applicationDidBecomeActive()
        XCTAssertTrue(coordinator.allowsDictation)
        XCTAssertFalse(coordinator.blocksDictationUI)
        XCTAssertEqual(coordinator.step, .ready)
    }

    func testAcknowledgeReadyPersistsDismissal() {
        defaults.set(true, forKey: SetupCoordinator.completedShortcutOnboardingKey)
        let model = FakeParakeetModelManager(initialState: .installed)
        let coordinator = makeCoordinator(model: model)
        coordinator.acknowledgeReadyAndDismiss()
        XCTAssertTrue(defaults.bool(forKey: SetupCoordinator.dismissedReadyKey))
        XCTAssertFalse(coordinator.shouldAutoPresent)
    }

    func testConstructionDoesNotStartInstallOrMicRequest() {
        let model = FakeParakeetModelManager(initialState: .notInstalled)
        let mic = FakeMicrophonePermission(status: .undetermined)
        _ = makeCoordinator(model: model, microphone: mic)
        XCTAssertEqual(model.ensureInstalledCallCount, 0)
        XCTAssertEqual(mic.requestCallCount, 0)
        XCTAssertEqual(model.refreshCallCount, 1)
    }

    func testReturningUserConstructionRequestsMicAfterShortcutConfirmed() async {
        defaults.set(true, forKey: SetupCoordinator.completedWelcomeKey)
        defaults.set(true, forKey: SetupCoordinator.completedShortcutOnboardingKey)
        let model = FakeParakeetModelManager(initialState: .notInstalled)
        model.suspendsInstallation = true
        let mic = FakeMicrophonePermission(status: .undetermined)
        mic.statusAfterRequest = .granted

        let coordinator = makeCoordinator(model: model, microphone: mic)

        await model.waitForInstallStart()
        XCTAssertEqual(mic.requestCallCount, 1)
        XCTAssertEqual(model.ensureInstalledCallCount, 1)
        XCTAssertEqual(coordinator.step, .preparing)

        model.resumeInstallation()
        await waitUntil { coordinator.step == .ready }
    }

    func testWindowCloseDoesNotCancelInstall() async {
        let model = FakeParakeetModelManager(initialState: .notInstalled)
        model.suspendsInstallation = true
        let coordinator = makeCoordinator(model: model)

        advanceThroughWelcomeAndShortcut(coordinator)
        await model.waitForInstallStart()
        XCTAssertEqual(coordinator.step, .preparing)
        coordinator.markWindowVisible(false)
        model.resumeInstallation()
        await waitUntil { coordinator.step == .ready }
        XCTAssertEqual(model.state, .installed)
        XCTAssertEqual(coordinator.step, .ready)
    }

    func testReadyDisplaysLiveShortcutString() {
        defaults.set(true, forKey: SetupCoordinator.completedShortcutOnboardingKey)
        let shortcut = FakeShortcutOnboarding(
            hasAssignedShortcut: true,
            displayString: "⌃⌥D"
        )
        let coordinator = makeCoordinator(
            model: FakeParakeetModelManager(initialState: .installed),
            shortcut: shortcut
        )
        XCTAssertEqual(coordinator.step, .ready)
        XCTAssertEqual(coordinator.shortcutDisplayString, "⌃⌥D")
    }
}

final class ModelPreparationStateTests: XCTestCase {
    func testDerivedFlags() {
        XCTAssertTrue(ModelPreparationState.notInstalled.needsInstall)
        XCTAssertTrue(ModelPreparationState.downloading.isInstalling)
        XCTAssertTrue(ModelPreparationState.loading.isInstalling)
        XCTAssertTrue(ModelPreparationState.installed.isInstalled)
        XCTAssertTrue(ModelPreparationState.loaded.isLoaded)
        XCTAssertFalse(ModelPreparationState.installed.isLoaded)
        XCTAssertFalse(ModelPreparationState.loading.isInstalled)
        XCTAssertFalse(ModelPreparationState.downloading.allowsDictation)
        XCTAssertTrue(ModelPreparationState.installed.allowsDictation)
    }

    func testProgressETACopy() {
        let progress = ModelPreparationProgress(
            fraction: 0.4,
            detail: "Downloading…",
            estimatedSecondsRemaining: 125
        )
        XCTAssertEqual(progress.percentText, "40%")
        XCTAssertEqual(progress.estimatedTimeRemainingText, "About 3 minutes remaining")
    }
}
