import Foundation
@testable import Timbre
import XCTest

@MainActor
final class FakeClipboard: ClipboardServicing {
    private(set) var copiedValues: [String] = []

    var lastCopied: String? { copiedValues.last }

    func copy(_ string: String) {
        copiedValues.append(string)
    }
}

@MainActor
final class AssistantControllerTests: XCTestCase {
    func testSuccessfulDictationCopiesFinalTranscript() async {
        let mock = MockTranscriptionService(
            behavior: .success(final: "Hello world", partials: ["Hello", "Hello world"]),
            partialDelayNanoseconds: 5_000_000
        )
        let clipboard = FakeClipboard()
        let controller = AssistantController(transcription: mock, clipboard: clipboard)

        await controller.startDictation()
        XCTAssertEqual(controller.sessionState, .listening(transcript: ""))

        await waitForTranscript(controller, containing: "Hello")
        await controller.stopDictation()

        XCTAssertEqual(controller.sessionState, .completed(transcript: "Hello world"))
        XCTAssertEqual(controller.liveTranscript, "Hello world")
        XCTAssertEqual(controller.lastCompletedTranscript, "Hello world")
        XCTAssertEqual(clipboard.lastCopied, "Hello world")
        XCTAssertEqual(controller.statusMessage, "Copied to clipboard.")
    }

    func testEmptyTranscriptionFailsWithoutClipboardWrite() async {
        let mock = MockTranscriptionService(
            behavior: .emptyResult,
            partialDelayNanoseconds: 1_000_000
        )
        let clipboard = FakeClipboard()
        let controller = AssistantController(transcription: mock, clipboard: clipboard)

        await controller.startDictation()
        await controller.stopDictation()

        XCTAssertEqual(
            controller.sessionState,
            .failed(message: TranscriptionError.emptyResult.localizedDescription, transcript: "")
        )
        XCTAssertTrue(clipboard.copiedValues.isEmpty)
        XCTAssertNil(controller.lastCompletedTranscript)
    }

    func testPreparePermissionErrorSetsFailedState() async {
        let mock = MockTranscriptionService(
            behavior: .prepareFailure(.speechPermissionDenied)
        )
        let clipboard = FakeClipboard()
        let controller = AssistantController(transcription: mock, clipboard: clipboard)

        await controller.startDictation()

        XCTAssertEqual(
            controller.sessionState,
            .failed(
                message: TranscriptionError.speechPermissionDenied.localizedDescription,
                transcript: ""
            )
        )
        XCTAssertTrue(clipboard.copiedValues.isEmpty)
    }

    func testRepeatedStartStopUsesLatestTranscriptForCopyAgain() async {
        let mock = MockTranscriptionService(
            behavior: .success(final: "First take", partials: ["First"]),
            partialDelayNanoseconds: 1_000_000
        )
        let clipboard = FakeClipboard()
        let controller = AssistantController(transcription: mock, clipboard: clipboard)

        await controller.startDictation()
        await controller.stopDictation()
        XCTAssertEqual(controller.lastCompletedTranscript, "First take")

        mock.behavior = .success(final: "Second take", partials: ["Second"])
        await controller.startDictation()
        await controller.stopDictation()

        XCTAssertEqual(controller.sessionState, .completed(transcript: "Second take"))
        XCTAssertEqual(controller.lastCompletedTranscript, "Second take")
        XCTAssertEqual(clipboard.copiedValues, ["First take", "Second take"])

        controller.copyLastTranscript()
        XCTAssertEqual(clipboard.copiedValues, ["First take", "Second take", "Second take"])
        XCTAssertEqual(controller.statusMessage, "Copied to clipboard.")
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
