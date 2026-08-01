import AppKit
import XCTest

final class TimbreUITests: XCTestCase {
    private static let transcript = "Integration dictation"

    private var app: XCUIApplication?
    private var textEdit: XCUIApplication?
    private var temporaryDirectory: URL!
    private var foregroundProbeURL: URL!
    private var backgroundProbeURL: URL!
    private var foregroundProfile: String!
    private var backgroundProfile: String!
    private var isRecordingFailureArtifacts = false

    override func setUpWithError() throws {
        continueAfterFailure = false
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TimbreFullIntegration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        foregroundProbeURL = temporaryDirectory.appendingPathComponent("foreground.json")
        backgroundProbeURL = temporaryDirectory.appendingPathComponent("background.json")
        foregroundProfile = "foreground-\(UUID().uuidString)"
        backgroundProfile = "background-\(UUID().uuidString)"
    }

    override func tearDownWithError() throws {
        app?.terminate()
        textEdit?.terminate()
        for profile in [foregroundProfile, backgroundProfile].compactMap({ $0 }) {
            let domain = "com.augustdrakton.Timbre.integration.\(profile)"
            UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain)
        }
        let appDefaults = UserDefaults(suiteName: "com.augustdrakton.Timbre")
        appDefaults?.removeObject(forKey: "KeyboardShortcuts_integrationTestToggleDictation")
        appDefaults?.synchronize()
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    override func record(_ issue: XCTIssue) {
        if !isRecordingFailureArtifacts {
            isRecordingFailureArtifacts = true
            if let app, app.state != .notRunning {
                let screenshot = XCTAttachment(screenshot: app.screenshot())
                screenshot.name = "Timbre failure"
                screenshot.lifetime = .keepAlways
                add(screenshot)
            }
            for (name, url) in [
                ("Foreground probe", foregroundProbeURL),
                ("Background probe", backgroundProbeURL),
            ] {
                if let url, let data = try? Data(contentsOf: url) {
                    let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                    attachment.name = name
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
            }
            isRecordingFailureArtifacts = false
        }
        super.record(issue)
    }

    @MainActor
    func testFullApplicationLifecycle() throws {
        try runForegroundOnboarding()
        try runBackgroundOnboarding()
        try runNormalDictationAndBusyStates()
        try runSettingsSurface()
        try runSecondLaunchWithoutHostOrRebuild()
        try runDeliverySafetyScenarios()
        try runSetupRecoveryScenarios()
        try runQuit()
    }

    @MainActor
    func testHotkeyLatency() throws {
        let app = launch(
            profile: backgroundProfile,
            scenario: "performance",
            probeURL: backgroundProbeURL,
            reset: true,
            menuHost: true
        )
        XCTAssertFalse(
            app.descendants(matching: .any)["setupFlowRoot"].waitForExistence(timeout: 1),
            hierarchy(app, "Performance profile should launch ready")
        )

        let textEdit = launchTextEdit()
        textEdit.activate()
        let initial = try waitForProbe(backgroundProbeURL, timeout: 3) {
            $0.sessionStarts == 0 && $0.modelState == "loaded"
        }

        pressGlobalHotkey(in: textEdit)
        let listening = try waitForProbe(backgroundProbeURL, timeout: 3) {
            $0.sessionStarts == initial.sessionStarts + 1
                && $0.lastStartToPreparingMilliseconds != nil
                && $0.lastStartToListeningMilliseconds != nil
        }
        let startToPreparing = try XCTUnwrap(listening.lastStartToPreparingMilliseconds)
        let startToListening = try XCTUnwrap(listening.lastStartToListeningMilliseconds)

        pressGlobalHotkey(in: textEdit)
        let completed = try waitForProbe(backgroundProbeURL, timeout: 3) {
            $0.sessionStops == initial.sessionStops + 1
                && $0.lastStopToCompletionMilliseconds != nil
        }
        let stopToCompletion = try XCTUnwrap(completed.lastStopToCompletionMilliseconds)

        print(
            String(
                format: "Timbre e2e latency: start-to-preparing=%.1fms start-to-listening=%.1fms stop-to-completion=%.1fms",
                startToPreparing,
                startToListening,
                stopToCompletion
            )
        )
        XCTAssertLessThan(startToPreparing, 1_000)
        XCTAssertLessThan(startToListening, 1_000)
        XCTAssertLessThan(stopToCompletion, 1_000)
    }

    // MARK: - Major phases

    @MainActor
    private func runForegroundOnboarding() throws {
        let app = launch(
            profile: foregroundProfile,
            scenario: "foregroundOnboarding",
            probeURL: foregroundProbeURL,
            reset: true,
            menuHost: true
        )
        try completeWelcomeAndRecordShortcut(in: app)

        XCTAssertTrue(
            app.staticTexts["Microphone Access"].waitForExistence(timeout: 3),
            hierarchy(app, "Expected the microphone step")
        )
        let microphoneSettings = app.buttons["setupOpenMicSettingsButton"]
        XCTAssertTrue(
            microphoneSettings.waitForExistence(timeout: 5),
            hierarchy(app, "Expected microphone denial recovery")
        )
        microphoneSettings.click()
        app.buttons["setupMicRetryButton"].click()

        let textInsertionContinue = app.buttons["setupTextInsertionContinueButton"]
        XCTAssertTrue(
            textInsertionContinue.waitForExistence(timeout: 5),
            hierarchy(app, "Expected Text Insertion step")
        )
        textInsertionContinue.click()

        // Text-insertion denial now leads with Try Again; a recheck confirms the
        // permission is still missing, after which the System Settings action
        // is surfaced.
        app.buttons["setupAccessibilityRetryButton"].click()
        let accessibilitySettings = app.buttons["setupOpenAccessibilitySettingsButton"]
        XCTAssertTrue(
            accessibilitySettings.waitForExistence(timeout: 5),
            hierarchy(app, "Expected Accessibility denial recovery")
        )
        accessibilitySettings.click()
        // Granting Accessibility lets the in-window permission monitor move on
        // automatically (or via a subsequent recheck).

        XCTAssertTrue(
            app.descendants(matching: .any)["setupProgress"].waitForExistence(timeout: 5),
            hierarchy(app, "Expected model preparation")
        )
        app.typeKey("k", modifierFlags: [.control, .shift])
        let beforeFailure = try waitForProbe(foregroundProbeURL, timeout: 3) {
            $0.installAttempts == 1
        }
        XCTAssertEqual(beforeFailure.sessionStarts, 0, "Hotkey must be ignored during setup")

        let retry = app.buttons["setupRetryButton"]
        XCTAssertTrue(
            retry.waitForExistence(timeout: 5),
            hierarchy(app, "Expected first integration install to fail")
        )
        retry.click()

        let done = app.buttons["setupDoneButton"]
        XCTAssertTrue(
            done.waitForExistence(timeout: 7),
            hierarchy(app, "Expected Ready after retry")
        )
        XCTAssertEqual(
            app.descendants(matching: .any)["setupReadyShortcutHint"].label,
            "Press ⌃⇧K to start dictating anywhere."
        )
        done.click()

        let completed = try waitForProbe(foregroundProbeURL, timeout: 3) {
            $0.installAttempts == 2 && ($0.modelState == "installed" || $0.modelState == "loaded")
        }
        XCTAssertEqual(completed.installAttempts, 2)
        XCTAssertTrue(
            app.windows["Timbre Integration Menu"].waitForExistence(timeout: 3),
            hierarchy(app, "Expected the production menu view host")
        )
        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
    }

    @MainActor
    private func runBackgroundOnboarding() throws {
        let app = launch(
            profile: backgroundProfile,
            scenario: "backgroundOnboarding",
            probeURL: backgroundProbeURL,
            reset: true,
            menuHost: true
        )
        try completeWelcomeAndRecordShortcut(in: app)

        XCTAssertTrue(
            app.staticTexts["Microphone Access"].waitForExistence(timeout: 3),
            hierarchy(app, "Expected microphone permission progress")
        )
        let textInsertionContinue = app.buttons["setupTextInsertionContinueButton"]
        XCTAssertTrue(
            textInsertionContinue.waitForExistence(timeout: 5),
            hierarchy(app, "Expected Text Insertion step")
        )
        textInsertionContinue.click()

        let background = app.buttons["setupContinueInBackgroundButton"]
        XCTAssertTrue(
            background.waitForExistence(timeout: 5),
            hierarchy(app, "Expected background preparation control")
        )
        background.click()
        XCTAssertFalse(
            app.descendants(matching: .any)["setupFlowRoot"].waitForExistence(timeout: 1),
            "Setup window should close while preparation continues"
        )

        let menuWindow = app.windows["Timbre Integration Menu"]
        XCTAssertTrue(menuWindow.waitForExistence(timeout: 3), hierarchy(app, "Missing menu host"))
        XCTAssertTrue(
            menuWindow.buttons["setupMenuItem"].waitForExistence(timeout: 3),
            hierarchy(app, "Menu should expose setup recovery")
        )
        _ = try realStatusItem(in: app)

        let firstAttempt = try waitForProbe(backgroundProbeURL, timeout: 3) {
            $0.installAttempts == 1 && $0.modelState == "downloading"
        }
        XCTAssertEqual(firstAttempt.installAttempts, 1)

        let reopen = menuWindow.buttons["setupMenuItem"]
        XCTAssertTrue(reopen.waitForExistence(timeout: 3), hierarchy(app, "Missing setup reopen"))
        reopen.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["setupProgress"].waitForExistence(timeout: 3),
            hierarchy(app, "Reopened setup should retain live progress")
        )
        XCTAssertEqual(try readProbe(backgroundProbeURL).installAttempts, 1)
        app.buttons["setupContinueInBackgroundButton"].click()

        XCTAssertTrue(
            menuWindow.buttons["settingsMenuItem"].waitForExistence(timeout: 7),
            hierarchy(app, "Menu did not become ready after background preparation")
        )
        let ready = try waitForProbe(backgroundProbeURL, timeout: 3) {
            $0.installAttempts == 1 && ($0.modelState == "installed" || $0.modelState == "loaded")
        }
        XCTAssertEqual(ready.installAttempts, 1)
    }

