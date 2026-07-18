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
}
