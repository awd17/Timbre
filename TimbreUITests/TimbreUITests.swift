import XCTest

final class TimbreUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testDebugWindowMockDictationAndScreenshot() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--debug-window", "--mock-transcription"]
        app.launch()
        app.activate()

        let debugWindow = app.windows["Timbre Debug"]
        XCTAssertTrue(
            debugWindow.waitForExistence(timeout: 10),
            "Expected AppKit debug window. Hierarchy:\n\(app.debugDescription)"
        )

        let start = debugWindow.buttons["startButton"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.click()

        let stop = debugWindow.buttons["stopButton"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))

        let transcript = debugWindow.staticTexts["transcriptText"]
        let heardSpeech = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "Hello"),
            object: transcript
        )
        _ = XCTWaiter.wait(for: [heardSpeech], timeout: 2)

        stop.click()

        let copyAgain = debugWindow.buttons["copyAgainButton"]
        let copyEnabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == true"),
            object: copyAgain
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [copyEnabled], timeout: 5),
            .completed,
            "Expected Copy Again after successful mock transcription"
        )

        let screenshot = XCTAttachment(screenshot: debugWindow.screenshot())
        screenshot.name = "debug-window-mock-dictation"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testSimulatedOnboardingWelcomeThroughReady() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--simulate-onboarding",
            "--simulate-onboarding-duration",
            "8",
        ]
        app.launch()
        app.activate()

        let setupRoot = app.descendants(matching: .any)["setupFlowRoot"]
        XCTAssertTrue(
            setupRoot.waitForExistence(timeout: 10),
            "Expected simulated setup window. Hierarchy:\n\(app.debugDescription)"
        )

        let welcomeContinue = app.buttons["setupContinueButton"]
        XCTAssertTrue(welcomeContinue.waitForExistence(timeout: 5))
        welcomeContinue.click()

        let shortcutContinue = app.buttons["setupShortcutContinueButton"]
        XCTAssertTrue(shortcutContinue.waitForExistence(timeout: 5))
        XCTAssertTrue(shortcutContinue.isEnabled)

        let setHotkey = app.buttons["setupShortcutSetButton"]
        XCTAssertTrue(setHotkey.waitForExistence(timeout: 2))
        setHotkey.click()

        let recordingStatus = app.descendants(matching: .any)["setupShortcutRecordingStatus"]
        let listening = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Press the shortcut you want to use."),
            object: recordingStatus
        )
        XCTAssertEqual(XCTWaiter.wait(for: [listening], timeout: 5), .completed)

        app.typeKey("k", modifierFlags: [.control, .shift])
        XCTAssertTrue(shortcutContinue.isEnabled)
        shortcutContinue.click()

        let background = app.buttons["setupContinueInBackgroundButton"]
        XCTAssertTrue(
            background.waitForExistence(timeout: 5),
            "Expected preparing step with Continue in Background. Hierarchy:\n\(app.debugDescription)"
        )
        XCTAssertTrue(app.descendants(matching: .any)["setupProgress"].waitForExistence(timeout: 2))

        // Visual check for the bottom gray bar regression.
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "onboarding-preparing-no-bottom-bar"
        attachment.lifetime = .keepAlways
        add(attachment)
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("timbre-onboarding-preparing-check.png")
        try screenshot.pngRepresentation.write(to: out)
        NSLog("Wrote onboarding screenshot to \(out.path)")

        // Stay on the window through completion. Close/reopen-without-cancel is covered by
        // SetupCoordinator unit tests; MenuBarExtra reopen is unreliable in UI automation.
        let done = app.buttons["setupDoneButton"]
        XCTAssertTrue(
            done.waitForExistence(timeout: 20),
            "Expected Ready after simulated download. Hierarchy:\n\(app.debugDescription)"
        )

        let readyHint = app.descendants(matching: .any)["setupReadyShortcutHint"]
        XCTAssertTrue(
            readyHint.waitForExistence(timeout: 2),
            "Expected Ready shortcut hint. Hierarchy:\n\(app.debugDescription)"
        )

        done.click()
    }

    @MainActor
    func testHotkeyButtonRecordsShortcutDuringSimulatedOnboarding() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--simulate-onboarding",
            "--simulate-onboarding-duration",
            "2",
            "--simulate-onboarding-step",
            "shortcut-empty",
        ]
        app.launch()
        app.activate()

        let hotkeyDisplay = app.descendants(matching: .any)["setupShortcutDisplay"]
        XCTAssertTrue(
            hotkeyDisplay.waitForExistence(timeout: 10),
            "Expected the custom hotkey display. Hierarchy:\n\(app.debugDescription)"
        )

        let shortcutContinue = app.buttons["setupShortcutContinueButton"]
        XCTAssertTrue(shortcutContinue.waitForExistence(timeout: 5))
        XCTAssertFalse(shortcutContinue.isEnabled)

        let setHotkey = app.buttons["setupShortcutSetButton"]
        XCTAssertTrue(setHotkey.waitForExistence(timeout: 5))
        setHotkey.click()

        let recordingStatus = app.descendants(matching: .any)["setupShortcutRecordingStatus"]
        let listening = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Press the shortcut you want to use."),
            object: recordingStatus
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [listening], timeout: 5),
            .completed,
            "Expected recording guidance after pressing Set hotkey. Current value: \(String(describing: recordingStatus.value))"
        )

        app.typeKey("k", modifierFlags: [.control, .shift])

        let assignedHotkey = app.descendants(matching: .any)["setupShortcutKeyCaps"]
        XCTAssertTrue(
            assignedHotkey.waitForExistence(timeout: 5),
            "Expected Control-Shift-K above the button. Hierarchy:\n\(app.debugDescription)"
        )
        XCTAssertEqual(assignedHotkey.label, "Current hotkey ⌃⇧K")
        XCTAssertTrue(shortcutContinue.isEnabled)

        let screenshot = XCTAttachment(screenshot: app.windows["Timbre"].screenshot())
        screenshot.name = "onboarding-custom-hotkey-control"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
