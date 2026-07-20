import Foundation
@testable import Timbre
import XCTest

@MainActor
final class ParakeetPrewarmCoordinatorTests: XCTestCase {
    func testConstructionAndIneligibleEvaluationDoNotLoad() {
        let model = FakeParakeetModelManager(initialState: .installed)
        let eligible = false
        let coordinator = ParakeetPrewarmCoordinator(
            modelManager: model,
            isEligible: { eligible },
            isParakeetProductionBackend: true
        )

        coordinator.evaluate(source: .launchReadiness)

        XCTAssertEqual(model.loadInstalledAndRetainCallCount, 0)
    }

    func testStartsOnEligibilityTransition() async {
        let model = FakeParakeetModelManager(initialState: .installed)
        var eligible = false
        let coordinator = ParakeetPrewarmCoordinator(
            modelManager: model,
            isEligible: { eligible },
            isParakeetProductionBackend: true
        )

        coordinator.evaluate(source: .launchReadiness)
        eligible = true
        coordinator.evaluate(source: .setupReadinessChanged)
        await waitUntil { model.state == .loaded }

        XCTAssertEqual(model.loadInstalledAndRetainCallCount, 1)
        XCTAssertEqual(model.retainLoadOperationCount, 1)
        XCTAssertEqual(model.state, .loaded)
    }

    func testDoesNotStartAgainWhileStillEligible() async {
        let model = FakeParakeetModelManager(initialState: .installed)
        let eligible = true
        let coordinator = ParakeetPrewarmCoordinator(
            modelManager: model,
            isEligible: { eligible },
            isParakeetProductionBackend: true
        )

        coordinator.evaluate(source: .launchReadiness)
        await waitUntil { model.state == .loaded }
        coordinator.evaluate(source: .setupReadinessChanged)

        XCTAssertEqual(model.loadInstalledAndRetainCallCount, 1)
    }

    func testDedupeWhenEligibilityFlapsDuringInFlightPrewarm() async {
        let model = FakeParakeetModelManager(initialState: .installed)
        model.suspendsRetainLoad = true
        var eligible = true
        let coordinator = ParakeetPrewarmCoordinator(
            modelManager: model,
            isEligible: { eligible },
            isParakeetProductionBackend: true
        )

        coordinator.evaluate(source: .launchReadiness)
        await model.waitForRetainLoadStart()
        eligible = false
        coordinator.evaluate(source: .setupReadinessChanged)
        eligible = true
        coordinator.evaluate(source: .setupReadinessChanged)

        XCTAssertEqual(model.loadInstalledAndRetainCallCount, 1)
        XCTAssertEqual(model.retainLoadOperationCount, 1)

        model.resumeRetainLoad()
        await waitUntil { model.state == .loaded }
    }

    func testEligibilityCanStartAgainAfterBecomingIneligible() async {
        let model = FakeParakeetModelManager(initialState: .installed)
        var eligible = true
        let coordinator = ParakeetPrewarmCoordinator(
            modelManager: model,
            isEligible: { eligible },
            isParakeetProductionBackend: true
        )

        coordinator.evaluate(source: .launchReadiness)
        await waitUntil { model.state == .loaded }
        await waitUntil { !coordinator.isAwaitingPrewarm }

        eligible = false
        coordinator.evaluate(source: .setupReadinessChanged)

        model.setState(.installed)
        eligible = true
        coordinator.evaluate(source: .setupReadinessChanged)
        await waitUntil { model.state == .loaded && model.loadInstalledAndRetainCallCount == 2 }

        XCTAssertEqual(model.loadInstalledAndRetainCallCount, 2)
        XCTAssertEqual(model.state, .loaded)
    }

    func testDisableFlagPreventsPrewarmInDebug() async {
        let model = FakeParakeetModelManager(initialState: .installed)
        let coordinator = ParakeetPrewarmCoordinator(
            modelManager: model,
            isEligible: { true },
            isParakeetProductionBackend: true,
            disablePrewarm: true
        )

        coordinator.evaluate(source: .launchReadiness)

#if DEBUG
        XCTAssertEqual(model.loadInstalledAndRetainCallCount, 0)
#else
        await waitUntil { model.state == .loaded }
        XCTAssertEqual(model.loadInstalledAndRetainCallCount, 1)
#endif
    }

    func testNonProductionBackendPreventsPrewarm() {
        let model = FakeParakeetModelManager(initialState: .installed)
        let coordinator = ParakeetPrewarmCoordinator(
            modelManager: model,
            isEligible: { true },
            isParakeetProductionBackend: false
        )

        coordinator.evaluate(source: .launchReadiness)

        XCTAssertEqual(model.loadInstalledAndRetainCallCount, 0)
    }

    func testCancelStopsCoordinatorAwaitButManagerCanComplete() async {
        let model = FakeParakeetModelManager(initialState: .installed)
        model.suspendsRetainLoad = true
        let coordinator = ParakeetPrewarmCoordinator(
            modelManager: model,
            isEligible: { true },
            isParakeetProductionBackend: true
        )

        coordinator.evaluate(source: .launchReadiness)
        await model.waitForRetainLoadStart()
        coordinator.cancel()
        model.resumeRetainLoad()
        await waitUntil { model.state == .loaded }

        XCTAssertEqual(model.retainLoadOperationCount, 1)
    }

    func testCancelDoesNotLeaveManagerStuckForLaterLoad() async throws {
        let model = FakeParakeetModelManager(initialState: .installed)
        let coordinator = ParakeetPrewarmCoordinator(
            modelManager: model,
            isEligible: { true },
            isParakeetProductionBackend: true
        )

        coordinator.evaluate(source: .launchReadiness)
        await waitUntil { model.state == .loaded }
        await waitUntil { !coordinator.isAwaitingPrewarm }
        coordinator.cancel()

        model.setState(.installed)
        try await model.loadInstalledAndRetain()

        XCTAssertEqual(model.state, .loaded)
        XCTAssertEqual(model.retainLoadOperationCount, 2)
    }

    func testTransientFailureLeavesInstalledAndAllowsRetry() async throws {
        let model = FakeParakeetModelManager(initialState: .installed)
        model.retainLoadBehavior = .transientFailure("compile glitch")
        let coordinator = ParakeetPrewarmCoordinator(
            modelManager: model,
            isEligible: { true },
            isParakeetProductionBackend: true
        )

        coordinator.evaluate(source: .launchReadiness)
        await waitUntil { !coordinator.isAwaitingPrewarm }

        XCTAssertEqual(model.state, .installed)
        XCTAssertEqual(model.loadInstalledAndRetainCallCount, 1)

        model.retainLoadBehavior = .success
        try await model.loadInstalledAndRetain()
        XCTAssertEqual(model.state, .loaded)
    }
}

@MainActor
private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
    while !condition() {
        await Task.yield()
    }
}
