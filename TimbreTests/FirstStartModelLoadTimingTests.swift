import Foundation
@testable import Timbre
import XCTest

/// Focused timing diagnostics for the first-ever in-memory Parakeet model load.
///
/// These tests drive the REAL `ParakeetModelManager` + `FluidAudioParakeetModelLoader`
/// against the on-disk model cache at
/// `~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v2`.
///
/// - They never delete or modify the cache; they only load it into memory.
/// - They never touch Microphone / Accessibility permissions.
/// - They are skipped when the real cache is not installed.
///
/// These diagnostics measure the expensive "installed but not loaded" state
/// directly. Production now absorbs that work during onboarding or launch
/// prewarming and does not register the dictation hotkey until the retained
/// manager is ready.
@MainActor
final class FirstStartModelLoadTimingTests: XCTestCase {
    private var modelManager: ParakeetModelManager!

    override func setUp() async throws {
        modelManager = ParakeetModelManager()
        guard modelManager.state.isInstalled || modelManager.state.isLoaded else {
            throw XCTSkip(
                "Real Parakeet model cache is not installed; these timing tests require the on-disk model."
            )
        }
    }

    override func tearDown() async throws {
        modelManager.unload()
        modelManager = nil
    }

    /// Measures how long the first in-memory load takes after an install-only
    /// state (`installed`, no retained manager) — exactly the state the app is in
    /// when the user finishes first-run setup and starts dictating for the first
    /// time before (or without) background prewarming.
    func testFirstInMemoryLoadLatency() async throws {
        modelManager.unload()
        XCTAssertTrue(modelManager.state.isInstalled, "Expected installed-but-not-loaded state.")

        let startedAt = Date()
        _ = try await modelManager.ensureLoaded()
        let seconds = Date().timeIntervalSince(startedAt)

        print(String(format: "Timbre timing: first in-memory model load = %.2fs", seconds))
        XCTAssertEqual(modelManager.state, .loaded)
        XCTAssertLessThan(seconds, 90, "First in-memory load took \(seconds)s.")
    }

    /// Measures how responsive the main actor is DURING the first-ever in-memory
    /// load in a fresh process. A large heartbeat gap means the model load
    /// occupies the main actor, which is what would make Escape and the stop
    /// shortcut unresponsive on the very first dictation after setup.
    func testMainActorResponsiveDuringFirstEverLoad() async throws {
        modelManager.unload()
        XCTAssertTrue(modelManager.state.isInstalled)

        let loadTask = Task { @MainActor in
            let startedAt = Date()
            let manager = try await modelManager.ensureLoaded()
            return (manager, Date().timeIntervalSince(startedAt))
        }

        try await Task.sleep(nanoseconds: 100_000_000)

        var ticks: [UInt64] = []
        for _ in 0..<50 {
            ticks.append(DispatchTime.now().uptimeNanoseconds)
            try await Task.sleep(nanoseconds: 200_000_000)
        }

        let (_, loadSeconds) = try await loadTask.value

        var maxGapMilliseconds = 0.0
        for index in 1..<ticks.count {
            let gap = Double(ticks[index] &- ticks[index - 1]) / 1_000_000
            maxGapMilliseconds = max(maxGapMilliseconds, gap)
        }

        print(
            String(
                format: "Timbre timing: first-ever load=%.2fs max main-actor heartbeat gap=%.1fms",
                loadSeconds,
                maxGapMilliseconds
            )
        )
        XCTAssertLessThan(
            maxGapMilliseconds,
            5_000,
            "Main actor was blocked for \(maxGapMilliseconds)ms during the first-ever model load; escape/stop would stall."
        )
    }

    /// The prewarm path (`loadInstalledAndRetain`) uses an installed-only flight;
    /// this is what `ParakeetPrewarmCoordinator` runs after setup readiness.
    func testPrewarmRetainLoadLatency() async throws {
        modelManager.unload()
        XCTAssertTrue(modelManager.state.isInstalled)

        let startedAt = Date()
        try await modelManager.loadInstalledAndRetain()
        let seconds = Date().timeIntervalSince(startedAt)

        print(String(format: "Timbre timing: prewarm retain load = %.2fs", seconds))
        XCTAssertEqual(modelManager.state, .loaded)
        XCTAssertLessThan(seconds, 30, "Prewarm retain load took \(seconds)s.")
    }

    /// Subsequent starts must reuse the retained manager instead of reloading.
    func testWarmReuseLatency() async throws {
        _ = try await modelManager.ensureLoaded()

        let startedAt = Date()
        _ = try await modelManager.ensureLoaded()
        let seconds = Date().timeIntervalSince(startedAt)

        print(String(format: "Timbre timing: warm reused load = %.3fs", seconds))
        XCTAssertLessThan(seconds, 1, "Warm reuse took \(seconds)s.")
    }

