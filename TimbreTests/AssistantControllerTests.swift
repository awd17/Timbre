import Foundation
@testable import Timbre
import XCTest

@MainActor
final class FakeClipboard: ClipboardServicing {
    private(set) var copiedValues: [String] = []
    var copySucceeds = true

    var lastCopied: String? { copiedValues.last }

    @discardableResult
    func copy(_ string: String) -> Bool {
        guard copySucceeds else { return false }
        copiedValues.append(string)
        return true
    }
}

@MainActor
final class FakeTranscriptDelivery: TranscriptDeliveryServicing {
    private(set) var deliveredTranscripts: [String] = []
    private(set) var deliveredTargets: [DictationTargetContext?] = []
    var result: TranscriptDeliveryResult = .pasteEventPosted
    private let clipboard: FakeClipboard?

    init(clipboard: FakeClipboard? = nil, result: TranscriptDeliveryResult = .pasteEventPosted) {
        self.clipboard = clipboard
        self.result = result
    }

    func deliver(
        _ transcript: String,
        to target: DictationTargetContext?
    ) async -> TranscriptDeliveryResult {
        deliveredTranscripts.append(transcript)
        deliveredTargets.append(target)
        clipboard?.copy(transcript)
        return result
    }
}

@MainActor
final class FakeDictationTargetProvider: DictationTargetProviding {
    var nextCapture: DictationTargetContext?
    var frontmostExternal: DictationTargetContext?
    var isSelfFrontmost = false
    private(set) var captureCallCount = 0
    private(set) var activateCallCount = 0
    var activateSucceeds = true

    func captureTarget() -> DictationTargetContext? {
        captureCallCount += 1
        return nextCapture
    }

    func frontmostExternalTarget() -> DictationTargetContext? {
        frontmostExternal
    }

    func activateTarget(_ target: DictationTargetContext) async -> Bool {
        activateCallCount += 1
        if activateSucceeds {
            frontmostExternal = target
            isSelfFrontmost = false
        }
        return activateSucceeds
    }
}

@MainActor
private final class RetainedLevelTranscriptionService: TranscriptionServicing {
    private var levelHandler: (@MainActor (Float) -> Void)?
    private var isRunning = false

    func prepare() async throws {}

    func start(
        onPartialResult: @escaping @MainActor (String) -> Void,
        onAudioLevel: @escaping @MainActor (Float) -> Void
    ) async throws {
        _ = onPartialResult
        isRunning = true
        levelHandler = onAudioLevel
    }

    func stop() async throws -> String {
        guard isRunning else { throw TranscriptionError.notRunning }
        isRunning = false
        return "Retained callback"
    }

    func cancel() async {
        isRunning = false
    }

    func emitLevel(_ level: Float) {
        levelHandler?(level)
    }
}

@MainActor
final class AssistantControllerTests: XCTestCase {
    func testBeginDictationTransitionsToPreparingSynchronously() {
        let controller = AssistantController(
            transcription: MockTranscriptionService(),
            clipboard: FakeClipboard(),
            delivery: FakeTranscriptDelivery(result: .pasteEventPosted),
            targetProvider: FakeDictationTargetProvider()
        )

        let task = controller.beginDictation()

        XCTAssertNotNil(task)
        XCTAssertEqual(controller.sessionState, .preparing)
    }

    func testBeginDictationPublishesPreparingSynchronously() {
        let controller = AssistantController(
            transcription: MockTranscriptionService(),
            clipboard: FakeClipboard(),
            delivery: FakeTranscriptDelivery(result: .pasteEventPosted),
            targetProvider: FakeDictationTargetProvider()
        )
        var observedStates: [SessionState] = []
        controller.setSessionStateHandler { observedStates.append($0) }

        _ = controller.beginDictation()

        XCTAssertEqual(observedStates.first, .preparing)
    }

