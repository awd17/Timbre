import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

@MainActor
protocol PasteboardReading {
    var changeCount: Int { get }
    func string(forType dataType: NSPasteboard.PasteboardType) -> String?
}

extension NSPasteboard: PasteboardReading {}

struct RunningProcessIdentity: Equatable, Sendable {
    let processIdentifier: pid_t
    let bundleIdentifier: String?
    let isTerminated: Bool
    let launchDate: Date?

    init(
        processIdentifier: pid_t,
        bundleIdentifier: String?,
        isTerminated: Bool,
        launchDate: Date? = nil
    ) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.isTerminated = isTerminated
        self.launchDate = launchDate
    }
}

@MainActor
protocol RunningProcessLooking {
    func process(pid: pid_t) -> RunningProcessIdentity?
}

@MainActor
struct WorkspaceRunningProcessLookup: RunningProcessLooking {
    func process(pid: pid_t) -> RunningProcessIdentity? {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        return RunningProcessIdentity(
            processIdentifier: app.processIdentifier,
            bundleIdentifier: app.bundleIdentifier,
            isTerminated: app.isTerminated,
            launchDate: app.launchDate
        )
    }
}

@MainActor
protocol SecureInputDetecting {
    func isSecureInputFocused(processIdentifier: pid_t) -> Bool
}

@MainActor
struct AccessibilitySecureInputDetector: SecureInputDetecting {
    func isSecureInputFocused(processIdentifier: pid_t) -> Bool {
        let appElement = AXUIElementCreateApplication(processIdentifier)
        var focusedObject: AnyObject?
        let focusedResult = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedObject
        )
        guard focusedResult == .success, let focusedObject else {
            return false
        }

        guard CFGetTypeID(focusedObject) == AXUIElementGetTypeID() else {
            return false
        }
        let focused = unsafeBitCast(focusedObject, to: AXUIElement.self)
        var roleObject: AnyObject?
        let roleResult = AXUIElementCopyAttributeValue(
            focused,
            kAXRoleAttribute as CFString,
            &roleObject
        )
        guard roleResult == .success, let role = roleObject as? String else {
            return false
        }
        return role == "AXSecureTextField"
    }
}

@MainActor
struct CGEventPasteCommandPoster: PasteCommandEventPosting {
    func postCommandV() -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            TimbreLog.line("Timbre delivery: failed to create CGEventSource")
            return false
        }

        let keyCode = CGKeyCode(kVK_ANSI_V)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else {
            TimbreLog.line("Timbre delivery: failed to create Command-V events")
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        TimbreLog.line("Timbre delivery: Command-V events posted (insertion not universally confirmable)")
        return true
    }
}

@MainActor
final class FocusedApplicationTextOutputService: TranscriptDeliveryServicing {
    private let clipboard: ClipboardServicing
    private let accessibility: any AccessibilityPermissionProviding
    private let targetProvider: any DictationTargetProviding
    private let pastePoster: any PasteCommandEventPosting
    private let processLookup: any RunningProcessLooking
    private let secureInputDetector: any SecureInputDetecting
    private let selfBundleIdentifier: String?
    private let preferences: any AppPreferencesProviding
    private let transcriptPasteboard: any TranscriptPasteboardServicing
    private let onClipboardOutcome: (ClipboardRetentionOutcome) -> Void

    init(
        clipboard: ClipboardServicing = ClipboardService(),
        accessibility: any AccessibilityPermissionProviding,
        targetProvider: any DictationTargetProviding,
        pastePoster: (any PasteCommandEventPosting)? = nil,
        processLookup: (any RunningProcessLooking)? = nil,
        secureInputDetector: (any SecureInputDetecting)? = nil,
        selfBundleIdentifier: String? = Bundle.main.bundleIdentifier,
        pasteboard: any PasteboardReading = NSPasteboard.general,
        preferences: (any AppPreferencesProviding)? = nil,
        transcriptPasteboard: (any TranscriptPasteboardServicing)? = nil,
        onClipboardOutcome: @escaping (ClipboardRetentionOutcome) -> Void = { _ in }
    ) {
        self.clipboard = clipboard
        self.accessibility = accessibility
        self.targetProvider = targetProvider
        self.pastePoster = pastePoster ?? CGEventPasteCommandPoster()
        self.processLookup = processLookup ?? WorkspaceRunningProcessLookup()
        self.secureInputDetector = secureInputDetector ?? AccessibilitySecureInputDetector()
        self.selfBundleIdentifier = selfBundleIdentifier
        self.preferences = preferences ?? UserDefaultsAppPreferences()
        self.transcriptPasteboard = transcriptPasteboard
            ?? TranscriptPasteboardService(
                pasteboard: (pasteboard as? NSPasteboard) ?? .general
            )
        self.onClipboardOutcome = onClipboardOutcome
    }

    func deliver(
        _ transcript: String,
        to target: DictationTargetContext?
    ) async -> TranscriptDeliveryResult {
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failed(.emptyTranscript)
        }

        guard accessibility.trustState == .trusted else {
            TimbreLog.line("Timbre delivery: Accessibility not trusted; copy only")
            return copyFallback(transcript, reason: .accessibilityUntrusted)
        }

        guard let target else {
            TimbreLog.line("Timbre delivery: missing target; copy only")
            return copyFallback(transcript, reason: .missingTarget)
        }

