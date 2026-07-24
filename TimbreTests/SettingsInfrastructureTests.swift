import AppKit
import Combine
import Foundation
@testable import Timbre
import XCTest

@MainActor
final class AppPreferencesTests: XCTestCase {
    func testDefaultsAreFalseAndPersist() throws {
        let suiteName = "TimbrePreferencesTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = UserDefaultsAppPreferences(defaults: defaults)
        XCTAssertFalse(preferences.keepTranscriptOnClipboardAfterInsertion)
        XCTAssertFalse(preferences.showInDock)

        preferences.keepTranscriptOnClipboardAfterInsertion = true
        preferences.showInDock = true

        let reloaded = UserDefaultsAppPreferences(defaults: defaults)
        XCTAssertTrue(reloaded.keepTranscriptOnClipboardAfterInsertion)
        XCTAssertTrue(reloaded.showInDock)
    }

    func testDistinctChangesPublishOnce() {
        let preferences = InMemoryAppPreferences()
        var changes: [AppPreferenceChange] = []
        let observation = preferences.changes.sink { changes.append($0) }

        preferences.showInDock = true
        preferences.showInDock = true
        preferences.keepTranscriptOnClipboardAfterInsertion = true

        XCTAssertEqual(changes, [
            .showInDock(true),
            .keepTranscriptOnClipboardAfterInsertion(true),
        ])
        withExtendedLifetime(observation) {}
    }

    func testNormalPreferencesUseKeysSeparateFromOnboarding() {
        let keys = Set([
            UserDefaultsAppPreferences.keepTranscriptOnClipboardAfterInsertionKey,
            UserDefaultsAppPreferences.showInDockKey,
        ])
        XCTAssertFalse(keys.contains(UserDefaultsOnboardingPreferences.completedWelcomeKey))
        XCTAssertFalse(keys.contains(UserDefaultsOnboardingPreferences.dismissedReadyKey))
        XCTAssertFalse(
            keys.contains(UserDefaultsOnboardingPreferences.completedShortcutOnboardingKey)
        )
    }
}

@MainActor
private final class FakeDockVisibilityService: DockVisibilityServicing {
    var results: [Bool] = []
    private(set) var policies: [NSApplication.ActivationPolicy] = []
    private(set) var activationCount = 0

    func apply(_ policy: NSApplication.ActivationPolicy) -> Bool {
        policies.append(policy)
        return results.isEmpty ? true : results.removeFirst()
    }

    func activate() {
        activationCount += 1
    }
}

@MainActor
final class DockVisibilityCoordinatorTests: XCTestCase {
    func testStoredPoliciesAndDistinctChanges() {
        let preferences = InMemoryAppPreferences()
        let service = FakeDockVisibilityService()
        let coordinator = DockVisibilityCoordinator(
            preferences: preferences,
            service: service
        )

        coordinator.applyLaunchPolicy()
        preferences.showInDock = true
        preferences.showInDock = true
        preferences.showInDock = false

        XCTAssertEqual(service.policies, [.accessory, .regular, .accessory])
    }

    func testTemporaryReasonsOverlapWithoutChangingPreference() {
        let preferences = InMemoryAppPreferences()
        let service = FakeDockVisibilityService()
        let coordinator = DockVisibilityCoordinator(
            preferences: preferences,
            service: service
        )
        coordinator.applyLaunchPolicy()

        coordinator.beginTemporaryPresentation(.onboarding)
        coordinator.beginTemporaryPresentation(.settingsWindow)
        coordinator.endTemporaryPresentation(.onboarding)
        coordinator.endTemporaryPresentation(.settingsWindow)

        XCTAssertFalse(preferences.showInDock)
        XCTAssertEqual(service.policies, [.accessory, .regular, .accessory])
    }

    func testTurningDockOffWaitsForSettingsToClose() {
        let preferences = InMemoryAppPreferences(showInDock: true)
        let service = FakeDockVisibilityService()
        let coordinator = DockVisibilityCoordinator(
            preferences: preferences,
            service: service
        )
        coordinator.applyLaunchPolicy()
        coordinator.beginTemporaryPresentation(.settingsWindow)

        preferences.showInDock = false
        XCTAssertEqual(service.policies, [.regular])

        coordinator.endTemporaryPresentation(.settingsWindow)
        XCTAssertEqual(service.policies, [.regular, .accessory])
    }

    func testFailedPolicyIsRetried() {
        let preferences = InMemoryAppPreferences()
        let service = FakeDockVisibilityService()
        service.results = [false, true]
        let coordinator = DockVisibilityCoordinator(
            preferences: preferences,
            service: service
        )

        coordinator.applyLaunchPolicy()
        coordinator.applyLaunchPolicy()

        XCTAssertEqual(service.policies, [.accessory, .accessory])
    }

