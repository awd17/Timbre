import Foundation
@testable import Timbre
import XCTest

final class TimbreSetupFeatureTests: XCTestCase {
    func testReleaseStyleDisabledWhenNotDebugPath() {
        // Release always returns false via #else; in DEBUG we still verify force-off args.
        XCTAssertFalse(
            TimbreSetupFeature.isEnabled(arguments: ["--mock-transcription"])
        )
        XCTAssertFalse(
            TimbreSetupFeature.isEnabled(arguments: ["--parakeet-fixture"])
        )
        XCTAssertFalse(
            TimbreSetupFeature.isEnabled(arguments: ["--disable-setup"])
        )
    }

#if DEBUG
    func testDebugEnabledByDefault() {
        XCTAssertTrue(TimbreSetupFeature.isEnabled(arguments: ["/path/to/Timbre"]))
    }
#endif
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

    func testFeatureOffNeverAutoPresents() {
        let model = FakeParakeetModelManager(initialState: .notInstalled)
        let mic = FakeMicrophonePermission()
        let coordinator = SetupCoordinator(
            modelManager: model,
            microphone: mic,
            defaults: defaults,
            featureEnabled: false
        )
        XCTAssertFalse(coordinator.shouldAutoPresent)
        XCTAssertNil(coordinator.menuActionTitle)
        XCTAssertNil(coordinator.menuStatusText)
        XCTAssertEqual(model.refreshCallCount, 0)
    }

    func testInitializationRefreshesAvailabilityOnceWhenEnabled() {
        let model = FakeParakeetModelManager(initialState: .notInstalled)
        _ = SetupCoordinator(
            modelManager: model,
            microphone: FakeMicrophonePermission(),
            defaults: defaults,
            featureEnabled: true
        )

        XCTAssertEqual(model.refreshCallCount, 1)
    }

    func testMicGrantedStartsInstall() async {
        let model = FakeParakeetModelManager(initialState: .notInstalled)
        model.suspendsInstallation = true
        let mic = FakeMicrophonePermission(status: .undetermined)
        mic.statusAfterRequest = .granted
        let coordinator = SetupCoordinator(
            modelManager: model,
            microphone: mic,
            defaults: defaults,
            featureEnabled: true
        )

        coordinator.continueFromWelcome()
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
        let coordinator = SetupCoordinator(
            modelManager: model,
            microphone: mic,
            defaults: defaults,
            featureEnabled: true
        )

        coordinator.continueFromWelcome()
        await waitUntil { coordinator.step == .microphoneDenied }

        XCTAssertEqual(coordinator.step, .microphoneDenied)
        XCTAssertEqual(model.ensureInstalledCallCount, 0)
    }

    func testDeniedDoesNotReRequestPrompt() async {
        let model = FakeParakeetModelManager(initialState: .notInstalled)
        let mic = FakeMicrophonePermission(status: .denied)
        let coordinator = SetupCoordinator(
            modelManager: model,
            microphone: mic,
            defaults: defaults,
            featureEnabled: true
        )

        coordinator.continueFromWelcome()
        await waitUntil { coordinator.step == .microphoneDenied }

        XCTAssertEqual(mic.requestCallCount, 1)
        XCTAssertEqual(coordinator.step, .microphoneDenied)

        coordinator.retryMicrophone()
        await waitUntil { mic.requestCallCount == 2 }
        XCTAssertEqual(mic.requestCallCount, 2)
        XCTAssertEqual(model.ensureInstalledCallCount, 0)
    }

    func testMenuReentryAfterMicrophoneDeniedShowsRecovery() async {
        let model = FakeParakeetModelManager(initialState: .notInstalled)
        let mic = FakeMicrophonePermission(status: .undetermined)
        mic.statusAfterRequest = .denied
        let coordinator = SetupCoordinator(
            modelManager: model,
            microphone: mic,
            defaults: defaults,
            featureEnabled: true
        )

        coordinator.continueFromWelcome()
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
        let mic = FakeMicrophonePermission(status: .granted)
        let coordinator = SetupCoordinator(
            modelManager: model,
            microphone: mic,
            defaults: defaults,
            featureEnabled: true
        )

        coordinator.continueFromWelcome()
        await model.waitForInstallStart()
        // A second request while preparing should join the fake's in-flight operation.
        coordinator.retryAfterFailure()
        await waitUntil { model.ensureInstalledCallCount == 2 }

        XCTAssertEqual(model.installOperationCount, 1)
        model.resumeInstallation()
        await waitUntil { coordinator.step == .ready }

        XCTAssertEqual(coordinator.step, .ready)
        XCTAssertEqual(model.ensureInstalledCallCount, 2)
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
        let mic = FakeMicrophonePermission(status: .granted)
        let coordinator = SetupCoordinator(
            modelManager: model,
            microphone: mic,
            defaults: defaults,
            featureEnabled: true
        )

        coordinator.continueFromWelcome()
        await waitUntil { coordinator.step == .failed }
        XCTAssertEqual(coordinator.step, .failed)

        coordinator.retryAfterFailure()
        await waitUntil { coordinator.step == .ready }
        XCTAssertEqual(coordinator.step, .ready)
        XCTAssertEqual(model.state, .installed)
    }