    func testSuccessfulDictationDeliversFinalTranscript() async {
        let mock = MockTranscriptionService(
            behavior: .success(final: "Hello world", partials: ["Hello", "Hello world"]),
            partialDelayNanoseconds: 5_000_000
        )
        let clipboard = FakeClipboard()
        let delivery = FakeTranscriptDelivery(clipboard: clipboard, result: .pasteEventPosted)
        let targets = FakeDictationTargetProvider()
        targets.nextCapture = DictationTargetContext(
            processIdentifier: 42,
            bundleIdentifier: "com.apple.TextEdit",
            localizedName: "TextEdit"
        )
        let controller = AssistantController(
            transcription: mock,
            clipboard: clipboard,
            delivery: delivery,
            targetProvider: targets
        )

        await controller.startDictation()
        XCTAssertEqual(controller.sessionState, .listening(transcript: ""))
        XCTAssertEqual(targets.captureCallCount, 1)
        XCTAssertNotNil(controller.activeSession)

        await waitForTranscript(controller, containing: "Hello")
        await controller.stopDictation()

        XCTAssertEqual(
            controller.sessionState,
            .completed(transcript: "Hello world", outcome: .inserted)
        )
        XCTAssertEqual(controller.liveTranscript, "Hello world")
        XCTAssertEqual(controller.lastCompletedTranscript, "Hello world")
        XCTAssertEqual(delivery.deliveredTranscripts, ["Hello world"])
        XCTAssertEqual(delivery.deliveredTargets.first.flatMap { $0 }?.processIdentifier, 42)
        XCTAssertEqual(clipboard.lastCopied, "Hello world")
        XCTAssertEqual(controller.statusMessage, "Inserted.")
        XCTAssertNil(controller.activeSession)
    }

    func testFallbackDeliverySetsCouldNotInsertStatus() async {
        let mock = MockTranscriptionService(
            behavior: .success(final: "Hello", partials: ["Hello"]),
            partialDelayNanoseconds: 1_000_000
        )
        let clipboard = FakeClipboard()
        let delivery = FakeTranscriptDelivery(
            clipboard: clipboard,
            result: .copiedAfterInsertFailure(.frontmostChanged)
        )
        let controller = AssistantController(
            transcription: mock,
            clipboard: clipboard,
            delivery: delivery,
            targetProvider: FakeDictationTargetProvider()
        )

        await controller.startDictation()
        await controller.stopDictation()

        XCTAssertEqual(
            controller.sessionState,
            .completed(transcript: "Hello", outcome: .copiedAfterInsertFailure)
        )
        XCTAssertEqual(controller.statusMessage, "Couldn't insert text. Copied instead.")
    }

    func testEmptyTranscriptionFailsWithoutDelivery() async {
        let mock = MockTranscriptionService(
            behavior: .emptyResult,
            partialDelayNanoseconds: 1_000_000
        )
        let clipboard = FakeClipboard()
        let delivery = FakeTranscriptDelivery(clipboard: clipboard)
        let controller = AssistantController(
            transcription: mock,
            clipboard: clipboard,
            delivery: delivery,
            targetProvider: FakeDictationTargetProvider()
        )

        await controller.startDictation()
        await controller.stopDictation()

        XCTAssertEqual(
            controller.sessionState,
            .failed(
                kind: .noSpeech,
                message: TranscriptionError.emptyResult.localizedDescription,
                transcript: ""
            )
        )
        XCTAssertTrue(clipboard.copiedValues.isEmpty)
        XCTAssertTrue(delivery.deliveredTranscripts.isEmpty)
        XCTAssertNil(controller.lastCompletedTranscript)
        XCTAssertNil(controller.activeSession)
    }

    func testAudioLevelUpdatesOnlyDuringActiveSessionAndResetsOnStop() async {
        let mock = MockTranscriptionService(
            behavior: .success(final: "Hello", partials: ["Hello"]),
            partialDelayNanoseconds: 1_000_000
        )
        let controller = AssistantController(
            transcription: mock,
            clipboard: FakeClipboard(),
            delivery: FakeTranscriptDelivery(result: .pasteEventPosted),
            targetProvider: FakeDictationTargetProvider()
        )

        await controller.startDictation()
        await waitForTranscript(controller, containing: "Hello")
        XCTAssertGreaterThan(controller.audioLevel, 0)

        await controller.stopDictation()
        XCTAssertEqual(controller.audioLevel, 0)
    }

    func testLateAudioLevelFromCompletedSessionIsIgnored() async {
        let transcription = RetainedLevelTranscriptionService()
        let controller = AssistantController(
            transcription: transcription,
            clipboard: FakeClipboard(),
            delivery: FakeTranscriptDelivery(result: .pasteEventPosted),
            targetProvider: FakeDictationTargetProvider()
        )

        await controller.startDictation()
        transcription.emitLevel(0.8)
        XCTAssertEqual(controller.audioLevel, 0.8)

        await controller.stopDictation()
        transcription.emitLevel(1)

        XCTAssertEqual(controller.audioLevel, 0)
    }

