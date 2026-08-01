import Foundation
@testable import Timbre
import XCTest

@MainActor
final class DictationShortcutCoordinatorTests: XCTestCase {
    func testStartRegistersOnceAndStopUnregistersOnce() {
        let fake = FakeGlobalShortcutService()
        let controller = makeController()
        let coordinator = DictationShortcutCoordinator(
            controller: controller,
            setupCoordinator: nil,
            shortcutService: fake
        )

        coordinator.start()
        coordinator.start()
        XCTAssertEqual(fake.startCount, 1)

        coordinator.stop()
        coordinator.stop()
        XCTAssertEqual(fake.stopCount, 1)
    }

    func testPressWhileIdleStartsDictation() async {
        let fake = FakeGlobalShortcutService()
        let mock = MockTranscriptionService(
            behavior: .success(final: "hello", partials: ["hello"]),
            partialDelayNanoseconds: 1_000_000
        )
        let controller = makeController(transcription: mock)
        let coordinator = DictationShortcutCoordinator(
            controller: controller,
            setupCoordinator: nil,
            shortcutService: fake
        )
        coordinator.start()

        fake.fire()
        XCTAssertEqual(controller.sessionState, .preparing)
        await waitUntil(controller) {
            if case .listening = $0.sessionState { return true }
            return false
        }

        guard case .listening = controller.sessionState else {
            XCTFail("Expected listening after shortcut start, got \(controller.sessionState)")
            return
        }
    }

    func testPressWhileListeningStopsDictation() async {
        let fake = FakeGlobalShortcutService()
        let mock = MockTranscriptionService(
            behavior: .success(final: "hello", partials: []),
            partialDelayNanoseconds: 0
        )
        let clipboard = FakeClipboard()
        let delivery = FakeTranscriptDelivery(clipboard: clipboard, result: .pasteEventPosted)
        let controller = AssistantController(
            transcription: mock,
            clipboard: clipboard,
            delivery: delivery,
            targetProvider: FakeDictationTargetProvider()
        )
        let coordinator = DictationShortcutCoordinator(
            controller: controller,
            setupCoordinator: nil,
            shortcutService: fake
        )
        coordinator.start()

        await controller.startDictation()
        XCTAssertEqual(controller.sessionState, .listening(transcript: ""))

        fake.fire()
        await waitUntil(controller) {
            if case .completed = $0.sessionState { return true }
            if case .failed = $0.sessionState { return true }
            return false
        }

        XCTAssertEqual(
            controller.sessionState,
            .completed(transcript: "hello", outcome: .inserted)
        )
        XCTAssertEqual(clipboard.lastCopied, "hello")
    }

    func testPerformanceTimingIncludesShortcutDispatchDelay() async throws {
        let fake = FakeGlobalShortcutService()
        let mock = MockTranscriptionService(
            behavior: .success(final: "hello", partials: []),
            partialDelayNanoseconds: 0
        )
        var startToPreparing: Double?
        var stopToCompletion: Double?
        let controller = AssistantController(
            transcription: mock,
            clipboard: FakeClipboard(),
            delivery: FakeTranscriptDelivery(result: .pasteEventPosted),
            targetProvider: FakeDictationTargetProvider(),
            performanceReporter: { event in
                switch event {
                case .startToPreparing(let milliseconds):
                    startToPreparing = milliseconds
                case .stopToCompletion(let milliseconds):
                    stopToCompletion = milliseconds
                case .startToListening:
                    break
                }
            }
        )
        let coordinator = DictationShortcutCoordinator(
            controller: controller,
            setupCoordinator: nil,
            shortcutService: fake
        )
        coordinator.start()

        let startRequestedAt = DispatchTime.now().uptimeNanoseconds - 50_000_000
        fake.fire(requestedAt: startRequestedAt)

        XCTAssertGreaterThan(try XCTUnwrap(startToPreparing), 40)
        await waitUntil(controller) {
            if case .listening = $0.sessionState { return true }
            return false
        }

        let stopRequestedAt = DispatchTime.now().uptimeNanoseconds - 50_000_000
        fake.fire(requestedAt: stopRequestedAt)
        await waitUntil(controller) {
            if case .completed = $0.sessionState { return true }
            return false
        }

        XCTAssertGreaterThan(try XCTUnwrap(stopToCompletion), 40)
    }

