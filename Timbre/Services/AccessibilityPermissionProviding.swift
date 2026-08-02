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

    /// Offers/registers the current executable when not trusted and records that
    /// an offer was made. Called only from an explicit onboarding action.
    func requestAccessIfNeeded() async -> AccessibilityTrustState

    func openSystemSettings()
}

@MainActor
final class AccessibilityPermissionService: AccessibilityPermissionProviding {
    static let offeredPromptKey = "timbre.hasOfferedAccessibilityPrompt"

    private let defaults: UserDefaults
    private let isProcessTrusted: () -> Bool
    private let requestSystemPrompt: () -> Void

    init(
        defaults: UserDefaults = .standard,
        isProcessTrusted: @escaping () -> Bool = {
            let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            let options = [promptKey: false] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        },
        requestSystemPrompt: @escaping () -> Void = {
            let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            let options = [promptKey: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
    ) {
        self.defaults = defaults
        self.isProcessTrusted = isProcessTrusted
        self.requestSystemPrompt = requestSystemPrompt
    }

    var trustState: AccessibilityTrustState {
        isProcessTrusted() ? .trusted : .notTrusted
    }

    var hasOfferedPrompt: Bool {
        defaults.bool(forKey: Self.offeredPromptKey)
    }

    func requestAccessIfNeeded() async -> AccessibilityTrustState {
        if trustState == .trusted {
            return .trusted
        }

        // This method is only reached from an explicit onboarding action.
        // Invoke the system API every time so removing a stale/incorrect TCC
        // row and pressing Try Again re-registers this exact executable.
        defaults.set(true, forKey: Self.offeredPromptKey)
        requestSystemPrompt()

        return trustState
    }

    func openSystemSettings() {
        let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