    /// While the cold load runs, a main-actor heartbeat must keep ticking. A large
    /// gap means the model load is occupying the main actor, which is what makes
    /// Escape and the stop shortcut unresponsive during the first start.
    func testMainActorStaysResponsiveDuringColdLoad() async throws {
        modelManager.unload()
        XCTAssertTrue(modelManager.state.isInstalled)

        let loadTask = Task { @MainActor in
            let startedAt = Date()
            let manager = try await modelManager.ensureLoaded()
            return (manager, Date().timeIntervalSince(startedAt))
        }

        // Let the load actually begin before sampling the heartbeat.
        try await Task.sleep(nanoseconds: 200_000_000)

        var ticks: [UInt64] = []
        for _ in 0..<30 {
            ticks.append(DispatchTime.now().uptimeNanoseconds)
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        let (_, loadSeconds) = try await loadTask.value

        var maxGapMilliseconds = 0.0
        for index in 1..<ticks.count {
            let gap = Double(ticks[index] &- ticks[index - 1]) / 1_000_000
            maxGapMilliseconds = max(maxGapMilliseconds, gap)
        }

        print(
            String(
                format: "Timbre timing: load=%.2fs max main-actor heartbeat gap=%.1fms",
                loadSeconds,
                maxGapMilliseconds
            )
        )
        XCTAssertLessThan(
            maxGapMilliseconds,
            2_000,
            "Main actor was blocked for \(maxGapMilliseconds)ms during model load; escape/stop would stall."
        )
    }

    /// The onboarding install step must load the model into memory (hidden in
    /// the "Preparing" step) so the first dictation after Ready reuses it. This
    /// is what `SetupCoordinator.perform(.installModel)` does now; it absorbs
    /// the cold Core ML/ANE compile so `ensureLoaded()` on the first dictation
    /// is warm. Requires a cold compile cache; run in a fresh process.
    func testOnboardingInstallsAndLoadsModelSoFirstDictationIsWarm() async throws {
        modelManager.refreshAvailability()
        XCTAssertTrue(modelManager.state.isInstalled)

        let installStart = Date()
        try await modelManager.ensureInstalled()
        let installSeconds = Date().timeIntervalSince(installStart)
        print(String(format: "Timbre timing: setup ensureInstalled = %.2fs", installSeconds))

        let loadStart = Date()
        try await modelManager.loadInstalledAndRetain()
        let loadSeconds = Date().timeIntervalSince(loadStart)
        print(
            String(
                format: "Timbre timing: setup retained load (hidden in Preparing) = %.2fs",
                loadSeconds
            )
        )
        XCTAssertEqual(modelManager.state, .loaded)

        let dictationStart = Date()
        _ = try await modelManager.ensureLoaded()
        let dictationSeconds = Date().timeIntervalSince(dictationStart)
        print(
            String(
                format: "Timbre timing: first dictation load after onboarding = %.2fs",
                dictationSeconds
            )
        )
        XCTAssertLessThan(
            dictationSeconds,
            1,
            "First dictation after onboarding still paid a cold compile (\(dictationSeconds)s)."
        )
    }

    /// Full first-available-start path through `AssistantController` with the real
    /// model and committed fixture (no microphone, no permissions). The app does
    /// not register the production hotkey until this retained prewarm is complete,
    /// so Start must only pay the warm reuse cost.
    func testFirstStartThroughAssistantController() async throws {
        modelManager.unload()
        let fixtureURL = try XCTUnwrap(ParakeetTranscriptionService.defaultFixtureURL())
        let transcription = ParakeetTranscriptionService(
            fixtureURL: fixtureURL,
            modelManager: modelManager
        )
        let clipboard = FakeClipboard()
        let delivery = FakeTranscriptDelivery(clipboard: clipboard)
        let targetProvider = FakeDictationTargetProvider()
        let controller = AssistantController(
            transcription: transcription,
            clipboard: clipboard,
            delivery: delivery,
            targetProvider: targetProvider
        )

        try await modelManager.loadInstalledAndRetain()

        var states: [SessionState] = []
        let listeningExpectation = expectation(description: "listening reached")
        let completionExpectation = expectation(description: "stop completed")
        controller.setSessionStateHandler { state in
            states.append(state)
            switch state {
            case .listening:
                listeningExpectation.fulfill()
            case .completed:
                completionExpectation.fulfill()
            default:
                break
            }
        }

        let startRequested = Date()
        controller.beginDictation()
        await fulfillment(of: [listeningExpectation], timeout: 60)
        let startToListening = Date().timeIntervalSince(startRequested)
        print(String(format: "Timbre timing: start-to-listening = %.2fs", startToListening))
        XCTAssertLessThan(startToListening, 1)

        let stopRequested = Date()
        await controller.stopDictation()
        await fulfillment(of: [completionExpectation], timeout: 60)
        let stopToCompletion = Date().timeIntervalSince(stopRequested)
        print(String(format: "Timbre timing: stop-to-completion = %.2fs", stopToCompletion))

        XCTAssertEqual(delivery.deliveredTranscripts.count, 1, "Text should have been delivered.")
        XCTAssertFalse(
            delivery.deliveredTranscripts[0].isEmpty,
            "Delivered transcript should not be empty."
        )
    }

    /// Cancellation remains immediate once the prewarmed first session is active.
    func testCancelAfterPrewarmedFirstStartEndsSessionPromptly() async throws {
        modelManager.unload()
        let fixtureURL = try XCTUnwrap(ParakeetTranscriptionService.defaultFixtureURL())
        let transcription = ParakeetTranscriptionService(
            fixtureURL: fixtureURL,
            modelManager: modelManager
        )
        let controller = AssistantController(
            transcription: transcription,
            clipboard: FakeClipboard(),
            delivery: FakeTranscriptDelivery(),
            targetProvider: FakeDictationTargetProvider()
        )

        try await modelManager.loadInstalledAndRetain()

        controller.beginDictation()
        XCTAssertEqual(controller.sessionState, .preparing)

        // Give the session time to reach Listening before cancelling.
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(modelManager.state, .loaded)

        let cancelledAt = Date()
        _ = controller.cancelDictation()
        let cancelSeconds = Date().timeIntervalSince(cancelledAt)

        print(
            String(
                format: "Timbre timing: cancel during cold load = %.3fs (state=%@)",
                cancelSeconds,
                "\(controller.sessionState)"
            )
        )
        XCTAssertLessThan(cancelSeconds, 1, "Cancel was not prompt during the cold load.")
        XCTAssertEqual(controller.sessionState, .idle, "Escape should end the session immediately.")
    }
}
