import AppKit
import Foundation
@testable import Timbre
import XCTest

final class AudioLevelMeterTests: XCTestCase {
    func testNormalizationClampsSilenceAndLoudInput() {
        XCTAssertEqual(AudioLevelMeter.normalizedLevel(rms: 0), 0)
        XCTAssertEqual(
            AudioLevelMeter.normalizedLevel(
                rms: pow(10, AudioLevelMeter.floorDecibels / 20)
            ),
            0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            AudioLevelMeter.normalizedLevel(
                rms: pow(10, AudioLevelMeter.ceilingDecibels / 20)
            ),
            1,
            accuracy: 0.001
        )
        XCTAssertEqual(AudioLevelMeter.normalizedLevel(rms: 2), 1)
    }

    func testMeterThrottlesAndUsesSlowerReleaseThanAttack() throws {
        let throttledMeter = AudioLevelMeter(maximumUpdatesPerSecond: 10)
        XCTAssertNotNil(throttledMeter.consume(rms: 1, time: 1))
        XCTAssertNil(throttledMeter.consume(rms: 1, time: 1.05))

        let smoothingMeter = AudioLevelMeter(maximumUpdatesPerSecond: 100)
        let loud = try XCTUnwrap(smoothingMeter.consume(rms: 1, time: 1))
        let released = try XCTUnwrap(smoothingMeter.consume(rms: 0, time: 1.02))
        XCTAssertGreaterThan(released, 0.4)
        XCTAssertLessThan(released, loud)
    }
}

final class DictationIndicatorPresentationTests: XCTestCase {
    func testSessionStatesMapToIconOnlyPresentations() {
        XCTAssertEqual(
            DictationIndicatorPresentation.presentation(for: .preparing),
            .preparing
        )
        XCTAssertEqual(
            DictationIndicatorPresentation.presentation(
                for: .listening(transcript: "")
            ),
            .listening
        )
        XCTAssertEqual(
            DictationIndicatorPresentation.presentation(
                for: .finishing(transcript: "hello")
            ),
            .processing
        )
        XCTAssertEqual(
            DictationIndicatorPresentation.presentation(
                for: .completed(transcript: "hello", outcome: .inserted)
            ),
            .hidden
        )
        XCTAssertEqual(
            DictationIndicatorPresentation.presentation(
                for: .completed(
                    transcript: "hello",
                    outcome: .copiedAfterInsertFailure
                )
            ),
            .copyFallback
        )
        XCTAssertEqual(
            DictationIndicatorPresentation.presentation(
                for: .failed(
                    kind: .noSpeech,
                    message: "No speech",
                    transcript: ""
                )
            ),
            .hidden
        )
        XCTAssertEqual(
            DictationIndicatorPresentation.presentation(
                for: .failed(
                    kind: .permission,
                    message: "Denied",
                    transcript: ""
                )
            ),
            .failure
        )
    }
}

final class DictationIndicatorPlacementTests: XCTestCase {
    func testClampingKeepsPanelInsideVisibleFrame() {
        let visible = NSRect(x: 100, y: 200, width: 1200, height: 800)
        let frame = DictationIndicatorPlacementStore.clampedFrame(
            centeredAt: NSPoint(x: -500, y: 3000),
            size: NSSize(width: 84, height: 40),
            in: visible
        )

        XCTAssertGreaterThanOrEqual(frame.minX, visible.minX + 8)
        XCTAssertLessThanOrEqual(frame.maxX, visible.maxX - 8)
        XCTAssertGreaterThanOrEqual(frame.minY, visible.minY + 8)
        XCTAssertLessThanOrEqual(frame.maxY, visible.maxY - 8)
    }

    func testPlacementRoundTripsThroughDefaults() throws {
        let suiteName = "DictationIndicatorPlacementTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = DictationIndicatorPlacementStore(defaults: defaults)
        let screen = try XCTUnwrap(NSScreen.main)
        let frame = NSRect(
            x: screen.visibleFrame.midX - 42,
            y: screen.visibleFrame.minY + 48,
            width: 84,
            height: 40
        )

        store.save(frame: frame, on: screen)

        let placement = try XCTUnwrap(store.load())
        XCTAssertEqual(placement.absoluteCenterX, frame.midX, accuracy: 0.001)
        XCTAssertEqual(placement.absoluteCenterY, frame.midY, accuracy: 0.001)
    }

    func testResetClearsSavedPlacement() throws {
        let suiteName = "DictationIndicatorPlacementResetTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = DictationIndicatorPlacementStore(defaults: defaults)
        let screen = try XCTUnwrap(NSScreen.main)
        let frame = NSRect(
            x: screen.visibleFrame.midX - 42,
            y: screen.visibleFrame.minY + 48,
            width: 84,
            height: 40
        )
        store.save(frame: frame, on: screen)
        XCTAssertNotNil(store.load())

        store.reset()

        XCTAssertNil(store.load())
        XCTAssertNil(defaults.object(forKey: DictationIndicatorPlacementStore.key))
    }
}
