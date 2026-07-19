import Foundation
@testable import Timbre
import XCTest

final class TranscriptionBackendSelectionTests: XCTestCase {
    func testReleaseAlwaysSelectsParakeet() {
        let resolution = TranscriptionBackendSelection.resolve(
            arguments: [
                "--mock-transcription",
                "--parakeet-transcription",
                "--apple-speech",
                "--parakeet-fixture",
                "--disable-setup",
            ],
            isDebug: false
        )
        XCTAssertEqual(resolution.backend, .parakeet)
        XCTAssertTrue(resolution.deprecatedParakeetFlagPresent)
        XCTAssertNil(resolution.conflictWinner)
    }

    func testReleaseIgnoresDeveloperFlags() {
        XCTAssertEqual(
            TranscriptionBackendSelection.resolve(arguments: ["Timbre"], isDebug: false).backend,
            .parakeet
        )
        XCTAssertEqual(
            TranscriptionBackendSelection.resolve(
                arguments: ["Timbre", "--apple-speech"],
                isDebug: false
            ).backend,
            .parakeet
        )
        XCTAssertFalse(
            TranscriptionBackendSelection.wantsParakeetFixture(
                arguments: ["Timbre", "--parakeet-fixture"],
                isDebug: false
            )
        )
    }

    func testDebugDefaultIsParakeet() {
        let resolution = TranscriptionBackendSelection.resolve(arguments: ["Timbre"], isDebug: true)
        XCTAssertEqual(resolution.backend, .parakeet)
        XCTAssertFalse(resolution.deprecatedParakeetFlagPresent)
        XCTAssertNil(resolution.conflictWinner)
    }

    func testDebugMockArgument() {
        let resolution = TranscriptionBackendSelection.resolve(
            arguments: ["Timbre", "--mock-transcription"],
            isDebug: true
        )
        XCTAssertEqual(resolution.backend, .mock)
        XCTAssertNil(resolution.conflictWinner)
    }

    func testDebugAppleSpeechArgument() {
        let resolution = TranscriptionBackendSelection.resolve(
            arguments: ["Timbre", "--apple-speech"],
            isDebug: true
        )
        XCTAssertEqual(resolution.backend, .appleSpeech)
    }

    func testDeprecatedParakeetFlagDoesNotChangeDefault() {
        let resolution = TranscriptionBackendSelection.resolve(
            arguments: ["Timbre", "--parakeet-transcription"],
            isDebug: true
        )
        XCTAssertEqual(resolution.backend, .parakeet)
        XCTAssertTrue(resolution.deprecatedParakeetFlagPresent)
    }

    func testFixtureWinsOverMock() {
        let resolution = TranscriptionBackendSelection.resolve(
            arguments: [
                "Timbre",
                "--parakeet-fixture",
                "--mock-transcription",
            ],
            isDebug: true
        )
        XCTAssertEqual(resolution.backend, .parakeet)
        XCTAssertEqual(resolution.conflictWinner, .fixture)
    }

    func testMockWinsOverAppleSpeech() {
        let resolution = TranscriptionBackendSelection.resolve(
            arguments: [
                "Timbre",
                "--mock-transcription",
                "--apple-speech",
            ],
            isDebug: true
        )
        XCTAssertEqual(resolution.backend, .mock)
        XCTAssertEqual(resolution.conflictWinner, .mock)
    }

    func testFixtureWinsOverAppleSpeech() {
        let resolution = TranscriptionBackendSelection.resolve(
            arguments: [
                "Timbre",
                "--parakeet-fixture",
                "--apple-speech",
            ],
            isDebug: true
        )
        XCTAssertEqual(resolution.backend, .parakeet)
        XCTAssertEqual(resolution.conflictWinner, .fixture)
    }

    func testParakeetFixtureAloneSelectsFixturePath() {
        XCTAssertTrue(
            TranscriptionBackendSelection.wantsParakeetFixture(
                arguments: ["Timbre", "--parakeet-fixture"],
                isDebug: true
            )
        )
        // Fixture wins over mock, so the fixture path remains active.
        XCTAssertTrue(
            TranscriptionBackendSelection.wantsParakeetFixture(
                arguments: [
                    "Timbre",
                    "--parakeet-fixture",
                    "--mock-transcription",
                ],
                isDebug: true
            )
        )
        XCTAssertFalse(
            TranscriptionBackendSelection.wantsParakeetFixture(
                arguments: ["Timbre"],
                isDebug: true
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
