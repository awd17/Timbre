import Foundation

/// Configurable fake transcription used for DEBUG launches and unit tests.
@MainActor
final class MockTranscriptionService: TranscriptionServicing {
    enum Behavior: Equatable {
        case success(final: String, partials: [String])
        case emptyResult
        case prepareFailure(TranscriptionError)
        case startFailure(TranscriptionError)
        case stopFailure(TranscriptionError)
    }

    var behavior: Behavior
    var partialDelayNanoseconds: UInt64

    private var session: TranscriptionSession?
    private var partialTask: Task<Void, Never>?

    init(
        behavior: Behavior = .success(
            final: "Hello world",
            partials: ["Hello", "Hello world"]
        ),
        partialDelayNanoseconds: UInt64 = 40_000_000
    ) {
        self.behavior = behavior
        self.partialDelayNanoseconds = partialDelayNanoseconds
    }

    func prepare() async throws {
        if case .prepareFailure(let error) = behavior {
            throw error
        }
    }

    func start(onPartialResult: @escaping @MainActor (String) -> Void) async throws {
        if session != nil {
            throw TranscriptionError.alreadyRunning
        }

        if case .startFailure(let error) = behavior {
            throw error
        }

        let newSession = TranscriptionSession(onPartialResult: onPartialResult)
        let sessionID = newSession.id
        session = newSession

        let partials: [String]
        switch behavior {
        case .success(_, let configuredPartials):
            partials = configuredPartials
        case .emptyResult, .prepareFailure, .startFailure, .stopFailure:
            partials = []
        }

        let delay = partialDelayNanoseconds
        partialTask = Task { [weak self] in
            for partial in partials {
                guard !Task.isCancelled else { return }
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self,
                          let active = self.session,
                          active.id == sessionID,
                          !active.isInvalidated
                    else { return }
                    active.deliverPartial(partial)
                }
            }
        }
    }

    func stop() async throws -> String {
        guard let active = session, !active.isInvalidated else {
            throw TranscriptionError.notRunning
        }

        partialTask?.cancel()
        partialTask = nil
        active.invalidate(resumeWithCancellation: false)
        session = nil

        switch behavior {
        case .success(let final, _):
            let trimmed = final.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                throw TranscriptionError.emptyResult
            }
            return final
        case .emptyResult:
            throw TranscriptionError.emptyResult
        case .stopFailure(let error):
            throw error
        case .prepareFailure, .startFailure:
            throw TranscriptionError.notRunning
        }
    }

    func cancel() async {
        partialTask?.cancel()
        partialTask = nil
        session?.invalidate(resumeWithCancellation: true)
        session = nil
    }
}
