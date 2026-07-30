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
private final class FakeDictationPlaybackController: DictationPlaybackControlling {
    private(set) var beginCount = 0
    private(set) var endCount = 0
    private(set) var shutdownCount = 0

    func beginListening() {
        beginCount += 1
    }

    func endListening() {
        endCount += 1
    }

    func shutdownForTermination() {
        shutdownCount += 1
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
private final class SuspendingTranscriptionService: TranscriptionServicing {
    enum Suspension {
        case none
        case prepare
        case stop
    }

    private let suspension: Suspension
    private var prepareContinuation: CheckedContinuation<Void, Never>?
    private var stopContinuation: CheckedContinuation<String, Error>?
    private var partialHandler: (@MainActor (String) -> Void)?
    private var audioLevelHandler: (@MainActor (Float) -> Void)?
    private(set) var prepareCallCount = 0
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private(set) var cancelCallCount = 0

    init(suspension: Suspension) {
        self.suspension = suspension
    }

    func prepare() async throws {
        prepareCallCount += 1
        guard suspension == .prepare else { return }
        await withCheckedContinuation { continuation in
            prepareContinuation = continuation
        }
    }

    func start(
        onPartialResult: @escaping @MainActor (String) -> Void,
        onAudioLevel: @escaping @MainActor (Float) -> Void
    ) async throws {
        startCallCount += 1
        partialHandler = onPartialResult
        audioLevelHandler = onAudioLevel
    }

    func stop() async throws -> String {
        stopCallCount += 1
        guard suspension == .stop else { return "Already detected" }
        return try await withCheckedThrowingContinuation { continuation in
            stopContinuation = continuation
        }
    }

    func cancel() async {
        cancelCallCount += 1
    }

    func resumePreparation() {
        prepareContinuation?.resume()
        prepareContinuation = nil
    }

    func resumeStop(with transcript: String) {
        stopContinuation?.resume(returning: transcript)
        stopContinuation = nil
    }

    func emitDetectedSpeech() {
        partialHandler?("Already detected")
        audioLevelHandler?(0.7)
    }
}

@MainActor
final class AssistantControllerTests: XCTestCase {
    func testPlaybackAttenuationMatchesListeningLifecycle() async {
        let playback = FakeDictationPlaybackController()
        let controller = AssistantController(
            transcription: MockTranscriptionService(
                behavior: .success(final: "Hello", partials: [])
            ),
            clipboard: FakeClipboard(),
            delivery: FakeTranscriptDelivery(result: .pasteEventPosted),
            targetProvider: FakeDictationTargetProvider(),
            playback: playback
        )

        await controller.startDictationFromShortcut()
        XCTAssertEqual(playback.beginCount, 1)
        XCTAssertEqual(playback.endCount, 0)

        await controller.stopDictation()
        XCTAssertEqual(playback.endCount, 1)
    }

    func testProgrammaticDictationNeverAdjustsPlayback() async {
        let playback = FakeDictationPlaybackController()
        let controller = AssistantController(
            transcription: MockTranscriptionService(
                behavior: .success(final: "Hello", partials: [])
            ),
            clipboard: FakeClipboard(),
            delivery: FakeTranscriptDelivery(result: .pasteEventPosted),
            targetProvider: FakeDictationTargetProvider(),
            playback: playback
        )

        await controller.startDictation()
        await controller.stopDictation()

        XCTAssertEqual(playback.beginCount, 0)
        XCTAssertEqual(playback.endCount, 0)
    }

    func testCancelDuringPreparingHidesImmediatelyAndPreventsCaptureStart() async {
        let transcription = SuspendingTranscriptionService(suspension: .prepare)
        let delivery = FakeTranscriptDelivery(result: .pasteEventPosted)
        let controller = AssistantController(
            transcription: transcription,
            clipboard: FakeClipboard(),
            delivery: delivery,
            targetProvider: FakeDictationTargetProvider()
        )

        let startTask = controller.beginDictationFromShortcut()
        await waitUntil { transcription.prepareCallCount == 1 }

        let cancelTask = controller.cancelDictation()

        XCTAssertEqual(controller.sessionState, .idle)
        XCTAssertNil(controller.activeSession)
        XCTAssertFalse(controller.canCancel)

        transcription.resumePreparation()
        await startTask?.value
        await cancelTask?.value

        XCTAssertEqual(transcription.startCallCount, 0)
        XCTAssertEqual(transcription.cancelCallCount, 1)
        XCTAssertTrue(delivery.deliveredTranscripts.isEmpty)
    }

    func testCancelAfterPartialSpeechDiscardsTranscriptAndRestoresPlayback() async {
        let transcription = SuspendingTranscriptionService(suspension: .none)
        let playback = FakeDictationPlaybackController()
        let delivery = FakeTranscriptDelivery(result: .pasteEventPosted)
        let controller = AssistantController(
            transcription: transcription,
            clipboard: FakeClipboard(),
            delivery: delivery,
            targetProvider: FakeDictationTargetProvider(),
            playback: playback
        )

        await controller.startDictationFromShortcut()
        transcription.emitDetectedSpeech()
        XCTAssertEqual(
            controller.sessionState,
            .listening(transcript: "Already detected")
        )

        let cancelTask = controller.cancelDictation()

        XCTAssertEqual(controller.sessionState, .idle)
        XCTAssertEqual(controller.audioLevel, 0)
        XCTAssertNil(controller.activeSession)
        XCTAssertEqual(playback.endCount, 1)

        await cancelTask?.value
        XCTAssertEqual(transcription.cancelCallCount, 1)
        XCTAssertTrue(delivery.deliveredTranscripts.isEmpty)
        XCTAssertNil(controller.lastCompletedTranscript)
    }

    func testCancelWhileFinishingDiscardsLateFinalTranscript() async {
        let transcription = SuspendingTranscriptionService(suspension: .stop)
        let delivery = FakeTranscriptDelivery(result: .pasteEventPosted)
        let controller = AssistantController(
            transcription: transcription,
            clipboard: FakeClipboard(),
            delivery: delivery,
            targetProvider: FakeDictationTargetProvider()
        )

        await controller.startDictation()
        transcription.emitDetectedSpeech()
        let stopTask = Task { await controller.stopDictation() }
        await waitUntil { transcription.stopCallCount == 1 }
        XCTAssertEqual(
            controller.sessionState,
            .finishing(transcript: "Already detected")
        )

        let cancelTask = controller.cancelDictation()

        XCTAssertEqual(controller.sessionState, .idle)
        XCTAssertNil(controller.activeSession)

        transcription.resumeStop(with: "Late final transcript")
        await stopTask.value
        await cancelTask?.value

        XCTAssertTrue(delivery.deliveredTranscripts.isEmpty)
        XCTAssertNil(controller.lastCompletedTranscript)
    }

    func testTerminationSynchronouslyShutsDownPlayback() {
        let playback = FakeDictationPlaybackController()
        let controller = AssistantController(
            transcription: MockTranscriptionService(),
            clipboard: FakeClipboard(),
            delivery: FakeTranscriptDelivery(result: .pasteEventPosted),
            targetProvider: FakeDictationTargetProvider(),
            playback: playback
        )

        controller.prepareForTermination()

        XCTAssertEqual(playback.shutdownCount, 1)
    }

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
