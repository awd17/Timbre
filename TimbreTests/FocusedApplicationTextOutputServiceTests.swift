import AppKit
import Foundation
@testable import Timbre
import XCTest

@MainActor
final class FakePasteCommandPoster: PasteCommandEventPosting {
    private(set) var postCount = 0
    var shouldSucceed = true

    func postCommandV() -> Bool {
        postCount += 1
        return shouldSucceed
    }
}

@MainActor
final class FakeRunningProcessLookup: RunningProcessLooking {
    var processes: [pid_t: RunningProcessIdentity] = [:]

    func process(pid: pid_t) -> RunningProcessIdentity? {
        processes[pid]
    }
}

@MainActor
final class FakeSecureInputDetector: SecureInputDetecting {
    var securePids: Set<pid_t> = []

    func isSecureInputFocused(processIdentifier: pid_t) -> Bool {
        securePids.contains(processIdentifier)
    }
}

@MainActor
final class FocusedApplicationTextOutputServiceTests: XCTestCase {
    private let sampleTarget = DictationTargetContext(
        processIdentifier: 99,
        bundleIdentifier: "com.example.Editor",
        localizedName: "Editor"
    )

    func testTrustedMatchingTargetPostsPaste() async {
        let pasteboard = NSPasteboard.withUniqueName()
        let clipboard = ClipboardService(pasteboard: pasteboard)
        let targets = FakeDictationTargetProvider()
        targets.frontmostExternal = sampleTarget
        let poster = FakePasteCommandPoster()
        let service = makeService(
            clipboard: clipboard,
            pasteboard: pasteboard,
            accessibility: FakeAccessibilityPermission(trustState: .trusted),
            targets: targets,
            poster: poster
        )

        let result = await service.deliver("hello", to: sampleTarget)

        XCTAssertEqual(result, .pasteEventPosted)
        XCTAssertEqual(pasteboard.string(forType: .string), "hello")
        XCTAssertEqual(poster.postCount, 1)
    }

    func testUntrustedCopiesOnly() async {
        let pasteboard = NSPasteboard.withUniqueName()
        let clipboard = ClipboardService(pasteboard: pasteboard)
        let poster = FakePasteCommandPoster()
        let service = makeService(
            clipboard: clipboard,
            pasteboard: pasteboard,
            accessibility: FakeAccessibilityPermission(trustState: .notTrusted),
            targets: FakeDictationTargetProvider(),
            poster: poster
        )

        let result = await service.deliver("hello", to: sampleTarget)

        XCTAssertEqual(result, .copiedAfterInsertFailure(.accessibilityUntrusted))
        XCTAssertEqual(pasteboard.string(forType: .string), "hello")
        XCTAssertEqual(poster.postCount, 0)
    }

    func testMissingTargetCopiesOnly() async {
        let pasteboard = NSPasteboard.withUniqueName()
        let poster = FakePasteCommandPoster()
        let service = makeService(
            clipboard: ClipboardService(pasteboard: pasteboard),
            pasteboard: pasteboard,
            accessibility: FakeAccessibilityPermission(trustState: .trusted),
            targets: FakeDictationTargetProvider(),
            poster: poster
        )

        let result = await service.deliver("hello", to: nil)

        XCTAssertEqual(result, .copiedAfterInsertFailure(.missingTarget))
        XCTAssertEqual(poster.postCount, 0)
    }

    func testClipboardFailureReturnsDeliveryFailure() async {
        let clipboard = FakeClipboard()
        clipboard.copySucceeds = false
        let poster = FakePasteCommandPoster()
        let service = makeService(
            clipboard: clipboard,
            pasteboard: NSPasteboard.withUniqueName(),
            accessibility: FakeAccessibilityPermission(trustState: .trusted),
            targets: FakeDictationTargetProvider(),
            poster: poster
        )

        let result = await service.deliver("hello", to: sampleTarget)

        XCTAssertEqual(result, .failed(.clipboardUnavailable))
        XCTAssertEqual(poster.postCount, 0)
    }

    func testFrontmostChangedCopiesOnly() async {
        let pasteboard = NSPasteboard.withUniqueName()
        let targets = FakeDictationTargetProvider()
        targets.frontmostExternal = DictationTargetContext(
            processIdentifier: 100,
            bundleIdentifier: "com.other.App",
            localizedName: "Other"
        )
        let poster = FakePasteCommandPoster()
        let service = makeService(
            clipboard: ClipboardService(pasteboard: pasteboard),
            pasteboard: pasteboard,
            accessibility: FakeAccessibilityPermission(trustState: .trusted),
            targets: targets,
            poster: poster
        )

        let result = await service.deliver("hello", to: sampleTarget)

        XCTAssertEqual(result, .copiedAfterInsertFailure(.frontmostChanged))
        XCTAssertEqual(poster.postCount, 0)
    }

    func testTerminatedTargetCopiesOnly() async {
        let pasteboard = NSPasteboard.withUniqueName()
        let lookup = FakeRunningProcessLookup()
        lookup.processes[99] = RunningProcessIdentity(
            processIdentifier: 99,
            bundleIdentifier: "com.example.Editor",
            isTerminated: true
        )
        let targets = FakeDictationTargetProvider()
        targets.frontmostExternal = sampleTarget
        let poster = FakePasteCommandPoster()
        let service = makeService(
            clipboard: ClipboardService(pasteboard: pasteboard),
            pasteboard: pasteboard,
            accessibility: FakeAccessibilityPermission(trustState: .trusted),
            targets: targets,
            poster: poster,
            processLookup: lookup
        )

        let result = await service.deliver("hello", to: sampleTarget)

        XCTAssertEqual(result, .copiedAfterInsertFailure(.targetTerminated))
        XCTAssertEqual(poster.postCount, 0)
    }