    func testPreparePermissionErrorSetsFailedState() async {
        let mock = MockTranscriptionService(
            behavior: .prepareFailure(.speechPermissionDenied)
        )
        let clipboard = FakeClipboard()
        let delivery = FakeTranscriptDelivery(clipboard: clipboard)
        let controller = AssistantController(
            transcription: mock,
            clipboard: clipboard,
            delivery: delivery,
            targetProvider: FakeDictationTargetProvider()
        )

        await controller.startDictation()

        XCTAssertEqual(
            controller.sessionState,
            .failed(
                kind: .permission,
                message: TranscriptionError.speechPermissionDenied.localizedDescription,
                transcript: ""
            )
        )
        XCTAssertTrue(clipboard.copiedValues.isEmpty)
        XCTAssertTrue(delivery.deliveredTranscripts.isEmpty)
        XCTAssertNil(controller.activeSession)
    }

    func testRepeatedStartStopUsesLatestTranscriptForCopyAgain() async {
        let mock = MockTranscriptionService(
            behavior: .success(final: "First take", partials: ["First"]),
            partialDelayNanoseconds: 1_000_000
        )
        let clipboard = FakeClipboard()
        let delivery = FakeTranscriptDelivery(clipboard: clipboard, result: .pasteEventPosted)
        let controller = AssistantController(
            transcription: mock,
            clipboard: clipboard,
            delivery: delivery,
            targetProvider: FakeDictationTargetProvider()
        )

        await controller.startDictation()
        await controller.stopDictation()
        XCTAssertEqual(controller.lastCompletedTranscript, "First take")

        mock.behavior = .success(final: "Second take", partials: ["Second"])
        await controller.startDictation()
        await controller.stopDictation()

        XCTAssertEqual(
            controller.sessionState,
            .completed(transcript: "Second take", outcome: .inserted)
        )
        XCTAssertEqual(controller.lastCompletedTranscript, "Second take")
        XCTAssertEqual(clipboard.copiedValues, ["First take", "Second take"])
        XCTAssertEqual(delivery.deliveredTranscripts, ["First take", "Second take"])

        controller.copyLastTranscript()
        XCTAssertEqual(clipboard.copiedValues, ["First take", "Second take", "Second take"])
        XCTAssertEqual(delivery.deliveredTranscripts.count, 2)
        XCTAssertEqual(controller.statusMessage, "Copied to clipboard.")
    }

    func testCopyAgainReportsClipboardFailureWithoutDeliveringAgain() async {
        let mock = MockTranscriptionService(
            behavior: .success(final: "Keep me", partials: []),
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

        await controller.startDictation()
        await controller.stopDictation()
        clipboard.copySucceeds = false

        controller.copyLastTranscript()

        XCTAssertEqual(controller.statusMessage, "Couldn't copy or insert text.")
        XCTAssertEqual(delivery.deliveredTranscripts, ["Keep me"])
    }

    func testNewStartReplacesSessionContext() async {
        let mock = MockTranscriptionService(
            behavior: .success(final: "One", partials: ["One"]),
            partialDelayNanoseconds: 1_000_000
        )
        let targets = FakeDictationTargetProvider()
        targets.nextCapture = DictationTargetContext(
            processIdentifier: 1,
            bundleIdentifier: "a.b",
            localizedName: "A"
        )
        let controller = AssistantController(
            transcription: mock,
            clipboard: FakeClipboard(),
            delivery: FakeTranscriptDelivery(result: .pasteEventPosted),
            targetProvider: targets
        )

        await controller.startDictation()
        let firstID = controller.activeSession?.id
        XCTAssertNotNil(firstID)

        await controller.stopDictation()
        targets.nextCapture = DictationTargetContext(
            processIdentifier: 2,
            bundleIdentifier: "c.d",
            localizedName: "C"
        )
        mock.behavior = .success(final: "Two", partials: ["Two"])
        await controller.startDictation()
        let secondID = controller.activeSession?.id
        XCTAssertNotNil(secondID)
        XCTAssertNotEqual(firstID, secondID)
        XCTAssertEqual(controller.activeSession?.target?.processIdentifier, 2)
    }

    private func waitForTranscript(
        _ controller: AssistantController,
        containing needle: String,
        timeoutNanoseconds: UInt64 = 200_000_000
    ) async {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if controller.liveTranscript.contains(needle) {
                return
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
