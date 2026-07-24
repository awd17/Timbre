import Foundation
import KeyboardShortcuts
@testable import Timbre
import XCTest

final class IntegrationTestConfigurationTests: XCTestCase {
    func testNotRequestedReturnsNil() {
        XCTAssertNil(
            IntegrationTestConfiguration.resolve(
                arguments: ["/path/to/Timbre"],
                environment: [:]
            )
        )
    }

    func testConfigurationParsesAndSanitizesEnvironment() throws {
        let configuration = try XCTUnwrap(
            IntegrationTestConfiguration.resolve(
                arguments: ["/path/to/Timbre", "--integration-test"],
                environment: [
                    IntegrationTestConfiguration.profileEnvironment: "profile/one",
                    IntegrationTestConfiguration.scenarioEnvironment: "secureInput",
                    IntegrationTestConfiguration.resetEnvironment: "1",
                    IntegrationTestConfiguration.menuHostEnvironment: "1",
                    IntegrationTestConfiguration.probeEnvironment: "/tmp/timbre-probe.json",
                ]
            )
        )

        XCTAssertEqual(configuration.profile, "profileone")
        XCTAssertEqual(configuration.scenario, .secureInput)
        XCTAssertTrue(configuration.shouldReset)
        XCTAssertTrue(configuration.showsMenuHost)
        XCTAssertEqual(configuration.probeURL.path, "/tmp/timbre-probe.json")
    }

    func testUnknownScenarioFallsBackToNormal() throws {
        let configuration = try XCTUnwrap(
            IntegrationTestConfiguration.resolve(
                arguments: ["--integration-test"],
                environment: [
                    IntegrationTestConfiguration.scenarioEnvironment: "unknown",
                ]
            )
        )
        XCTAssertEqual(configuration.scenario, .normal)
    }

    func testEveryScriptedScenarioParses() throws {
        for scenario in IntegrationTestScenario.allCases {
            let configuration = try XCTUnwrap(
                IntegrationTestConfiguration.resolve(
                    arguments: ["--integration-test"],
                    environment: [
                        IntegrationTestConfiguration.scenarioEnvironment: scenario.rawValue,
                    ]
                )
            )
            XCTAssertEqual(configuration.scenario, scenario)
        }
    }
}

@MainActor
final class IntegrationTestProbeTests: XCTestCase {
    func testProbePersistsCountsAcrossGenerations() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TimbreProbeTests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let first = IntegrationTestProbe(url: url, reset: true)
        first.recordInstallAttempt()
        first.recordSessionStarted()
        first.recordShortcutBurstArmed()
        first.recordShortcutBurstInvocation()
        first.recordPasteAttempt(text: "hello", succeeded: true)
        first.recordDeliveryResult(.pasteEventPosted)

