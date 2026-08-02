import CoreGraphics
@testable import Timbre
import XCTest

final class EscapeKeyInterceptorTests: XCTestCase {
    func testInterceptsEscapeKeyDownAndLeavesOtherKeysAlone() {
        XCTAssertTrue(
            EscapeKeyInterceptor.shouldIntercept(
                eventType: .keyDown,
                keyCode: 53
            )
        )
        XCTAssertFalse(
            EscapeKeyInterceptor.shouldIntercept(
                eventType: .keyUp,
                keyCode: 53
            )
        )
        XCTAssertFalse(
            EscapeKeyInterceptor.shouldIntercept(
                eventType: .keyDown,
                keyCode: 36
            )
        )
    }
}
