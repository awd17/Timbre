import Foundation

/// Per-recording identity so late callbacks from a cancelled session cannot affect a newer one.
@MainActor
final class TranscriptionSession {
    let id = UUID()

    private(set) var isInvalidated = false
    private(set) var latestTranscript = ""
    private var onPartialResult: (@MainActor (String) -> Void)?
    private var continuation: CheckedContinuation<String, Error>?

    init(onPartialResult: @escaping @MainActor (String) -> Void) {
        self.onPartialResult = onPartialResult
    }

    func deliverPartial(_ text: String) {
        guard !isInvalidated else { return }
        latestTranscript = text
        onPartialResult?(text)
    }

    func beginStopping(_ continuation: CheckedContinuation<String, Error>) {
        self.continuation = continuation
    }

    func complete(_ result: Result<String, Error>) {
        guard !isInvalidated, let continuation else { return }
        self.continuation = nil
        switch result {
        case .success(let text):
            continuation.resume(returning: text)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    func invalidate(resumeWithCancellation: Bool = true) {
        guard !isInvalidated else { return }
        isInvalidated = true
        onPartialResult = nil
        if resumeWithCancellation, let continuation {
            self.continuation = nil
            continuation.resume(throwing: CancellationError())
        }
    }
}