    @MainActor
    private func runNormalDictationAndBusyStates() throws {
        guard let app else { return XCTFail("Background app was not launched") }
        let textEdit = launchTextEdit()
        let initial = try readProbe(backgroundProbeURL)
        let initialCopy = app.windows["Timbre Integration Menu"]
            .buttons["copyLastDictationMenuItem"]
        XCTAssertTrue(initialCopy.waitForExistence(timeout: 3))
        XCTAssertFalse(initialCopy.isEnabled)

        textEdit.activate()
        let armedStart = try armShortcutBurst(after: initial)
        pressGlobalHotkey(in: textEdit)
        let listening = try waitForProbe(backgroundProbeURL, timeout: 5) {
            $0.sessionStarts == initial.sessionStarts + 1
                && $0.shortcutBurstInvocations
                    == armedStart.shortcutBurstInvocations + 3
        }
        XCTAssertEqual(listening.sessionStarts, initial.sessionStarts + 1)
        XCTAssertEqual(listening.sessionStops, initial.sessionStops)

        let armedStop = try armShortcutBurst(after: listening)
        pressGlobalHotkey(in: textEdit)
        let inserted = try waitForProbe(backgroundProbeURL, timeout: 5) {
            $0.successfulPastes == initial.successfulPastes + 1
                && $0.shortcutBurstInvocations
                    == armedStop.shortcutBurstInvocations + 3
        }
        XCTAssertEqual(inserted.sessionStarts, initial.sessionStarts + 1)
        XCTAssertEqual(inserted.sessionStops, initial.sessionStops + 1)
        XCTAssertEqual(inserted.lastPasteText, Self.transcript)
        XCTAssertEqual(inserted.lastDeliveryResult, "pasteEventPosted")

        let menuWindow = app.windows["Timbre Integration Menu"]

        let pasteAttemptsBeforeCopy = inserted.pasteAttempts
        let copy = menuWindow.buttons["copyLastDictationMenuItem"]
        XCTAssertTrue(copy.waitForExistence(timeout: 3))
        XCTAssertTrue(copy.isEnabled)
        copy.click()
        XCTAssertEqual(try readProbe(backgroundProbeURL).pasteAttempts, pasteAttemptsBeforeCopy)

        XCTAssertFalse(menuWindow.buttons["startButton"].exists)
        XCTAssertFalse(menuWindow.buttons["stopButton"].exists)
        XCTAssertFalse(menuWindow.descendants(matching: .any)["transcriptText"].exists)
        XCTAssertFalse(menuWindow.descendants(matching: .any)["statusMessage"].exists)
    }

