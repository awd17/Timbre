import Foundation

#if DEBUG
/// DEBUG-only simulated onboarding launch configuration.
enum SimulatedOnboarding {
    static let argument = "--simulate-onboarding"
    static let failureArgument = "--simulate-onboarding-failure"
    static let durationArgument = "--simulate-onboarding-duration"
    static let stepArgument = "--simulate-onboarding-step"
    static let useRealRecorderArgument = "--simulate-onboarding-real-recorder"

    struct Configuration: Equatable {
        var failOnce: Bool
        var durationSeconds: TimeInterval
        var initialStep: String?
        var useRealRecorder: Bool
    }

    static func isRequested(arguments: [String]) -> Bool {
        arguments.contains(argument)
    }

    /// True when simulate mode should run (and is not rejected by incompatible flags).
    static func isEnabled(arguments: [String]) -> Bool {
        guard isRequested(arguments: arguments) else { return false }
        if let conflict = incompatibleReason(arguments: arguments) {
            TimbreLog.line("Timbre onboarding: SIMULATED mode rejected (\(conflict))")
            return false
        }
        return true
    }

    static func incompatibleReason(arguments: [String]) -> String? {
        if arguments.contains(TimbreSetupFeature.disableArgument) {
            return "incompatible with \(TimbreSetupFeature.disableArgument)"
        }
        if arguments.contains(TranscriptionBackendSelection.parakeetFixtureArgument) {
            return "incompatible with \(TranscriptionBackendSelection.parakeetFixtureArgument)"
        }
        if arguments.contains(TranscriptionBackendSelection.appleSpeechArgument) {
            return "incompatible with \(TranscriptionBackendSelection.appleSpeechArgument)"
        }
        return nil
    }

    static func configuration(arguments: [String]) -> Configuration {
        var duration: TimeInterval = 6
        if let index = arguments.firstIndex(of: durationArgument),
           arguments.indices.contains(index + 1),
           let value = TimeInterval(arguments[index + 1]),
           value > 0
        {
            duration = value
        }

        var initialStep: String?
        if let index = arguments.firstIndex(of: stepArgument),
           arguments.indices.contains(index + 1)
        {
            initialStep = arguments[index + 1]
        }

        return Configuration(
            failOnce: arguments.contains(failureArgument),
            durationSeconds: duration,
            initialStep: initialStep,
            useRealRecorder: arguments.contains(useRealRecorderArgument)
        )
    }
}
#endif