    func testInstalledCacheSkipsWelcomeDownloadPitch() {
        let model = FakeParakeetModelManager(initialState: .installed)
        let mic = FakeMicrophonePermission(status: .granted)
        let coordinator = SetupCoordinator(
            modelManager: model,
            microphone: mic,
            defaults: defaults,
            featureEnabled: true
        )
        XCTAssertEqual(coordinator.step, .ready)
        XCTAssertTrue(coordinator.shouldAutoPresent)
        XCTAssertEqual(model.ensureInstalledCallCount, 0)
    }

    func testDismissedReadyDoesNotAutoPresent() {
        defaults.set(true, forKey: SetupCoordinator.dismissedReadyKey)
        let model = FakeParakeetModelManager(initialState: .installed)
        let mic = FakeMicrophonePermission(status: .granted)
        let coordinator = SetupCoordinator(
            modelManager: model,
            microphone: mic,
            defaults: defaults,
            featureEnabled: true
        )
        XCTAssertFalse(coordinator.shouldAutoPresent)
        XCTAssertNil(coordinator.menuActionTitle)
    }

    func testMissingModelOverridesStaleDismissedPref() {
        defaults.set(true, forKey: SetupCoordinator.dismissedReadyKey)
        defaults.set(true, forKey: SetupCoordinator.completedWelcomeKey)
        let model = FakeParakeetModelManager(initialState: .notInstalled)
        let mic = FakeMicrophonePermission(status: .granted)
        let coordinator = SetupCoordinator(
            modelManager: model,
            microphone: mic,
            defaults: defaults,
            featureEnabled: true
        )
        XCTAssertTrue(coordinator.shouldAutoPresent)
        XCTAssertEqual(coordinator.menuActionTitle, "Finish Setup…")
        XCTAssertEqual(coordinator.menuStatusText, "Setup required")
    }

    func testMenuStatusWhileDownloading() {
        let model = FakeParakeetModelManager(initialState: .downloading)
        let mic = FakeMicrophonePermission()
        let coordinator = SetupCoordinator(
            modelManager: model,
            microphone: mic,
            defaults: defaults,
            featureEnabled: true
        )
        XCTAssertEqual(coordinator.menuActionTitle, "Getting Ready…")
        XCTAssertEqual(coordinator.menuStatusText, "Getting ready…")
        XCTAssertTrue(coordinator.blocksDictationUI)
        XCTAssertFalse(coordinator.allowsDictation)
    }

    func testInstalledAllowsDictation() {
        defaults.set(true, forKey: SetupCoordinator.dismissedReadyKey)
        let model = FakeParakeetModelManager(initialState: .installed)
        let mic = FakeMicrophonePermission()
        let coordinator = SetupCoordinator(
            modelManager: model,
            microphone: mic,
            defaults: defaults,
            featureEnabled: true
        )
        XCTAssertTrue(coordinator.allowsDictation)
        XCTAssertFalse(coordinator.blocksDictationUI)
    }

    func testAcknowledgeReadyPersistsDismissal() {
        let model = FakeParakeetModelManager(initialState: .installed)
        let mic = FakeMicrophonePermission()
        let coordinator = SetupCoordinator(
            modelManager: model,
            microphone: mic,
            defaults: defaults,
            featureEnabled: true
        )
        coordinator.acknowledgeReadyAndDismiss()
        XCTAssertTrue(defaults.bool(forKey: SetupCoordinator.dismissedReadyKey))
        XCTAssertFalse(coordinator.shouldAutoPresent)
    }

    func testWindowCloseDoesNotCancelInstall() async {
        let model = FakeParakeetModelManager(initialState: .notInstalled)
        model.suspendsInstallation = true
        let mic = FakeMicrophonePermission(status: .granted)
        let coordinator = SetupCoordinator(
            modelManager: model,
            microphone: mic,
            defaults: defaults,
            featureEnabled: true
        )

        coordinator.continueFromWelcome()
        await model.waitForInstallStart()
        XCTAssertEqual(coordinator.step, .preparing)
        coordinator.markWindowVisible(false)
        model.resumeInstallation()
        await waitUntil { coordinator.step == .ready }
        XCTAssertEqual(model.state, .installed)
        XCTAssertEqual(coordinator.step, .ready)
    }
}

@MainActor
final class FakeParakeetModelManagerSingleFlightTests: XCTestCase {
    func testConcurrentEnsureInstalledSharesOneOperation() async throws {
        let model = FakeParakeetModelManager(initialState: .notInstalled)
        model.suspendsInstallation = true

        async let first: Void = model.ensureInstalled()
        async let second: Void = model.ensureInstalled()
        await model.waitForInstallStart()
        await waitUntil { model.ensureInstalledCallCount == 2 }
        XCTAssertEqual(model.installOperationCount, 1)
        model.resumeInstallation()
        try await first
        try await second

        XCTAssertEqual(model.ensureInstalledCallCount, 2)
        XCTAssertEqual(model.state, .installed)
    }

    func testInstallEndsInstalledNotLoaded() async throws {
        let model = FakeParakeetModelManager(initialState: .notInstalled)
        try await model.ensureInstalled()
        XCTAssertEqual(model.state, .installed)
        XCTAssertFalse(model.state.isLoaded)
    }
}

@MainActor
private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
    while !condition() {
        await Task.yield()
    }
}

final class ModelPreparationStateTests: XCTestCase {
    func testDerivedFlags() {
        XCTAssertTrue(ModelPreparationState.notInstalled.needsInstall)
        XCTAssertTrue(ModelPreparationState.downloading.isInstalling)
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
