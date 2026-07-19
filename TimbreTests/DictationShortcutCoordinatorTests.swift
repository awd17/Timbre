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
        let controller = AssistantController(transcription: mock, clipboard: FakeClipboard())
        let coordinator = DictationShortcutCoordinator(
            controller: controller,
            setupCoordinator: nil,
            shortcutService: fake
        )
        coordinator.start()

        fake.fire()
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
        let controller = AssistantController(transcription: mock, clipboard: clipboard)
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

        XCTAssertEqual(controller.sessionState, .completed(transcript: "hello"))
        XCTAssertEqual(clipboard.lastCopied, "hello")
    }

    func testRapidPressDuringPreparingDoesNotStartSecondSession() async {
        let fake = FakeGlobalShortcutService()
        let mock = MockTranscriptionService(
            behavior: .success(final: "one", partials: []),
            partialDelayNanoseconds: 50_000_000
        )
        let controller = AssistantController(transcription: mock, clipboard: FakeClipboard())
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
            defaults: UserDefaults(suiteName: UUID().uuidString)!,
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
        let setup = SetupCoordinator(
            modelManager: model,
            microphone: mic,
            defaults: UserDefaults(suiteName: UUID().uuidString)!,
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

    private func makeController() -> AssistantController {
        AssistantController(
            transcription: MockTranscriptionService(
                behavior: .success(final: "x", partials: []),
                partialDelayNanoseconds: 0
            ),
            clipboard: FakeClipboard()
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
