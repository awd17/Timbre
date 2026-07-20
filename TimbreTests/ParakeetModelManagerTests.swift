import FluidAudio
import Foundation
@testable import Timbre
import XCTest

private enum ModelLoaderTestError: Error, LocalizedError {
    case loadFailed
    case downloadFailed
    case unusedTranscription

    var errorDescription: String? {
        switch self {
        case .loadFailed: return "load failed"
        case .downloadFailed: return "download failed"
        case .unusedTranscription: return "transcription is not used by model lifecycle tests"
        }
    }
}

private actor FakeParakeetASRManager: ParakeetASRManaging {
    var decoderLayerCount: Int { 2 }

    func transcribe(
        _ samples: [Float],
        decoderState: inout TdtDecoderState,
        language: Language?
    ) async throws -> ASRResult {
        _ = samples
        _ = decoderState
        _ = language
        throw ModelLoaderTestError.unusedTranscription
    }
}

@MainActor
private final class FakeParakeetModelLoader: ParakeetModelLoading {
    enum LoadOutcome {
        case success
        case failure(Error)
    }

    var cacheExistsValue: Bool
    var cacheIsValidValue = true
    var loadOutcomes: [LoadOutcome] = [.success]
    var downloadError: Error?
    var invalidateError: Error?
    var suspendsLoad = false
    var suspendsDownload = false

    private(set) var validationCallCount = 0
    private(set) var invalidationCallCount = 0
    private(set) var downloadCallCount = 0
    private(set) var loadCallCount = 0

    private var loadStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var downloadStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var loadGate: CheckedContinuation<Void, Never>?
    private var downloadGate: CheckedContinuation<Void, Never>?

    init(cacheExists: Bool) {
        cacheExistsValue = cacheExists
    }

    func cacheExists() -> Bool {
        cacheExistsValue
    }

    func cacheIsValid() async -> Bool {
        validationCallCount += 1
        return cacheIsValidValue
    }

    func invalidateCache() throws {
        invalidationCallCount += 1
        if let invalidateError {
            throw invalidateError
        }
        cacheExistsValue = false
    }

    func download(progressHandler: ProgressHandler?) async throws {
        _ = progressHandler
        downloadCallCount += 1
        let waiters = downloadStartWaiters
        downloadStartWaiters.removeAll()
        waiters.forEach { $0.resume() }

        if suspendsDownload {
            await withCheckedContinuation { continuation in
                downloadGate = continuation
            }
        }
        if let downloadError {
            throw downloadError
        }
        cacheExistsValue = true
    }

    func loadCached(
        progressHandler: ProgressHandler?
    ) async throws -> any ParakeetASRManaging {
        _ = progressHandler
        loadCallCount += 1
        let waiters = loadStartWaiters
        loadStartWaiters.removeAll()
        waiters.forEach { $0.resume() }

        if suspendsLoad {
            await withCheckedContinuation { continuation in
                loadGate = continuation
            }
        }

        let outcome = loadOutcomes.isEmpty ? .success : loadOutcomes.removeFirst()
        switch outcome {
        case .success:
            return FakeParakeetASRManager()
        case .failure(let error):
            throw error
        }
    }

    func waitForLoadStart() async {
        if loadCallCount > 0 { return }
        await withCheckedContinuation { continuation in
            loadStartWaiters.append(continuation)
        }
    }

    func waitForDownloadStart() async {
        if downloadCallCount > 0 { return }
        await withCheckedContinuation { continuation in
            downloadStartWaiters.append(continuation)
        }
    }

    func resumeLoad() {
        suspendsLoad = false
        loadGate?.resume()
        loadGate = nil
    }

    func resumeDownload() {
        suspendsDownload = false
        downloadGate?.resume()
        downloadGate = nil
    }
}

@MainActor
final class ParakeetModelManagerTests: XCTestCase {
    func testConcurrentPrewarmAndStartShareProductionLoadFlight() async throws {
        let loader = FakeParakeetModelLoader(cacheExists: true)
        loader.suspendsLoad = true
        let manager = ParakeetModelManager(loader: loader)

        async let prewarm: Void = manager.loadInstalledAndRetain()
        await loader.waitForLoadStart()
        XCTAssertEqual(manager.state, .installed)

        async let start: any ParakeetASRManaging = manager.ensureLoaded()
        await Task.yield()
        XCTAssertEqual(loader.loadCallCount, 1)

        loader.resumeLoad()
        try await prewarm
        _ = try await start

        XCTAssertEqual(loader.loadCallCount, 1)
        XCTAssertEqual(manager.state, .loaded)
    }

