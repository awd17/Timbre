import Foundation

/// User-facing preparation progress derived from FluidAudio callbacks (no fake percentages).
struct ModelPreparationProgress: Equatable {
    /// Overall fraction in `0...1` when known; `nil` means indeterminate.
    var fraction: Double?
    /// Short status under the primary “Getting Timbre ready…” title.
    var detail: String?
    /// Estimated remaining time when fraction is trustworthy enough to extrapolate.
    var estimatedSecondsRemaining: TimeInterval?

    static let idle = ModelPreparationProgress(fraction: nil, detail: nil, estimatedSecondsRemaining: nil)

    var estimatedTimeRemainingText: String? {
        guard let seconds = estimatedSecondsRemaining, seconds.isFinite, seconds > 0 else {
            return nil
        }
        if seconds < 60 {
            return "Less than a minute remaining"
        }
        let minutes = Int((seconds / 60.0).rounded(.up))
        if minutes == 1 {
            return "About 1 minute remaining"
        }
        return "About \(minutes) minutes remaining"
    }

    var percentText: String? {
        guard let fraction else { return nil }
        let percent = Int((fraction * 100).rounded(.down).clamped(to: 0...99))
        return "\(percent)%"
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

/// Lifecycle of the Parakeet v2 model on disk vs in memory.
/// Installed means files are present and verified; loaded means an `AsrManager` is retained.
enum ModelPreparationState: Equatable {
    case checking
    case notInstalled
    case downloading
    case installed
    case loading
    case loaded
    case failed(message: String)

    var needsInstall: Bool {
        switch self {
        case .notInstalled, .failed:
            return true
        case .checking, .downloading, .installed, .loading, .loaded:
            return false
        }
    }

    var isInstalling: Bool {
        switch self {
        case .downloading, .loading:
            return true
        case .checking, .notInstalled, .installed, .loaded, .failed:
            return false
        }
    }

    /// On-disk and verified (or already loaded). Does not include in-flight download/load.
    var isInstalled: Bool {
        switch self {
        case .installed, .loaded:
            return true
        case .checking, .notInstalled, .downloading, .loading, .failed:
            return false
        }
    }

    var isLoaded: Bool {
        if case .loaded = self { return true }
        return false
    }

    /// Dictation may start only when the required component is ready on disk (or loaded).
    var allowsDictation: Bool {
        isInstalled
    }
}
