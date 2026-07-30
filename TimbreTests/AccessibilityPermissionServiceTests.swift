import Foundation
@testable import Timbre
import XCTest

@MainActor
final class AccessibilityPermissionServiceTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "AccessibilityPermissionServiceTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
    }

    func testTrustedProcessDoesNotRequestPrompt() async {
        var promptCount = 0
        let service = AccessibilityPermissionService(
            defaults: defaults,
            isProcessTrusted: { true },
            requestSystemPrompt: { promptCount += 1 }
        )

        let state = await service.requestAccessIfNeeded()

        XCTAssertEqual(state, .trusted)
        XCTAssertEqual(promptCount, 0)
        XCTAssertFalse(service.hasOfferedPrompt)
    }

    func testExplicitRetryReregistersEvenWhenPromptWasPreviouslyOffered() async {
        defaults.set(true, forKey: AccessibilityPermissionService.offeredPromptKey)
        var isTrusted = false
        var promptCount = 0
        let service = AccessibilityPermissionService(
            defaults: defaults,
            isProcessTrusted: { isTrusted },
            requestSystemPrompt: {
                promptCount += 1
                isTrusted = true
            }
        )

        let state = await service.requestAccessIfNeeded()

        XCTAssertEqual(state, .trusted)
        XCTAssertEqual(promptCount, 1)
        XCTAssertTrue(service.hasOfferedPrompt)
    }
}