    @MainActor
    private func runSettingsSurface() throws {
        guard let app else { return XCTFail("Background app was not launched") }
        let menuWindow = app.windows["Timbre Integration Menu"]
        let settings = menuWindow.buttons["settingsMenuItem"]
        XCTAssertTrue(settings.waitForExistence(timeout: 3))
        settings.click()

        for identifier in [
            "settingsMicrophoneInput",
            "settingsPlaybackBehavior",
            "settingsResetOverlayPosition",
            "settingsResetAll",
            "settingsQuit",
            "settingsVersion",
        ] {
            XCTAssertTrue(
                app.descendants(matching: .any)[identifier].waitForExistence(timeout: 3),
                hierarchy(app, "Settings is missing \(identifier)")
            )
        }

        app.buttons["settingsResetOverlayPosition"].click()
        app.buttons["settingsResetAll"].click()
        XCTAssertTrue(
            app.staticTexts["Reset All Settings?"].waitForExistence(timeout: 3),
            hierarchy(app, "Reset All Settings should require confirmation")
        )
        app.windows["com_apple_SwiftUI_Settings_window"]
            .sheets.firstMatch
            .buttons["Cancel"]
            .click()
        app.typeKey("w", modifierFlags: .command)
    }

    @MainActor
    private func runSecondLaunchWithoutHostOrRebuild() throws {
        app?.terminate()
        XCTAssertTrue(app?.wait(for: .notRunning, timeout: 5) == true)

        let app = launch(
            profile: backgroundProfile,
            scenario: "normal",
            probeURL: backgroundProbeURL,
            reset: false,
            menuHost: false
        )
        XCTAssertFalse(
            app.descendants(matching: .any)["setupFlowRoot"].waitForExistence(timeout: 2),
            hierarchy(app, "A completed profile must not reopen onboarding")
        )
        XCTAssertEqual(app.windows.count, 0, "Second launch should be menu-bar-only")
        let statusItem = try realStatusItem(in: app)
        statusItem.click()
        XCTAssertTrue(
            app.menuItems["Settings…"].waitForExistence(timeout: 3),
            hierarchy(app, "The compact menu did not expose Settings")
        )
        XCTAssertTrue(
            app.menuItems["Microphone"].exists,
            hierarchy(app, "The compact menu did not expose the Microphone submenu")
        )
        XCTAssertTrue(app.menuItems["Copy Last Dictation"].exists)
        XCTAssertTrue(app.menuItems["Quit Timbre"].exists)
        XCTAssertFalse(app.menuItems["Start"].exists)
        XCTAssertFalse(app.menuItems["Stop"].exists)
        statusItem.click()

        let relaunched = try waitForProbe(backgroundProbeURL, timeout: 3) {
            $0.generation >= 2 && $0.installAttempts == 1
        }
        let textEdit = launchTextEdit()
        textEdit.activate()
        pressGlobalHotkey(in: textEdit)
        _ = try waitForProbe(backgroundProbeURL, timeout: 5) {
            $0.sessionStarts == relaunched.sessionStarts + 1
        }
        pressGlobalHotkey(in: textEdit)
        let readyUse = try waitForProbe(backgroundProbeURL, timeout: 5) {
            $0.successfulPastes == relaunched.successfulPastes + 1
        }
        XCTAssertEqual(readyUse.installAttempts, 1, "Relaunch must reuse the installed model")
    }

