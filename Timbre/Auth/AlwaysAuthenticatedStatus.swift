import Foundation

/// Setup-only auth stub for automated integration runs that do not exercise Clerk.
@MainActor
final class AlwaysAuthenticatedStatus: AuthenticationStatusProviding {
    let isSignedIn = true
}