    func testRapidPressDuringPreparingDoesNotStartSecondSession() async {
        let fake = FakeGlobalShortcutService()
        let mock = MockTranscriptionService(
            behavior: .success(final: "one", partials: []),
            partialDelayNanoseconds: 50_000_000
        )
        let controller = makeController(transcription: mock)
        let coordinator = DictationShortcutCoordinator(
            controller: controller,
            setupCoordinator: nil,
            shortcutService: fake
        )
        coordinator.start()

        fake.fire()
        fake.fire()
        fake.fire()

        await waitUntil(controller) {
            if case .listening = $0.sessionState { return true }
            if case .failed = $0.sessionState { return true }
            return false
        }

        XCTAssertEqual(controller.sessionState, .listening(transcript: ""))
    }

    func testSetupBlockedPresentsSetupNotStart() {
        let fake = FakeGlobalShortcutService()
        let controller = makeController()
        let model = FakeParakeetModelManager(initialState: .notInstalled)
        let mic = FakeMicrophonePermission(status: .undetermined)
        let setup = SetupCoordinator(
            modelManager: model,
            microphone: mic,
            accessibility: FakeAccessibilityPermission(trustState: .trusted),
            defaults: UserDefaults(suiteName: UUID().uuidString)!,
            shortcutOnboarding: FakeShortcutOnboarding(),
            featureEnabled: true
        )
        var presented = 0
        let coordinator = DictationShortcutCoordinator(
            controller: controller,
            setupCoordinator: setup,
            shortcutService: fake,
            presentSetup: { presented += 1 }
        )
        coordinator.start()

        XCTAssertTrue(setup.blocksDictationUI)
        fake.fire()
        XCTAssertEqual(presented, 1)
        XCTAssertEqual(controller.sessionState, .idle)
    }

    func testSetupInstallingIgnoresPress() {
        let fake = FakeGlobalShortcutService()
        let controller = makeController()
        let model = FakeParakeetModelManager(initialState: .downloading)
        let mic = FakeMicrophonePermission(status: .granted)
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(true, forKey: SetupCoordinator.completedShortcutOnboardingKey)
        let setup = SetupCoordinator(
            modelManager: model,
            microphone: mic,
            accessibility: FakeAccessibilityPermission(trustState: .trusted),
            defaults: defaults,
            shortcutOnboarding: FakeShortcutOnboarding(),
            featureEnabled: true
        )
        var presented = 0
        let coordinator = DictationShortcutCoordinator(
            controller: controller,
            setupCoordinator: setup,
            shortcutService: fake,
            presentSetup: { presented += 1 }
        )
        coordinator.start()

        fake.fire()
        XCTAssertEqual(presented, 0)
        XCTAssertEqual(controller.sessionState, .idle)
    }

    func testFailedListeningObservationDoesNotCrash() {
        let fake = FakeGlobalShortcutService()
        let controller = makeController()
        let coordinator = DictationShortcutCoordinator(
            controller: controller,
            setupCoordinator: nil,
            shortcutService: fake
        )
        coordinator.start()
        fake.isListening = false
        XCTAssertFalse(coordinator.isListening)
        fake.fire()
        XCTAssertNil(coordinator.menuHintText())
    }

    private func makeController(
        transcription: TranscriptionServicing? = nil
    ) -> AssistantController {
        AssistantController(
            transcription: transcription ?? MockTranscriptionService(
                behavior: .success(final: "x", partials: []),
                partialDelayNanoseconds: 0
            ),
            clipboard: FakeClipboard(),
            delivery: FakeTranscriptDelivery(result: .pasteEventPosted),
            targetProvider: FakeDictationTargetProvider()
        )
    }

    private func waitUntil(
        _ controller: AssistantController,
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        _ predicate: (AssistantController) -> Bool
    ) async {
        let start = DispatchTime.now().uptimeNanoseconds
        while !predicate(controller) {
            if DispatchTime.now().uptimeNanoseconds - start > timeoutNanoseconds {
                XCTFail("Timed out waiting for controller state: \(controller.sessionState)")
                return
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