        let second = IntegrationTestProbe(url: url, reset: false)
        XCTAssertEqual(second.snapshot.generation, 2)
        XCTAssertEqual(second.snapshot.installAttempts, 1)
        XCTAssertEqual(second.snapshot.sessionStarts, 1)
        XCTAssertEqual(second.snapshot.shortcutBurstsArmed, 1)
        XCTAssertEqual(second.snapshot.shortcutBurstInvocations, 1)
        XCTAssertEqual(second.snapshot.successfulPastes, 1)
        XCTAssertEqual(second.snapshot.lastPasteText, "hello")
        XCTAssertEqual(second.snapshot.lastDeliveryResult, "pasteEventPosted")
    }

    func testProbeRecordsEveryDeliveryBoundaryAndFailedPostText() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TimbreProbeBoundaryTests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let probe = IntegrationTestProbe(url: url, reset: true)
        let results: [(TranscriptDeliveryResult, String)] = [
            (.copiedAfterInsertFailure(.missingTarget), "copiedAfterInsertFailure.missingTarget"),
            (.copiedAfterInsertFailure(.targetTerminated), "copiedAfterInsertFailure.targetTerminated"),
            (.copiedAfterInsertFailure(.frontmostChanged), "copiedAfterInsertFailure.frontmostChanged"),
            (.copiedAfterInsertFailure(.accessibilityUntrusted), "copiedAfterInsertFailure.accessibilityUntrusted"),
            (.copiedAfterInsertFailure(.secureInputField), "copiedAfterInsertFailure.secureInputField"),
            (.copiedAfterInsertFailure(.pasteboardChanged), "copiedAfterInsertFailure.pasteboardChanged"),
            (.copiedAfterInsertFailure(.eventPostFailed), "copiedAfterInsertFailure.eventPostFailed"),
        ]

        for (result, expected) in results {
            probe.recordDeliveryResult(result)
            XCTAssertEqual(probe.snapshot.lastDeliveryResult, expected)
        }

        probe.recordPasteAttempt(text: "retained transcript", succeeded: false)
        XCTAssertEqual(probe.snapshot.pasteAttempts, 1)
        XCTAssertEqual(probe.snapshot.successfulPastes, 0)
        XCTAssertEqual(probe.snapshot.lastPasteText, "retained transcript")
    }

    func testCleanupScenarioRemovesOnlyItsProfileShortcutAndProbe() throws {
        let profile = "cleanup-\(UUID().uuidString)"
        let suiteName = "com.augustdrakton.Timbre.integration.\(profile)"
        let probeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TimbreCleanupTests-\(UUID().uuidString).json")
        let configuration = IntegrationTestConfiguration(
            profile: profile,
            scenario: .cleanup,
            shouldReset: true,
            showsMenuHost: false,
            probeURL: probeURL
        )
        let runtime = IntegrationTestRuntime(configuration: configuration)
        runtime.defaults.set("integration-only", forKey: "cleanup-marker")
        KeyboardShortcuts.setShortcut(
            KeyboardShortcuts.Shortcut(.k, modifiers: [.control, .shift]),
            for: .integrationTestToggleDictation
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: probeURL.path))
        runtime.cleanupPersistentStateIfRequested()

        XCTAssertNil(UserDefaults(suiteName: suiteName)?.object(forKey: "cleanup-marker"))
        XCTAssertFalse(
            KeyboardShortcutsOnboardingAdapter(
                name: .integrationTestToggleDictation
            ).hasAssignedShortcut
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: probeURL.path))
    }
}

@MainActor
final class PersistentIntegrationModelManagerTests: XCTestCase {
    func testInstalledStatePersistsAcrossManagerRelaunchWithoutAnotherAttempt() async throws {
        let suiteName = "TimbrePersistentModelTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let probeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(suiteName).json")
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: probeURL)
        }

        let probe = IntegrationTestProbe(url: probeURL, reset: true)
        let first = PersistentIntegrationModelManager(
            defaults: defaults,
            scenario: .normal,
            probe: probe,
            installationStepDelay: .zero
        )
        try await first.ensureInstalled()
        XCTAssertEqual(first.state, .installed)
        XCTAssertEqual(probe.snapshot.installAttempts, 1)

        let relaunched = PersistentIntegrationModelManager(
            defaults: defaults,
            scenario: .normal,
            probe: probe,
            installationStepDelay: .zero
        )
        try await relaunched.ensureInstalled()
        XCTAssertEqual(relaunched.state, .installed)
        XCTAssertEqual(probe.snapshot.installAttempts, 1)
    }

    func testForegroundFailureIsConsumedAndRetrySucceeds() async throws {
        let suiteName = "TimbrePersistentModelRetryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let probeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(suiteName).json")
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: probeURL)
        }

        let probe = IntegrationTestProbe(url: probeURL, reset: true)
        let model = PersistentIntegrationModelManager(
            defaults: defaults,
            scenario: .foregroundOnboarding,
            probe: probe,
            installationStepDelay: .zero
        )

        do {
            try await model.ensureInstalled()
            XCTFail("The first foreground attempt should fail")
        } catch {
            XCTAssertEqual(model.state, .failed(message: "Something went wrong while getting Timbre ready."))
        }
        try await model.ensureInstalled()
        XCTAssertEqual(model.state, .installed)
        XCTAssertEqual(probe.snapshot.installAttempts, 2)
    }
}

@MainActor
final class IntegrationShortcutInjectionTests: XCTestCase {
    override func setUp() {
        super.setUp()
        KeyboardShortcuts.reset(.integrationTestToggleDictation)
    }

    override func tearDown() {
        KeyboardShortcuts.reset(.integrationTestToggleDictation)
        super.tearDown()
    }

