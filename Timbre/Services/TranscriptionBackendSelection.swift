import Foundation

enum TranscriptionBackend: Equatable {
    case appleSpeech
    case mock
    case parakeet

    var logName: String {
        switch self {
        case .appleSpeech: return "appleSpeech"
        case .mock: return "mock"
        case .parakeet: return "parakeet"
        }
    }
}

struct TranscriptionBackendResolution: Equatable {
    let backend: TranscriptionBackend
    /// Set when both mock and parakeet flags were present (mock wins).
    let conflictingFlagsIgnoredParakeet: Bool
}

enum TranscriptionBackendSelection {
    static let mockArgument = "--mock-transcription"
    static let parakeetArgument = "--parakeet-transcription"
    static let parakeetFixtureArgument = "--parakeet-fixture"

    /// Resolves the transcription backend from process arguments.
    /// Pure: no logging. Callers log `conflictingFlagsIgnoredParakeet` if needed.
    static func resolve(arguments: [String], isDebug: Bool) -> TranscriptionBackendResolution {
        guard isDebug else {
            return TranscriptionBackendResolution(
                backend: .appleSpeech,
                conflictingFlagsIgnoredParakeet: false
            )
        }

        let wantsMock = arguments.contains(mockArgument)
        let wantsParakeet = arguments.contains(parakeetArgument)

        if wantsMock {
            return TranscriptionBackendResolution(
                backend: .mock,
                conflictingFlagsIgnoredParakeet: wantsParakeet
            )
        }

        if wantsParakeet {
            return TranscriptionBackendResolution(
                backend: .parakeet,
                conflictingFlagsIgnoredParakeet: false
            )
        }

        return TranscriptionBackendResolution(
            backend: .appleSpeech,
            conflictingFlagsIgnoredParakeet: false
        )
    }

    static func wantsParakeetFixture(arguments: [String], isDebug: Bool) -> Bool {
        guard isDebug else { return false }
        return arguments.contains(parakeetFixtureArgument)
            && resolve(arguments: arguments, isDebug: isDebug).backend == .parakeet
    }
}
