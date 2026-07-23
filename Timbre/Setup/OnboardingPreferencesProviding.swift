import Foundation

/// Onboarding presentation preferences. Never proof of model install or permission trust.
@MainActor
protocol OnboardingPreferencesProviding: AnyObject {
    var completedWelcome: Bool { get set }
    var dismissedReady: Bool { get set }
    var completedShortcutOnboarding: Bool { get set }
}

@MainActor
final class UserDefaultsOnboardingPreferences: OnboardingPreferencesProviding {
    static let completedWelcomeKey = "timbre.hasCompletedSetupWelcome"
    static let dismissedReadyKey = "timbre.hasDismissedSetupReady"
    static let completedShortcutOnboardingKey = "timbre.hasCompletedShortcutOnboarding"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var completedWelcome: Bool {
        get { defaults.bool(forKey: Self.completedWelcomeKey) }
        set { defaults.set(newValue, forKey: Self.completedWelcomeKey) }
    }

    var dismissedReady: Bool {
        get { defaults.bool(forKey: Self.dismissedReadyKey) }
        set { defaults.set(newValue, forKey: Self.dismissedReadyKey) }
    }

    var completedShortcutOnboarding: Bool {
        get { defaults.bool(forKey: Self.completedShortcutOnboardingKey) }
        set { defaults.set(newValue, forKey: Self.completedShortcutOnboardingKey) }
    }
}