    func testOnboardingAndGlobalServiceUseInjectedShortcutName() {
        KeyboardShortcuts.setShortcut(
            KeyboardShortcuts.Shortcut(.k, modifiers: [.control, .shift]),
            for: .integrationTestToggleDictation
        )

        let onboarding = KeyboardShortcutsOnboardingAdapter(
            name: .integrationTestToggleDictation
        )
        let global = KeyboardShortcutsGlobalShortcutService(
            name: .integrationTestToggleDictation
        )

        XCTAssertTrue(onboarding.hasAssignedShortcut)
        XCTAssertEqual(onboarding.displayString, "⌃⇧K")
        XCTAssertEqual(global.displayString, "⌃⇧K")
    }

    func testSettingsClearRestoresPreviousShortcutWhenEditingEnds() {
        let previous = KeyboardShortcuts.Shortcut(.k, modifiers: [.control, .shift])
        KeyboardShortcuts.setShortcut(previous, for: .integrationTestToggleDictation)
        let adapter = KeyboardShortcutsOnboardingAdapter(
            name: .integrationTestToggleDictation
        )
        adapter.beginSettingsShortcutEditing()

        KeyboardShortcuts.setShortcut(nil, for: .integrationTestToggleDictation)
        adapter.applySettingsRecorderChange(nil)
        XCTAssertTrue(adapter.hasAssignedShortcut)
        XCTAssertEqual(adapter.displayString, "⌃⇧K")

        adapter.refreshFromStorage()
        XCTAssertTrue(adapter.hasAssignedShortcut)
        XCTAssertEqual(adapter.displayString, "⌃⇧K")

        adapter.finishSettingsShortcutEditing()

        XCTAssertEqual(
            KeyboardShortcuts.getShortcut(for: .integrationTestToggleDictation),
            previous
        )
        XCTAssertTrue(adapter.hasAssignedShortcut)
        XCTAssertEqual(adapter.displayString, "⌃⇧K")
    }

    func testSettingsReplacementBecomesNextRollbackShortcut() {
        KeyboardShortcuts.setShortcut(
            KeyboardShortcuts.Shortcut(.k, modifiers: [.control, .shift]),
            for: .integrationTestToggleDictation
        )
        let adapter = KeyboardShortcutsOnboardingAdapter(
            name: .integrationTestToggleDictation
        )
        adapter.beginSettingsShortcutEditing()
        let replacement = KeyboardShortcuts.Shortcut(.j, modifiers: [.command, .shift])
        KeyboardShortcuts.setShortcut(replacement, for: .integrationTestToggleDictation)
        adapter.applySettingsRecorderChange(replacement)

        KeyboardShortcuts.setShortcut(nil, for: .integrationTestToggleDictation)
        adapter.applySettingsRecorderChange(nil)
        adapter.finishSettingsShortcutEditing()

        XCTAssertEqual(
            KeyboardShortcuts.getShortcut(for: .integrationTestToggleDictation),
            replacement
        )
        XCTAssertEqual(adapter.displayString, "⇧⌘J")
    }

    func testSettingsUsesRecommendedShortcutWhenNoRollbackExists() {
        KeyboardShortcuts.setShortcut(nil, for: .integrationTestToggleDictation)
        let adapter = KeyboardShortcutsOnboardingAdapter(
            name: .integrationTestToggleDictation
        )
        adapter.beginSettingsShortcutEditing()
        adapter.finishSettingsShortcutEditing()

        XCTAssertEqual(
            KeyboardShortcuts.getShortcut(for: .integrationTestToggleDictation),
            DictationShortcutName.recommendedShortcut
        )
    }

    func testIntegrationBurstInvokesTheRegisteredHandlerWithoutHIDPosting() {
        let service = KeyboardShortcutsGlobalShortcutService(
            name: .integrationTestToggleDictation
        )
        var handlerInvocations = 0
        var burstInvocations = 0
        service.setHandler {
            handlerInvocations += 1
        }
        service.armIntegrationTestBurst(extraInvocations: 3) {
            burstInvocations += 1
        }

        service.invokeKeyUpForUnitTesting()

        XCTAssertEqual(handlerInvocations, 4)
        XCTAssertEqual(burstInvocations, 3)
    }
}
