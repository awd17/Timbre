import CoreGraphics
import Foundation

/// Temporarily owns Escape while a dictation session is active.
///
/// A global `NSEvent` monitor can observe Escape in another application, but it
/// cannot prevent that application from handling the same key press. An active
/// session event tap can consume the key-down instead. The tap is installed only
/// for Preparing/Listening/Processing and is removed as soon as the session ends,
/// so Escape behaves normally everywhere else.
final class EscapeKeyInterceptor {
    private static let escapeKeyCode: Int64 = 53

    private let onEscape: @MainActor () -> Void
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    init(onEscape: @escaping @MainActor () -> Void) {
        self.onEscape = onEscape
    }

    deinit {
        stop()
    }

    @discardableResult
    func start() -> Bool {
        if eventTap != nil { return true }

        let eventMask = CGEventMask(1) << CGEventType.keyDown.rawValue
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: Self.eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            TimbreLog.line(
                "Timbre Escape: could not create active event tap; Accessibility may not be available yet."
            )
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) else {
            CFMachPortInvalidate(eventTap)
            TimbreLog.line("Timbre Escape: could not create event-tap run-loop source.")
            return false
        }

        self.eventTap = eventTap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        TimbreLog.line("Timbre Escape: interception enabled for active dictation.")
        return true
    }

    func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CFMachPortInvalidate(eventTap)
        }
        eventTap = nil
        runLoopSource = nil
    }

    static func shouldIntercept(
        eventType: CGEventType,
        keyCode: Int64
    ) -> Bool {
        eventType == .keyDown && keyCode == escapeKeyCode
    }

    private static let eventTapCallback: CGEventTapCallBack = {
        _, eventType, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let interceptor = Unmanaged<EscapeKeyInterceptor>
            .fromOpaque(userInfo)
            .takeUnretainedValue()

        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            if let eventTap = interceptor.eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        guard shouldIntercept(
            eventType: eventType,
            keyCode: keyCode
        ) else {
            return Unmanaged.passUnretained(event)
        }

        // Event-tap callbacks installed on the main run loop execute on the main
        // thread. Scheduling onto MainActor keeps the callback ABI synchronous:
        // Escape is consumed immediately, then the session is cancelled.
        if !isRepeat {
            Task { @MainActor in
                interceptor.onEscape()
            }
        }
        return nil
    }
}
