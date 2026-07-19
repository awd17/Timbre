import Foundation

/// Gates automatic first-run setup. Release always off; DEBUG on unless mock/fixture args force it off.
/// The next PR removes this gate when Parakeet becomes the production default.
enum TimbreSetupFeature {
    static let disableArgument = "--disable-setup"

    /// Whether automatic setup UI and menu chrome are active for this launch.
    static func isEnabled(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
#if DEBUG
        if arguments.contains(TranscriptionBackendSelection.mockArgument) {
            return false
        }
        if arguments.contains(TranscriptionBackendSelection.parakeetFixtureArgument) {
            return false
        }
        if arguments.contains(disableArgument) {
            return false
        }
        return true
#else
        return false
#endif
    }
}