    @MainActor
    private func runSetupRecoveryScenarios() throws {
        let startingInstallAttempts = try readProbe(backgroundProbeURL).installAttempts

        var app = relaunchBackground(scenario: "clearShortcut", menuHost: true)
        XCTAssertTrue(
            app.buttons["setupShortcutSetButton"].waitForExistence(timeout: 5),
            hierarchy(app, "A missing shortcut must reopen shortcut setup")
        )
        try recordShortcut(in: app, mayAdvanceAutomatically: true)
        if app.buttons["setupDoneButton"].waitForExistence(timeout: 3) {
            app.buttons["setupDoneButton"].click()
        }
        XCTAssertEqual(try readProbe(backgroundProbeURL).installAttempts, startingInstallAttempts)

        app = relaunchBackground(scenario: "microphoneRevoked", menuHost: true)
        XCTAssertTrue(
            app.buttons["setupOpenMicSettingsButton"].waitForExistence(timeout: 5),
            hierarchy(app, "Missing microphone recovery")
        )
        app.buttons["setupOpenMicSettingsButton"].click()
        app.buttons["setupMicRetryButton"].click()
        if app.buttons["setupDoneButton"].waitForExistence(timeout: 3) {
            app.buttons["setupDoneButton"].click()
        }
        XCTAssertEqual(try readProbe(backgroundProbeURL).installAttempts, startingInstallAttempts)

        app = relaunchBackground(scenario: "accessibilityRevoked", menuHost: true)
        XCTAssertTrue(
            app.buttons["setupAccessibilityRetryButton"].waitForExistence(timeout: 5),
            hierarchy(app, "Missing Accessibility recovery")
        )
        // Try Again rechecks first; only after a failed recheck does the System
        // Settings action appear.
        app.buttons["setupAccessibilityRetryButton"].click()
        let accessibilitySettings = app.buttons["setupOpenAccessibilitySettingsButton"]
        XCTAssertTrue(
            accessibilitySettings.waitForExistence(timeout: 5),
            hierarchy(app, "Missing Accessibility recovery")
        )
        accessibilitySettings.click()
        // Granting Accessibility moves forward once the in-window monitor
        // notices the trust change.
        if app.buttons["setupDoneButton"].waitForExistence(timeout: 3) {
            app.buttons["setupDoneButton"].click()
        }
        XCTAssertEqual(try readProbe(backgroundProbeURL).installAttempts, startingInstallAttempts)
    }

