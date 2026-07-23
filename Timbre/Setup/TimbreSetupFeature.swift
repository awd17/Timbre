import Foundation

/// Gates automatic first-run Parakeet setup.
///
/// Release: always enabled (developer bypass flags are ignored).
/// DEBUG: on by default; off for mock, fixture, Apple Speech, or `--disable-setup`.
/// `--simulate-onboarding` forces setup on unless incompatible flags are present.
enum TimbreSetupFeature {
    static let disableArgument = "--disable-setup"

    /// Whether automatic setup UI and menu chrome are active for this launch.
    static func isEnabled(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
#if DEBUG
        return isEnabled(arguments: arguments, isDebug: true)
#else
        return isEnabled(arguments: arguments, isDebug: false)
#endif
    }

    /// Pure resolver for unit tests. Release (`isDebug: false`) ignores bypass flags.
    static func isEnabled(arguments: [String], isDebug: Bool) -> Bool {
        guard isDebug else {
            return true
        }

#if DEBUG
        if SimulatedOnboarding.isRequested(arguments: arguments) {
            return SimulatedOnboarding.isEnabled(arguments: arguments)
        }
#endif

        if arguments.contains(TranscriptionBackendSelection.mockArgument) {
            return false
        }
        if arguments.contains(TranscriptionBackendSelection.parakeetFixtureArgument) {
            return false
        }
        if arguments.contains(TranscriptionBackendSelection.appleSpeechArgument) {
            return false
        }
        if arguments.contains(disableArgument) {
            return false
        }
        return true
    }
}
