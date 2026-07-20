import FluidAudio
import Foundation

/// Narrow ASR surface used after model preparation. Keeping this boundary protocol-based
/// lets model lifecycle tests use a lightweight actor instead of constructing Core ML models.
protocol ParakeetASRManaging: Actor {
    var decoderLayerCount: Int { get }

    func transcribe(
        _ samples: [Float],
        decoderState: inout TdtDecoderState,
        language: Language?
    ) async throws -> ASRResult
}

extension AsrManager: ParakeetASRManaging {}

/// FluidAudio boundary owned by `ParakeetModelManager`.
///
/// The manager owns lifecycle and single-flight policy; this boundary owns only cache I/O
/// and construction of the retained ASR actor.
@MainActor
protocol ParakeetModelLoading: AnyObject {
    func cacheExists() -> Bool
    func loadValidatedCache() async -> (any ParakeetASRManaging)?
    func invalidateCache() throws

    func download(progressHandler: ProgressHandler?) async throws
    func loadCached(progressHandler: ProgressHandler?) async throws -> any ParakeetASRManaging
}

@MainActor
final class FluidAudioParakeetModelLoader: ParakeetModelLoading {
    private let version: AsrModelVersion

    init(version: AsrModelVersion = .v2) {
        self.version = version
    }

    private var cacheDirectory: URL {
        AsrModels.defaultCacheDirectory(for: version)
    }

    func cacheExists() -> Bool {
        AsrModels.modelsExist(at: cacheDirectory, version: version)
    }

    func loadValidatedCache() async -> (any ParakeetASRManaging)? {
        do {
            // `modelsExist` only checks paths, and FluidAudio's lightweight model
            // validation does not parse the vocabulary. A full load is the only
            // authoritative check that every cached artifact is usable. Return the
            // resulting manager so retained-load recovery does not compile it again.
            return try await loadCached(progressHandler: nil)
        } catch {
            TimbreLog.line(
                "Timbre model: cache validation failed — \(error.localizedDescription)"
            )
            return nil
        }
    }

    func invalidateCache() throws {
        guard FileManager.default.fileExists(atPath: cacheDirectory.path) else { return }
        try FileManager.default.removeItem(at: cacheDirectory)
    }

    func download(progressHandler: ProgressHandler?) async throws {
        try requireAppleSilicon()
        _ = try await AsrModels.download(
            version: version,
            progressHandler: progressHandler
        )
    }

    func loadCached(
        progressHandler: ProgressHandler?
    ) async throws -> any ParakeetASRManaging {
        try requireAppleSilicon()
        let models = try await AsrModels.load(
            from: cacheDirectory,
            version: version,
            progressHandler: progressHandler
        )
        return AsrManager(config: .default, models: models)
    }

    private func requireAppleSilicon() throws {
#if !arch(arm64)
        throw TranscriptionError.recognitionFailed("Parakeet models require Apple Silicon.")
#endif
    }
}
