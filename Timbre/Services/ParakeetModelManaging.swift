import Foundation

/// Shared Parakeet model lifecycle: install/verify on disk, optionally load into memory.
/// Views must not depend on FluidAudio types; only services call loading APIs on the concrete manager.
@MainActor
protocol ParakeetModelManaging: AnyObject {
    var state: ModelPreparationState { get }
    var progress: ModelPreparationProgress { get }

    /// Probe the on-disk cache. Sets `notInstalled` or `installed` without loading into memory.
    /// Does not change state while a download or load is already in flight.
    func refreshAvailability()

    /// Single-flight download + verify-load + release. Ends in `installed` (not `loaded`).
    func ensureInstalled() async throws

    /// Drop any retained in-memory manager. Leaves state as `installed` when files remain.
    func unload()
}
