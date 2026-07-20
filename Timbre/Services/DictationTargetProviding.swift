import AppKit
import Foundation

@MainActor
protocol DictationTargetProviding: AnyObject {
    /// Intended external target at Start. Never returns Timbre.
    func captureTarget() -> DictationTargetContext?

    /// Current frontmost app if it is not Timbre; nil when Timbre is frontmost or none.
    func frontmostExternalTarget() -> DictationTargetContext?

    /// True when Timbre itself is the frontmost application.
    var isSelfFrontmost: Bool { get }

    /// Activates the captured target. Returns true when frontmost matches afterward.
    func activateTarget(_ target: DictationTargetContext) -> Bool
}

/// Tracks the last activated non-Timbre application.
///
/// MenuBarExtra with `.window` style makes Timbre frontmost when the user opens the
/// menu and taps Start. Activation tracking preserves the intended external target.
/// Observers are removed on deinit.
@MainActor
final class FrontmostApplicationTracker: DictationTargetProviding {
    private let workspace: NSWorkspace
    private let selfBundleIdentifier: String?
    private let notificationCenter: NotificationCenter

    private var lastExternalProcessIdentifier: pid_t?
    private var lastExternalBundleIdentifier: String?
    private var lastExternalLocalizedName: String?
    private var observer: NSObjectProtocol?

    init(
        workspace: NSWorkspace = .shared,
        selfBundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) {
        self.workspace = workspace
        self.selfBundleIdentifier = selfBundleIdentifier
        self.notificationCenter = workspace.notificationCenter
        seedFromFrontmost()
        observer = notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: workspace,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                self?.handleActivation(notification)
            }
        }
    }

    deinit {
        if let observer {
            notificationCenter.removeObserver(observer)
        }
    }

    var isSelfFrontmost: Bool {
        guard let frontmost = workspace.frontmostApplication else { return false }
        return isSelf(frontmost)
    }

    func frontmostExternalTarget() -> DictationTargetContext? {
        guard let frontmost = workspace.frontmostApplication else { return nil }
        return context(from: frontmost)
    }

    func activateTarget(_ target: DictationTargetContext) -> Bool {
        guard let running = NSRunningApplication(processIdentifier: target.processIdentifier),
              !running.isTerminated,
              matches(target, running: running),
              running.activate(options: [.activateIgnoringOtherApps]),
              let frontmost = workspace.frontmostApplication
        else {
            return false
        }
        return matches(target, running: frontmost)
    }

    func captureTarget() -> DictationTargetContext? {
        if let frontmost = frontmostExternalTarget() {
            remember(frontmost)
            return frontmost
        }
        return lastExternalContext()
    }

    private func seedFromFrontmost() {
        if let frontmost = frontmostExternalTarget() {
            remember(frontmost)
        }
    }

    private func handleActivation(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
            as? NSRunningApplication
        else {
            return
        }
        if let context = context(from: app) {
            remember(context)
        }
    }

    private func remember(_ context: DictationTargetContext) {
        lastExternalProcessIdentifier = context.processIdentifier
        lastExternalBundleIdentifier = context.bundleIdentifier
        lastExternalLocalizedName = context.localizedName
    }

    private func lastExternalContext() -> DictationTargetContext? {
        guard let pid = lastExternalProcessIdentifier else { return nil }
        if let running = NSRunningApplication(processIdentifier: pid), !running.isTerminated {
            if let expectedBundle = lastExternalBundleIdentifier {
                guard running.bundleIdentifier == expectedBundle else { return nil }
            }
            return DictationTargetContext(
                processIdentifier: running.processIdentifier,
                bundleIdentifier: running.bundleIdentifier ?? lastExternalBundleIdentifier,
                localizedName: running.localizedName ?? lastExternalLocalizedName
            )
        }
        return nil
    }

    private func context(from app: NSRunningApplication) -> DictationTargetContext? {
        guard !isSelf(app), !app.isTerminated else { return nil }
        return DictationTargetContext(
            processIdentifier: app.processIdentifier,
            bundleIdentifier: app.bundleIdentifier,
            localizedName: app.localizedName
        )
    }

    private func isSelf(_ app: NSRunningApplication) -> Bool {
        guard let selfBundleIdentifier, let bundle = app.bundleIdentifier else {
            return app == NSRunningApplication.current
        }
        return bundle == selfBundleIdentifier
    }

    private func matches(
        _ target: DictationTargetContext,
        running: NSRunningApplication
    ) -> Bool {
        guard running.processIdentifier == target.processIdentifier else { return false }
        if let expected = target.bundleIdentifier, let actual = running.bundleIdentifier {
            return expected == actual
        }
        return target.bundleIdentifier == nil
    }
}
