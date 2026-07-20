import AppKit
import ApplicationServices
import Foundation

enum AccessibilityTrustState: Equatable {
    case trusted
    case notTrusted
}

@MainActor
protocol AccessibilityPermissionProviding: AnyObject {
    /// Live system trust. Always the source of truth for readiness and paste gating.
    var trustState: AccessibilityTrustState { get }

    /// Timbre-local UX only: whether we have already offered/requested access.
    /// Never treat as proof of denial or of readiness.
    var hasOfferedPrompt: Bool { get }

    /// Offers the system prompt when not trusted and not yet offered; records that an offer was made.
    /// Does not re-prompt aggressively after an offer while still notTrusted.
    func requestAccessIfNeeded() async -> AccessibilityTrustState

    func openSystemSettings()
}

@MainActor
final class AccessibilityPermissionService: AccessibilityPermissionProviding {
    static let offeredPromptKey = "timbre.hasOfferedAccessibilityPrompt"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var trustState: AccessibilityTrustState {
        AXIsProcessTrusted() ? .trusted : .notTrusted
    }

    var hasOfferedPrompt: Bool {
        defaults.bool(forKey: Self.offeredPromptKey)
    }

    func requestAccessIfNeeded() async -> AccessibilityTrustState {
        if trustState == .trusted {
            return .trusted
        }

        if !hasOfferedPrompt {
            defaults.set(true, forKey: Self.offeredPromptKey)
            let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            let options = [promptKey: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }

        return trustState
    }

    func openSystemSettings() {
        let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
