import FluidAudio
import Foundation
@testable import Timbre
import XCTest

private actor StartupTestASRManager: ParakeetASRManaging {
    var decoderLayerCount: Int { 2 }

    func transcribe(
        _ samples: [Float],
        decoderState: inout TdtDecoderState,
        language: Language?
    ) async throws -> ASRResult {
        _ = samples
        _ = decoderState
        _ = language
        throw TranscriptionError.emptyResult
    }
}

@MainActor
private final class StartupTestModelLoader: ParakeetModelLoading {
    private(set) var loadCallCount = 0

    func cacheExists() -> Bool { true }
    func loadValidatedCache() async -> (any ParakeetASRManaging)? { StartupTestASRManager() }
    func invalidateCache() throws {}
    func download(progressHandler: ProgressHandler?) async throws { _ = progressHandler }

    func loadCached(
        progressHandler: ProgressHandler?
    ) async throws -> any ParakeetASRManaging {
        _ = progressHandler
        loadCallCount += 1
        return StartupTestASRManager()
    }
}

@MainActor
private final class StartupTestAudioSource: ParakeetAudioSource {
    let diagnosticLabel = "startup-test"
    private(set) var prepareCallCount = 0
    private(set) var beginCallCount = 0
    private(set) var teardownCallCount = 0

    func prepareAccess() async throws {
        prepareCallCount += 1
    }

    func begin(onAudioLevel: @escaping @MainActor (Float) -> Void) throws {
        _ = onAudioLevel
        beginCallCount += 1
    }

    func finish() throws -> [Float] { [] }

    func teardown() {
        teardownCallCount += 1
    }
}

@MainActor
final class ParakeetTranscriptionStartupTests: XCTestCase {
    func testStartReusesPrewarmedModelWithoutAdditionalLoad() async throws {
        let loader = StartupTestModelLoader()
        let modelManager = ParakeetModelManager(loader: loader)
        let audioSource = StartupTestAudioSource()
        let transcription = ParakeetTranscriptionService(
            audioSource: audioSource,
            modelManager: modelManager
        )

        try await modelManager.loadInstalledAndRetain()
        XCTAssertEqual(loader.loadCallCount, 1)

        try await transcription.prepare()
        try await transcription.start(onPartialResult: { _ in }, onAudioLevel: { _ in })

        XCTAssertEqual(audioSource.prepareCallCount, 1)
        XCTAssertEqual(audioSource.beginCallCount, 1)
        XCTAssertEqual(loader.loadCallCount, 1)
        XCTAssertEqual(modelManager.state, .loaded)

        await transcription.cancel()
    }
}
