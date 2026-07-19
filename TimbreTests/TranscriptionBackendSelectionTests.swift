import Foundation
@testable import Timbre
import XCTest

final class TranscriptionBackendSelectionTests: XCTestCase {
    func testReleaseAlwaysSelectsAppleSpeech() {
        let resolution = TranscriptionBackendSelection.resolve(
            arguments: [
                "--mock-transcription",
                "--parakeet-transcription",
            ],
            isDebug: false
        )
        XCTAssertEqual(resolution.backend, .appleSpeech)
        XCTAssertFalse(resolution.conflictingFlagsIgnoredParakeet)
    }

    func testDebugDefaultIsAppleSpeech() {
        let resolution = TranscriptionBackendSelection.resolve(arguments: ["Timbre"], isDebug: true)
        XCTAssertEqual(resolution.backend, .appleSpeech)
    }

    func testDebugMockArgument() {
        let resolution = TranscriptionBackendSelection.resolve(
            arguments: ["Timbre", "--mock-transcription"],
            isDebug: true
        )
        XCTAssertEqual(resolution.backend, .mock)
        XCTAssertFalse(resolution.conflictingFlagsIgnoredParakeet)
    }

    func testDebugParakeetArgument() {
        let resolution = TranscriptionBackendSelection.resolve(
            arguments: ["Timbre", "--parakeet-transcription"],
            isDebug: true
        )
        XCTAssertEqual(resolution.backend, .parakeet)
    }

    func testMockWinsOverParakeet() {
        let resolution = TranscriptionBackendSelection.resolve(
            arguments: [
                "Timbre",
                "--parakeet-transcription",
                "--mock-transcription",
            ],
            isDebug: true
        )
        XCTAssertEqual(resolution.backend, .mock)
        XCTAssertTrue(resolution.conflictingFlagsIgnoredParakeet)
    }

    func testParakeetFixtureRequiresParakeetBackend() {
        XCTAssertFalse(
            TranscriptionBackendSelection.wantsParakeetFixture(
                arguments: ["Timbre", "--parakeet-fixture"],
                isDebug: true
            )
        )
        XCTAssertTrue(
            TranscriptionBackendSelection.wantsParakeetFixture(
                arguments: [
                    "Timbre",
                    "--parakeet-transcription",
                    "--parakeet-fixture",
                ],
                isDebug: true
            )
        )
        XCTAssertFalse(
            TranscriptionBackendSelection.wantsParakeetFixture(
                arguments: [
                    "Timbre",
                    "--parakeet-transcription",
                    "--parakeet-fixture",
                ],
                isDebug: false
            )
        )
    }
}

final class ParakeetTranscriptValidationTests: XCTestCase {
    func testSoftValidateMatchesSmokeExpectations() {
        let transcript =
            "Tambour smoke test, the quick brown fox jumps over the lazy dog. Please recognize this for parakeet."
        let result = ParakeetTranscriptValidation.softValidate(transcript: transcript)
        XCTAssertTrue(result.passed)
        XCTAssertTrue(result.hasQuickBrownFox)
        XCTAssertTrue(result.hasLazyDog)
        XCTAssertEqual(result.matchedOptionalPhrase, "smoke test")
    }

    func testSoftValidateRejectsEmpty() {
        XCTAssertFalse(ParakeetTranscriptValidation.softValidate(transcript: "").passed)
    }
}

@MainActor
final class SessionStateTests: XCTestCase {
    func testPreparingAndProcessingStatusMessages() {
        XCTAssertEqual(SessionState.preparing.statusMessage, "Preparing...")
        XCTAssertEqual(
            SessionState.finishing(transcript: "x").statusMessage,
            "Processing..."
        )
        XCTAssertFalse(SessionState.preparing.canStart)
        XCTAssertFalse(SessionState.preparing.canStop)
        XCTAssertTrue(SessionState.listening(transcript: "").canStop)
    }
}
