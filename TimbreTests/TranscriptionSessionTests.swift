import Foundation
@testable import Timbre
import XCTest

@MainActor
final class TranscriptionSessionTests: XCTestCase {
    func testInvalidatedSessionIgnoresPartials() {
        var partials: [String] = []
        let session = TranscriptionSession { text in
            partials.append(text)
        }

        session.deliverPartial("hello")
        XCTAssertEqual(partials, ["hello"])
        XCTAssertEqual(session.latestTranscript, "hello")

        session.invalidate(resumeWithCancellation: false)
        session.deliverPartial("world")
        XCTAssertEqual(partials, ["hello"])
        XCTAssertEqual(session.latestTranscript, "hello")
    }

    func testInvalidateCancelsPendingStop() async {
        let session = TranscriptionSession { _ in }

        let task = Task {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                session.beginStopping(continuation)
            }
        }

        await Task.yield()
        session.invalidate(resumeWithCancellation: true)

        do {
            _ = try await task.value
            XCTFail("Invalidated session should resume with CancellationError")
        } catch is CancellationError {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCompleteIsIdempotent() async throws {
        let session = TranscriptionSession { _ in }
        let value: String = try await withCheckedThrowingContinuation { continuation in
            session.beginStopping(continuation)
            session.complete(.success("once"))
            session.complete(.success("twice"))
        }
        XCTAssertEqual(value, "once")
    }

    func testFreshSessionStillCompletesAfterPriorInvalidation() async throws {
        let stale = TranscriptionSession { _ in }
        stale.invalidate(resumeWithCancellation: false)

        let fresh = TranscriptionSession { _ in }
        let value: String = try await withCheckedThrowingContinuation { continuation in
            fresh.beginStopping(continuation)
            // Stale completion must not affect the new session.
            stale.complete(.success("stale"))
            fresh.complete(.success("fresh session"))
        }
        XCTAssertEqual(value, "fresh session")
    }
}