        if let selfBundleIdentifier,
           target.bundleIdentifier == selfBundleIdentifier
        {
            TimbreLog.line("Timbre delivery: target is Timbre; copy only")
            return copyFallback(transcript, reason: .targetIsSelf)
        }

        guard let running = processLookup.process(pid: target.processIdentifier),
              !running.isTerminated
        else {
            TimbreLog.line("Timbre delivery: target terminated; copy only")
            return copyFallback(transcript, reason: .targetTerminated)
        }

        if let expectedBundle = target.bundleIdentifier {
            guard let actualBundle = running.bundleIdentifier else {
                TimbreLog.line("Timbre delivery: ambiguous target identity; copy only")
                return copyFallback(transcript, reason: .ambiguousTargetIdentity)
            }
            guard actualBundle == expectedBundle else {
                TimbreLog.line("Timbre delivery: pid/bundle mismatch; copy only")
                return copyFallback(transcript, reason: .ambiguousTargetIdentity)
            }
        } else {
            guard let expectedLaunchDate = target.launchDate,
                  running.launchDate == expectedLaunchDate
            else {
                TimbreLog.line("Timbre delivery: pid/launch-date mismatch; copy only")
                return copyFallback(transcript, reason: .ambiguousTargetIdentity)
            }
        }

        if let frontmostExternal = targetProvider.frontmostExternalTarget() {
            if !Self.targetsMatch(captured: target, frontmost: frontmostExternal) {
                TimbreLog.line("Timbre delivery: frontmost changed; copy only")
                return copyFallback(transcript, reason: .frontmostChanged)
            }
        } else if targetProvider.isSelfFrontmost {
            // MenuBarExtra path: Timbre briefly owns focus. Reactivate only the
            // original captured target — never a different third-party app.
            TimbreLog.line("Timbre delivery: Timbre frontmost; reactivating captured target")
            guard await targetProvider.activateTarget(target) else {
                TimbreLog.line("Timbre delivery: target reactivation failed; copy only")
                return copyFallback(transcript, reason: .frontmostChanged)
            }
            guard let confirmed = targetProvider.frontmostExternalTarget(),
                  Self.targetsMatch(captured: target, frontmost: confirmed)
            else {
                TimbreLog.line("Timbre delivery: target reactivation not confirmed; copy only")
                return copyFallback(transcript, reason: .frontmostChanged)
            }
        } else {
            TimbreLog.line("Timbre delivery: no usable frontmost app; copy only")
            return copyFallback(transcript, reason: .frontmostChanged)
        }

        if secureInputDetector.isSecureInputFocused(processIdentifier: target.processIdentifier) {
            TimbreLog.line("Timbre delivery: secure input field; copy only")
            return copyFallback(transcript, reason: .secureInputField)
        }

        TimbreLog.line("Timbre delivery: target validation succeeded")

        let keepTranscript = preferences.keepTranscriptOnClipboardAfterInsertion
        let snapshotCapture = keepTranscript
            ? PasteboardSnapshotCapture.unavailable
            : transcriptPasteboard.captureCompleteSnapshot()
        let snapshot: PasteboardSnapshot?
        let retainedOutcome: ClipboardRetentionOutcome
        switch snapshotCapture {
        case .snapshot(let captured):
            snapshot = captured
            retainedOutcome = .transcriptIntentionallyRetained
        case .unavailable:
            snapshot = nil
            retainedOutcome = keepTranscript
                ? .transcriptIntentionallyRetained
                : .restorationSkipped(.snapshotUnavailable)
        }

        guard let write = transcriptPasteboard.writeTranscript(
            transcript,
            restorationSnapshot: snapshot,
            retainedOutcome: retainedOutcome,
            onOutcome: onClipboardOutcome
        ) else {
            TimbreLog.line("Timbre delivery: clipboard write failed")
            return .failed(.clipboardUnavailable)
        }
        TimbreLog.line(
            "Timbre delivery: pasteboard write succeeded (changeCount \(write.changeCount))"
        )

        guard transcriptPasteboard.isCurrentWriteUnchanged(write) else {
            TimbreLog.line("Timbre delivery: pasteboard changed before paste")
            transcriptPasteboard.cancelRestoration(
                for: write,
                outcome: .restorationSkipped(.clipboardChanged)
            )
            return .copiedAfterInsertFailure(.pasteboardChanged)
        }

        guard pastePoster.postCommandV() else {
            transcriptPasteboard.cancelRestoration(
                for: write,
                outcome: .insertionFailedTranscriptRetained(.eventPostFailed)
            )
            return .copiedAfterInsertFailure(.eventPostFailed)
        }

        return .pasteEventPosted
    }

    private func copyFallback(
        _ transcript: String,
        reason: CopyFallbackReason
    ) -> TranscriptDeliveryResult {
        guard clipboard.copy(transcript) else {
            return .failed(.clipboardUnavailable)
        }
        onClipboardOutcome(.insertionFailedTranscriptRetained(reason))
        TimbreLog.line("Timbre clipboard: insertion failed; transcript retained (\(reason))")
        return .copiedAfterInsertFailure(reason)
    }

    static func targetsMatch(
        captured: DictationTargetContext,
        frontmost: DictationTargetContext
    ) -> Bool {
        if captured.processIdentifier != frontmost.processIdentifier {
            return false
        }
        if let capturedBundle = captured.bundleIdentifier {
            return frontmost.bundleIdentifier == capturedBundle
        }
        guard let capturedLaunchDate = captured.launchDate else { return false }
        return frontmost.launchDate == capturedLaunchDate
    }
}
