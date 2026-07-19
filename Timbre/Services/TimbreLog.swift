import Foundation

enum TimbreLog {
    /// Unbuffered diagnostics (GUI apps often buffer stdout).
    static func line(_ message: String) {
        fputs(message + "\n", stderr)
        fflush(stderr)
    }
}