    func testSelfFrontmostReactivatesCapturedTarget() async {
        let pasteboard = NSPasteboard.withUniqueName()
        let targets = FakeDictationTargetProvider()
        targets.isSelfFrontmost = true
        targets.frontmostExternal = nil
        targets.activateSucceeds = true
        let poster = FakePasteCommandPoster()
        let service = makeService(
            clipboard: ClipboardService(pasteboard: pasteboard),
            pasteboard: pasteboard,
            accessibility: FakeAccessibilityPermission(trustState: .trusted),
            targets: targets,
            poster: poster
        )

        let result = await service.deliver("hello", to: sampleTarget)

        XCTAssertEqual(result, .pasteEventPosted)
        XCTAssertEqual(targets.activateCallCount, 1)
        XCTAssertEqual(poster.postCount, 1)
    }

    func testSecureFieldCopiesOnly() async {
        let pasteboard = NSPasteboard.withUniqueName()
        let targets = FakeDictationTargetProvider()
        targets.frontmostExternal = sampleTarget
        let secure = FakeSecureInputDetector()
        secure.securePids = [99]
        let poster = FakePasteCommandPoster()
        let service = makeService(
            clipboard: ClipboardService(pasteboard: pasteboard),
            pasteboard: pasteboard,
            accessibility: FakeAccessibilityPermission(trustState: .trusted),
            targets: targets,
            poster: poster,
            secureInput: secure
        )

        let result = await service.deliver("secret", to: sampleTarget)

        XCTAssertEqual(result, .copiedAfterInsertFailure(.secureInputField))
        XCTAssertEqual(poster.postCount, 0)
    }

    func testEventPostFailureCopiesOnly() async {
        let pasteboard = NSPasteboard.withUniqueName()
        let targets = FakeDictationTargetProvider()
        targets.frontmostExternal = sampleTarget
        let poster = FakePasteCommandPoster()
        poster.shouldSucceed = false
        let service = makeService(
            clipboard: ClipboardService(pasteboard: pasteboard),
            pasteboard: pasteboard,
            accessibility: FakeAccessibilityPermission(trustState: .trusted),
            targets: targets,
            poster: poster
        )

        let result = await service.deliver("hello", to: sampleTarget)

        XCTAssertEqual(result, .copiedAfterInsertFailure(.eventPostFailed))
        XCTAssertEqual(poster.postCount, 1)
    }

    func testTargetsMatchRequiresPidAndBundleWhenBothPresent() {
        let a = DictationTargetContext(
            processIdentifier: 1,
            bundleIdentifier: "a.b",
            localizedName: "A"
        )
        let same = DictationTargetContext(
            processIdentifier: 1,
            bundleIdentifier: "a.b",
            localizedName: "A"
        )
        let differentBundle = DictationTargetContext(
            processIdentifier: 1,
            bundleIdentifier: "c.d",
            localizedName: "C"
        )
        XCTAssertTrue(FocusedApplicationTextOutputService.targetsMatch(captured: a, frontmost: same))
        XCTAssertFalse(
            FocusedApplicationTextOutputService.targetsMatch(captured: a, frontmost: differentBundle)
        )
    }

    func testClipboardOnlyDeliveryNeverPastes() async {
        let clipboard = FakeClipboard()
        let delivery = ClipboardOnlyTranscriptDelivery(clipboard: clipboard)
        let result = await delivery.deliver("hi", to: sampleTarget)
        XCTAssertEqual(result, .copiedByDesign)
        XCTAssertEqual(clipboard.lastCopied, "hi")
    }

    func testClipboardOnlyDeliveryReportsClipboardFailure() async {
        let clipboard = FakeClipboard()
        clipboard.copySucceeds = false
        let delivery = ClipboardOnlyTranscriptDelivery(clipboard: clipboard)

        let result = await delivery.deliver("hi", to: sampleTarget)

        XCTAssertEqual(result, .failed(.clipboardUnavailable))
    }

    private func makeService(
        clipboard: ClipboardServicing,
        pasteboard: NSPasteboard,
        accessibility: FakeAccessibilityPermission,
        targets: FakeDictationTargetProvider,
        poster: FakePasteCommandPoster,
        processLookup: FakeRunningProcessLookup? = nil,
        secureInput: FakeSecureInputDetector? = nil
    ) -> FocusedApplicationTextOutputService {
        let lookup = processLookup ?? {
            let created = FakeRunningProcessLookup()
            created.processes[sampleTarget.processIdentifier] = RunningProcessIdentity(
                processIdentifier: sampleTarget.processIdentifier,
                bundleIdentifier: sampleTarget.bundleIdentifier,
                isTerminated: false
            )
            return created
        }()
        return FocusedApplicationTextOutputService(
            clipboard: clipboard,
            accessibility: accessibility,
            targetProvider: targets,
            pastePoster: poster,
            processLookup: lookup,
            secureInputDetector: secureInput ?? FakeSecureInputDetector(),
            selfBundleIdentifier: "com.timbre.app",
            pasteboard: pasteboard
        )
    }
}