    func testCorruptCacheIsInvalidatedInsteadOfRemainingInstalled() async {
        let loader = FakeParakeetModelLoader(cacheExists: true)
        loader.cacheIsValidValue = false
        loader.loadOutcomes = [.failure(ModelLoaderTestError.loadFailed)]
        let manager = ParakeetModelManager(loader: loader)

        do {
            try await manager.loadInstalledAndRetain()
            XCTFail("Expected corrupt cache load to fail.")
        } catch {
            XCTAssertEqual(error as? ParakeetModelError, .modelNotInstalled)
        }

        XCTAssertEqual(loader.validationCallCount, 1)
        XCTAssertEqual(loader.invalidationCallCount, 1)
        XCTAssertFalse(loader.cacheExistsValue)
        XCTAssertEqual(manager.state, .notInstalled)
    }

    func testValidatedCacheFailureRemainsRetryableWithoutInvalidation() async {
        let loader = FakeParakeetModelLoader(cacheExists: true)
        loader.cacheIsValidValue = true
        loader.loadOutcomes = [.failure(ModelLoaderTestError.loadFailed)]
        let manager = ParakeetModelManager(loader: loader)

        do {
            try await manager.loadInstalledAndRetain()
            XCTFail("Expected transient cache load failure.")
        } catch {
            XCTAssertEqual(
                error as? ParakeetModelError,
                .transientLoadFailed("load failed")
            )
        }

        XCTAssertEqual(loader.validationCallCount, 1)
        XCTAssertEqual(loader.invalidationCallCount, 0)
        XCTAssertEqual(manager.state, .installed)
    }

    func testStartJoiningCorruptPrewarmRepairsWithOneDownload() async throws {
        let loader = FakeParakeetModelLoader(cacheExists: true)
        loader.cacheIsValidValue = false
        loader.suspendsLoad = true
        loader.loadOutcomes = [
            .failure(ModelLoaderTestError.loadFailed),
            .success,
        ]
        let manager = ParakeetModelManager(loader: loader)

        let prewarm = Task { @MainActor in
            try await manager.loadInstalledAndRetain()
        }
        await loader.waitForLoadStart()

        let start = Task { @MainActor in
            try await manager.ensureLoaded()
        }
        await Task.yield()
        loader.resumeLoad()

        do {
            try await prewarm.value
            XCTFail("Expected cached-only prewarm to report the invalid install.")
        } catch {
            XCTAssertEqual(error as? ParakeetModelError, .modelNotInstalled)
        }
        _ = try await start.value

        XCTAssertEqual(loader.invalidationCallCount, 1)
        XCTAssertEqual(loader.downloadCallCount, 1)
        XCTAssertEqual(loader.loadCallCount, 2)
        XCTAssertEqual(manager.state, .loaded)
    }

    func testConcurrentEnsureInstalledUsesProductionSingleFlight() async throws {
        let loader = FakeParakeetModelLoader(cacheExists: false)
        loader.suspendsDownload = true
        let manager = ParakeetModelManager(loader: loader)

        async let first: Void = manager.ensureInstalled()
        await loader.waitForDownloadStart()
        async let second: Void = manager.ensureInstalled()
        await Task.yield()

        XCTAssertEqual(loader.downloadCallCount, 1)
        loader.resumeDownload()
        try await first
        try await second

        XCTAssertEqual(loader.downloadCallCount, 1)
        XCTAssertEqual(loader.loadCallCount, 1)
        XCTAssertEqual(manager.state, .installed)
    }

    func testEnsureInstalledRepairsExistingCorruptCache() async throws {
        let loader = FakeParakeetModelLoader(cacheExists: true)
        loader.cacheIsValidValue = false
        loader.loadOutcomes = [
            .failure(ModelLoaderTestError.loadFailed),
            .success,
        ]
        let manager = ParakeetModelManager(loader: loader)

        // Force verification rather than the installed fast path.
        manager.unload()
        loader.cacheExistsValue = false
        manager.refreshAvailability()
        loader.cacheExistsValue = true

        try await manager.ensureInstalled()

        XCTAssertEqual(loader.invalidationCallCount, 1)
        XCTAssertEqual(loader.downloadCallCount, 1)
        XCTAssertEqual(loader.loadCallCount, 2)
        XCTAssertEqual(manager.state, .installed)
    }

    func testEnsureInstalledAcceptsCacheThatValidatesOnRetry() async throws {
        let loader = FakeParakeetModelLoader(cacheExists: true)
        loader.cacheIsValidValue = true
        loader.loadOutcomes = [.failure(ModelLoaderTestError.loadFailed)]
        let manager = ParakeetModelManager(loader: loader)

        // Move past the installed fast path so ensureInstalled verifies this cache.
        loader.cacheExistsValue = false
        manager.refreshAvailability()
        loader.cacheExistsValue = true

        try await manager.ensureInstalled()

        XCTAssertEqual(loader.validationCallCount, 1)
        XCTAssertEqual(loader.invalidationCallCount, 0)
        XCTAssertEqual(loader.downloadCallCount, 0)
        XCTAssertEqual(manager.state, .installed)
    }
}
