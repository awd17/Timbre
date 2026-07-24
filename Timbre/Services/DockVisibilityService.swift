import AppKit
import Combine
import Foundation

@MainActor
protocol ApplicationActivationPolicyApplying: AnyObject {
    @discardableResult
    func setActivationPolicy(_ policy: NSApplication.ActivationPolicy) -> Bool
    func activate()
}

@MainActor
final class NSApplicationActivationPolicyApplicator:
    ApplicationActivationPolicyApplying
{
    private let application: NSApplication

    init(application: NSApplication? = nil) {
        self.application = application ?? .shared
    }

    func setActivationPolicy(_ policy: NSApplication.ActivationPolicy) -> Bool {
        application.setActivationPolicy(policy)
    }

    func activate() {
        application.activate(ignoringOtherApps: true)
    }
}

@MainActor
protocol DockVisibilityServicing: AnyObject {
    @discardableResult
    func apply(_ policy: NSApplication.ActivationPolicy) -> Bool
    func activate()
}

@MainActor
final class DockVisibilityService: DockVisibilityServicing {
    private let applicator: any ApplicationActivationPolicyApplying

    init(
        applicator: (any ApplicationActivationPolicyApplying)? = nil
    ) {
        self.applicator = applicator ?? NSApplicationActivationPolicyApplicator()
    }

    func apply(_ policy: NSApplication.ActivationPolicy) -> Bool {
        applicator.setActivationPolicy(policy)
    }

    func activate() {
        applicator.activate()
    }
}

enum TemporaryApplicationPresentationReason: Hashable {
    case onboarding
    case settingsWindow
    case debugWindow
}

@MainActor
final class DockVisibilityCoordinator {
    private let preferences: any AppPreferencesProviding
    private let service: any DockVisibilityServicing
    private var activeReasons: Set<TemporaryApplicationPresentationReason> = []
    private var lastAppliedPolicy: NSApplication.ActivationPolicy?
    private var preferenceObservation: AnyCancellable?

    init(
        preferences: any AppPreferencesProviding,
        service: (any DockVisibilityServicing)? = nil
    ) {
        self.preferences = preferences
        self.service = service ?? DockVisibilityService()
        preferenceObservation = preferences.changes
            .sink { [weak self] change in
                guard case .showInDock = change else { return }
                self?.reconcile()
            }
    }

    var showsInDockByPreference: Bool {
        preferences.showInDock
    }

    func applyLaunchPolicy() {
        reconcile(force: true)
    }

    func beginTemporaryPresentation(_ reason: TemporaryApplicationPresentationReason) {
        let inserted = activeReasons.insert(reason).inserted
        if inserted {
            reconcile()
        }
    }

    func endTemporaryPresentation(_ reason: TemporaryApplicationPresentationReason) {
        guard activeReasons.remove(reason) != nil else { return }
        reconcile()
    }

    func activate() {
        service.activate()
    }

    private func reconcile(force: Bool = false) {
        let policy: NSApplication.ActivationPolicy =
            preferences.showInDock || !activeReasons.isEmpty ? .regular : .accessory
        guard force || policy != lastAppliedPolicy else { return }

        if service.apply(policy) {
            lastAppliedPolicy = policy
            TimbreLog.line(
                "Timbre activation: \(policy == .regular ? "regular" : "accessory")"
            )
        } else {
            lastAppliedPolicy = nil
            TimbreLog.line("Timbre activation: policy change failed")
        }
    }
}