    func testSettingsOpeningActivatesBeforeInvokingSceneAction() {
        let preferences = InMemoryAppPreferences()
        let service = FakeDockVisibilityService()
        let dockCoordinator = DockVisibilityCoordinator(
            preferences: preferences,
            service: service
        )
        dockCoordinator.applyLaunchPolicy()
        let settingsCoordinator = SettingsOpeningCoordinator(
            dockVisibilityCoordinator: dockCoordinator
        )
        var activationCountWhenOpened: Int?
        settingsCoordinator.install {
            activationCountWhenOpened = service.activationCount
        }

        settingsCoordinator.open()

        XCTAssertEqual(service.policies, [.accessory, .regular])
        XCTAssertEqual(service.activationCount, 1)
        XCTAssertEqual(activationCountWhenOpened, 1)
    }
}

final class BundleInformationTests: XCTestCase {
    func testVersionFormatting() {
        XCTAssertEqual(
            BundleInformation(marketingVersion: "1.0", buildNumber: "42")
                .versionDescription,
            "Version 1.0 (42)"
        )
        XCTAssertEqual(
            BundleInformation(marketingVersion: "1.0", buildNumber: nil)
                .versionDescription,
            "Version 1.0"
        )
        XCTAssertEqual(
            BundleInformation(marketingVersion: nil, buildNumber: "42")
                .versionDescription,
            "Build 42"
        )
        XCTAssertEqual(
            BundleInformation(marketingVersion: nil, buildNumber: nil)
                .versionDescription,
            "Version unavailable"
        )
    }
}

@MainActor
final class TranscriptPasteboardServiceTests: XCTestCase {
    func testConsumedTranscriptRestoresAllPreviousRepresentations() async {
        let pasteboard = NSPasteboard.withUniqueName()
        let first = NSPasteboardItem()
        first.setString("prior", forType: .string)
        first.setData(Data([1, 2, 3]), forType: .init("com.timbre.test-data"))
        let second = NSPasteboardItem()
        second.setString("second", forType: .string)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([first, second]))

        let service = TranscriptPasteboardService(pasteboard: pasteboard)
        let capture = service.captureCompleteSnapshot()
        guard case .snapshot(let snapshot) = capture else {
            return XCTFail("Expected a complete snapshot")
        }
        var outcomes: [ClipboardRetentionOutcome] = []
        let write = service.writeTranscript(
            "transcript",
            restorationSnapshot: snapshot,
            retainedOutcome: .transcriptIntentionallyRetained,
            onOutcome: { outcomes.append($0) }
        )
        XCTAssertNotNil(write)

        XCTAssertEqual(pasteboard.string(forType: .string), "transcript")
        await waitUntil { outcomes == [.previousClipboardRestored] }

        guard let restored = pasteboard.pasteboardItems else {
            return XCTFail("Expected restored items")
        }
        XCTAssertEqual(restored.count, 2)
        XCTAssertEqual(restored.first?.string(forType: .string), "prior")
        XCTAssertEqual(
            restored.first?.data(forType: .init("com.timbre.test-data")),
            Data([1, 2, 3])
        )
        XCTAssertEqual(restored.last?.string(forType: .string), "second")
    }

    func testNewerClipboardChangeIsNotOverwritten() async {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString("prior", forType: .string)
        let service = TranscriptPasteboardService(pasteboard: pasteboard)
        guard case .snapshot(let snapshot) = service.captureCompleteSnapshot() else {
            return XCTFail("Expected snapshot")
        }
        var outcomes: [ClipboardRetentionOutcome] = []
        let write = service.writeTranscript(
            "transcript",
            restorationSnapshot: snapshot,
            retainedOutcome: .transcriptIntentionallyRetained,
            onOutcome: { outcomes.append($0) }
        )
        XCTAssertNotNil(write)

        pasteboard.clearContents()
        pasteboard.setString("newer", forType: .string)
        await waitUntil { !outcomes.isEmpty }

        XCTAssertEqual(pasteboard.string(forType: .string), "newer")
        XCTAssertEqual(outcomes, [.restorationSkipped(.clipboardChanged)])
    }

    func testEmptySnapshotRestoresEmptyClipboard() async {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        let service = TranscriptPasteboardService(pasteboard: pasteboard)
        guard case .snapshot(let snapshot) = service.captureCompleteSnapshot() else {
            return XCTFail("Expected snapshot")
        }
        var outcome: ClipboardRetentionOutcome?
        _ = service.writeTranscript(
            "transcript",
            restorationSnapshot: snapshot,
            retainedOutcome: .transcriptIntentionallyRetained,
            onOutcome: { outcome = $0 }
        )

        XCTAssertEqual(pasteboard.string(forType: .string), "transcript")
        await waitUntil { outcome == .previousClipboardRestored }
        XCTAssertTrue(pasteboard.pasteboardItems?.isEmpty ?? true)
    }
}
