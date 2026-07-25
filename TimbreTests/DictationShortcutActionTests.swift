import Foundation
@testable import Timbre
import XCTest

final class DictationShortcutActionTests: XCTestCase {
    func testIdleStarts() {
        XCTAssertEqual(
            DictationShortcutPolicy.resolve(session: .idle, setup: .unrestricted),
            .start
        )
    }

    func testListeningStops() {
        XCTAssertEqual(
            DictationShortcutPolicy.resolve(
                session: .listening(transcript: ""),
                setup: .unrestricted
            ),
            .stop
        )
    }

    func testPreparingAndFinishingAreNoOp() {
        XCTAssertEqual(
            DictationShortcutPolicy.resolve(session: .preparing, setup: .unrestricted),
            .none
        )
        XCTAssertEqual(
            DictationShortcutPolicy.resolve(
                session: .finishing(transcript: "x"),
                setup: .unrestricted
            ),
            .none
        )
    }

    func testCompletedAndFailedStartFreshSession() {
        XCTAssertEqual(
            DictationShortcutPolicy.resolve(
                session: .completed(transcript: "done", outcome: .inserted),
                setup: .unrestricted
            ),
            .start
        )
        XCTAssertEqual(
            DictationShortcutPolicy.resolve(
                session: .failed(kind: .recognition, message: "err", transcript: ""),
                setup: .unrestricted
            ),
            .start
        )
    }

    func testSetupInstallingIsNoOp() {
        let setup = DictationShortcutSetupContext(
            allowsDictation: false,
            blocksDictationUI: true,
            isInstalling: true,
            isSetupFailed: false
        )
        XCTAssertEqual(
            DictationShortcutPolicy.resolve(session: .idle, setup: setup),
            .none
        )
    }

    func testSetupFailedPresentsSetup() {
        let setup = DictationShortcutSetupContext(
            allowsDictation: false,
            blocksDictationUI: true,
            isInstalling: false,
            isSetupFailed: true
        )
        XCTAssertEqual(
            DictationShortcutPolicy.resolve(session: .idle, setup: setup),
            .presentSetup
        )
    }

    func testSetupRequiredPresentsSetup() {
        let setup = DictationShortcutSetupContext(
            allowsDictation: false,
            blocksDictationUI: true,
            isInstalling: false,
            isSetupFailed: false
        )
        XCTAssertEqual(
            DictationShortcutPolicy.resolve(session: .idle, setup: setup),
            .presentSetup
        )
    }

    func testAllowsDictationUsesSessionMapping() {
        let setup = DictationShortcutSetupContext(
            allowsDictation: true,
            blocksDictationUI: false,
            isInstalling: false,
            isSetupFailed: false
        )
        XCTAssertEqual(
            DictationShortcutPolicy.resolve(
                session: .listening(transcript: "hi"),
                setup: setup
            ),
            .stop
        )
    }
}
