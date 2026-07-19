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

/// Which DEBUG flag won when more than one backend-related flag was present.
enum TranscriptionBackendConflictWinner: Equatable {
    case fixture
    case mock
    case appleSpeech

    var logName: String {
        switch self {
        case .fixture: return "fixture"
        case .mock: return "mock"
        case .appleSpeech: return "appleSpeech"
        }
    }
}

struct TranscriptionBackendResolution: Equatable {
    let backend: TranscriptionBackend
    /// True when `--parakeet-transcription` was present (deprecated; Parakeet is already default).
    let deprecatedParakeetFlagPresent: Bool
    /// Set when multiple DEBUG backend flags were present; names the winner.
    let conflictWinner: TranscriptionBackendConflictWinner?
}

enum TranscriptionBackendSelection {
    static let mockArgument = "--mock-transcription"
    /// Deprecated no-op. Parakeet is the default; presence is logged only.
    static let parakeetArgument = "--parakeet-transcription"
    static let parakeetFixtureArgument = "--parakeet-fixture"
    static let appleSpeechArgument = "--apple-speech"

    /// Resolves the transcription backend from process arguments.
    /// Pure: no logging. Callers log deprecation / conflicts if needed.
    ///
    /// DEBUG priority: fixture → mock → apple-speech → Parakeet default.
    /// Release always selects Parakeet and ignores developer flags.
    static func resolve(arguments: [String], isDebug: Bool) -> TranscriptionBackendResolution {
        let deprecatedParakeetFlagPresent = arguments.contains(parakeetArgument)

        guard isDebug else {
            return TranscriptionBackendResolution(
                backend: .parakeet,
                deprecatedParakeetFlagPresent: deprecatedParakeetFlagPresent,
                conflictWinner: nil
            )
        }

        let wantsFixture = arguments.contains(parakeetFixtureArgument)
        let wantsMock = arguments.contains(mockArgument)
        let wantsAppleSpeech = arguments.contains(appleSpeechArgument)
        let flagCount = [wantsFixture, wantsMock, wantsAppleSpeech].filter(\.self).count

        if wantsFixture {
            return TranscriptionBackendResolution(
                backend: .parakeet,
                deprecatedParakeetFlagPresent: deprecatedParakeetFlagPresent,
                conflictWinner: flagCount > 1 ? .fixture : nil
            )
        }

        if wantsMock {
            return TranscriptionBackendResolution(
                backend: .mock,
                deprecatedParakeetFlagPresent: deprecatedParakeetFlagPresent,
                conflictWinner: flagCount > 1 ? .mock : nil
            )
        }

        if wantsAppleSpeech {
            return TranscriptionBackendResolution(
                backend: .appleSpeech,
                deprecatedParakeetFlagPresent: deprecatedParakeetFlagPresent,
                conflictWinner: nil
            )
        }

        return TranscriptionBackendResolution(
            backend: .parakeet,
            deprecatedParakeetFlagPresent: deprecatedParakeetFlagPresent,
            conflictWinner: nil
        )
    }

    static func wantsParakeetFixture(arguments: [String], isDebug: Bool) -> Bool {
        guard isDebug else { return false }
        return arguments.contains(parakeetFixtureArgument)
            && resolve(arguments: arguments, isDebug: isDebug).backend == .parakeet
    }
}