    @MainActor
    private func runDeliverySafetyScenarios() throws {
        try runFallbackScenario(
            scenario: "normal",
            expectedResult: "copiedAfterInsertFailure.frontmostChanged"
        ) { textEdit, _, _ in
            let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
            finder.activate()
            self.pressGlobalHotkey(in: finder)
        }

        try runFallbackScenario(
            scenario: "normal",
            expectedResult: "copiedAfterInsertFailure.targetTerminated"
        ) { textEdit, app, _ in
            textEdit.terminate()
            XCTAssertTrue(textEdit.wait(for: .notRunning, timeout: 5))
            app.activate()
            self.pressGlobalHotkey(in: app)
        }

        for (scenario, result) in [
            ("accessibilityRevokedDuringDelivery", "copiedAfterInsertFailure.accessibilityUntrusted"),
            ("secureInput", "copiedAfterInsertFailure.secureInputField"),
            ("pasteboardRace", "copiedAfterInsertFailure.pasteboardChanged"),
            ("eventPostFailure", "copiedAfterInsertFailure.eventPostFailed"),
        ] {
            try runFallbackScenario(scenario: scenario, expectedResult: result) {
                textEdit, _, _ in
                self.pressGlobalHotkey(in: textEdit)
            }
        }
    }

    @MainActor
    private func runQuit() throws {
        let app = relaunchBackground(scenario: "cleanup", menuHost: true)
        let quit = app.windows["Timbre Integration Menu"].buttons["quitMenuItem"]
        XCTAssertTrue(quit.waitForExistence(timeout: 5), hierarchy(app, "Missing Quit"))
        quit.click()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 5), "Quit must terminate Timbre")
    }

    // MARK: - Scenario helpers

    @MainActor
    private func runFallbackScenario(
        scenario: String,
        expectedResult: String,
        stop: (XCUIApplication, XCUIApplication, ProbeSnapshot) throws -> Void
    ) throws {
        let app = relaunchBackground(scenario: scenario, menuHost: true)
        let textEdit = launchTextEdit()
        let before = try readProbe(backgroundProbeURL)
        textEdit.activate()
        pressGlobalHotkey(in: textEdit)
        _ = try waitForProbe(backgroundProbeURL, timeout: 5) {
            $0.sessionStarts == before.sessionStarts + 1
        }

        try stop(textEdit, app, before)
        let result = try waitForProbe(backgroundProbeURL, timeout: 5) {
            $0.lastDeliveryResult == expectedResult
        }
        XCTAssertEqual(result.successfulPastes, before.successfulPastes)
        XCTAssertEqual(result.lastDeliveryResult, expectedResult)

        XCTAssertTrue(app.windows["Timbre Integration Menu"].waitForExistence(timeout: 3))
    }

    @MainActor
    private func completeWelcomeAndRecordShortcut(in app: XCUIApplication) throws {
        // The welcome + sign-in page is a single step; the integration runtime
        // is always authenticated, so the way forward is the Continue button.
        let welcome = app.buttons["setupSignInContinueButton"]
        XCTAssertTrue(welcome.waitForExistence(timeout: 10), hierarchy(app, "Missing combined welcome + sign-in"))
        welcome.click()

        let shortcutContinue = app.buttons["setupShortcutContinueButton"]
        XCTAssertTrue(
            shortcutContinue.waitForExistence(timeout: 5),
            hierarchy(app, "Missing shortcut step")
        )
        XCTAssertFalse(shortcutContinue.isEnabled, "Fresh integration shortcut must be unset")
        try recordShortcut(in: app)
        XCTAssertTrue(shortcutContinue.isEnabled)
        shortcutContinue.click()
    }

    @MainActor
    private func recordShortcut(
        in app: XCUIApplication,
        mayAdvanceAutomatically: Bool = false
    ) throws {
        let setHotkey = app.buttons["setupShortcutSetButton"]
        XCTAssertTrue(setHotkey.waitForExistence(timeout: 5), hierarchy(app, "Missing Set hotkey"))
        setHotkey.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["setupShortcutRecordingStatus"]
                .waitForExistence(timeout: 2)
        )
        app.typeKey("k", modifierFlags: [.control, .shift])
        let assigned = app.descendants(matching: .any)["setupShortcutKeyCaps"]
        if assigned.waitForExistence(timeout: mayAdvanceAutomatically ? 1 : 5) {
            XCTAssertEqual(assigned.label, "Current hotkey ⌃⇧K")
            return
        }

        guard mayAdvanceAutomatically else {
            return XCTFail("Shortcut was not recorded. \(hierarchy(app, "Missing assigned shortcut"))")
        }
        let readyHint = app.descendants(matching: .any)["setupReadyShortcutHint"]
        XCTAssertTrue(
            readyHint.waitForExistence(timeout: 5),
            hierarchy(app, "Shortcut recovery did not restore readiness")
        )
        XCTAssertEqual(readyHint.label, "Press ⌃⇧K to start dictating anywhere.")
    }

    @MainActor
    private func launch(
        profile: String,
        scenario: String,
        probeURL: URL,
        reset: Bool,
        menuHost: Bool
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--integration-test"]
        app.launchEnvironment = [
            "TIMBRE_INTEGRATION_PROFILE": profile,
            "TIMBRE_INTEGRATION_SCENARIO": scenario,
            "TIMBRE_INTEGRATION_RESET": reset ? "1" : "0",
            "TIMBRE_INTEGRATION_MENU_HOST": menuHost ? "1" : "0",
            "TIMBRE_INTEGRATION_PROBE": probeURL.path,
        ]
        app.launch()
        self.app = app
        return app
    }

    @MainActor
    private func relaunchBackground(
        scenario: String,
        menuHost: Bool
    ) -> XCUIApplication {
        app?.terminate()
        _ = app?.wait(for: .notRunning, timeout: 5)
        return launch(
            profile: backgroundProfile,
            scenario: scenario,
            probeURL: backgroundProbeURL,
            reset: false,
            menuHost: menuHost
        )
    }

    @MainActor
    private func launchTextEdit() -> XCUIApplication {
        textEdit?.terminate()
        let textEdit = XCUIApplication(bundleIdentifier: "com.apple.TextEdit")
        textEdit.launch()
        self.textEdit = textEdit
        return textEdit
    }

    @MainActor
    private func realStatusItem(in app: XCUIApplication) throws -> XCUIElement {
        let inApp = app.descendants(matching: .any)["timbreStatusItem"]
        if inApp.waitForExistence(timeout: 2) {
            return inApp
        }
        let systemUIServer = XCUIApplication(bundleIdentifier: "com.apple.systemuiserver")
        let systemItem = systemUIServer.descendants(matching: .any)["timbreStatusItem"]
        XCTAssertTrue(
            systemItem.waitForExistence(timeout: 3),
            hierarchy(app, "Real Timbre status item was not exposed")
        )
        return systemItem
    }

    // MARK: - Probe and wait helpers

    private func readProbe(_ url: URL) throws -> ProbeSnapshot {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ProbeSnapshot.self, from: data)
    }

    private func waitForProbe(
        _ url: URL,
        timeout: TimeInterval,
        predicate: @escaping (ProbeSnapshot) -> Bool
    ) throws -> ProbeSnapshot {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { [weak self] _, _ in
                guard let self,
                      let snapshot = try? self.readProbe(url)
                else {
                    return false
                }
                return predicate(snapshot)
            },
            object: url
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: timeout),
            .completed,
            "Timed out waiting for probe condition at \(url.path)"
        )
        return try readProbe(url)
    }

    private func waitForLabel(
        _ element: XCUIElement,
        _ label: String,
        timeout: TimeInterval = 5
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                guard let element = object as? XCUIElement else { return false }
                return element.label == label || element.value as? String == label
            },
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func armShortcutBurst(
        after snapshot: ProbeSnapshot,
        extraInvocations: Int = 3
    ) throws -> ProbeSnapshot {
        let command = ShortcutBurstCommand(
            generation: snapshot.shortcutBurstsArmed + 1,
            extraInvocations: extraInvocations
        )
        let data = try JSONEncoder().encode(command)
        let commandURL = backgroundProbeURL.deletingPathExtension()
            .appendingPathExtension("shortcut-burst.json")
        try data.write(to: commandURL, options: .atomic)
        return try waitForProbe(backgroundProbeURL, timeout: 3) {
            $0.shortcutBurstsArmed == snapshot.shortcutBurstsArmed + 1
        }
    }

    /// Uses XCTest's event channel so a clean test machine does not need to grant
    /// Accessibility or Input Monitoring access to the XCTest runner. The event
    /// still enters through macOS and exercises the registered Carbon shortcut.
    @MainActor
    private func pressGlobalHotkey(in application: XCUIApplication) {
        application.typeKey("k", modifierFlags: [.control, .shift])
    }

    private func hierarchy(_ app: XCUIApplication, _ message: String) -> String {
        "\(message). Hierarchy:\n\(app.debugDescription)"
    }
}

private struct ProbeSnapshot: Codable {
    let generation: Int
    let modelState: String
    let installAttempts: Int
    let sessionStarts: Int
    let sessionStops: Int
    let shortcutBurstsArmed: Int
    let shortcutBurstInvocations: Int
    let pasteAttempts: Int
    let successfulPastes: Int
    let lastPasteText: String?
    let lastDeliveryResult: String?
    let lastStartToPreparingMilliseconds: Double?
    let lastStartToListeningMilliseconds: Double?
    let lastStopToCompletionMilliseconds: Double?
}

private struct ShortcutBurstCommand: Codable {
    let generation: Int
    let extraInvocations: Int
}
