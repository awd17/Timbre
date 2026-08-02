import CoreGraphics
import Foundation

/// Temporarily owns Escape while a dictation session is active.
///
/// A global `NSEvent` monitor can observe Escape in another application, but it
/// cannot prevent that application from handling the same key press. An active
/// session event tap can consume the key-down instead. The tap is enabled only
/// for Preparing/Listening/Processing and stays disabled between sessions, so
/// Escape behaves normally everywhere else without paying setup cost each time.
final class EscapeKeyInterceptor {
    private static let escapeKeyCode: Int64 = 53

    private let onEscape: @MainActor () -> Void
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isActive = false

    init(onEscape: @escaping @MainActor () -> Void) {
        self.onEscape = onEscape
    }

    deinit {
        shutdown()
    }

    /// Create the event tap while the app is already doing setup work, but
    /// leave it disabled until dictation starts.
    @discardableResult
    func prepare() -> Bool {
        if eventTap != nil { return true }

        guard installEventTap() else { return false }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        TimbreLog.line("Timbre Escape: interception prepared.")
        return true
    }

    @discardableResult
    func start() -> Bool {
        guard prepare(), let eventTap else { return false }
        isActive = true
        CGEvent.tapEnable(tap: eventTap, enable: true)
        TimbreLog.line("Timbre Escape: interception enabled for active dictation.")
        return true
    }

    /// Disable interception while retaining the expensive event-tap setup for
    /// the next session.
    func stop() {
        isActive = false
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
    }

    func shutdown() {
        stop()
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CFMachPortInvalidate(eventTap)
        }
        eventTap = nil
        runLoopSource = nil
    }

    private func installEventTap() -> Bool {

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
        return true
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
            if interceptor.isActive, let eventTap = interceptor.eventTap {
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
