import Foundation

enum AuthenticationError: Error, Equatable, LocalizedError {
    case notConfigured
    case cancelled
    case invalidTokenResponse
    case tokenExchangeFailed(String?)
    case refreshFailed(String?)
    case missingCredentials
    case sessionPresentationFailed

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Sign-in is not configured. Add Clerk OAuth settings in Config/Auth.local.xcconfig."
        case .cancelled:
            return "Sign-in was cancelled."
        case .invalidTokenResponse:
            return "The token response from Clerk was invalid."
        case .tokenExchangeFailed(let detail):
            return detail.map { "Could not complete sign-in: \($0)" }
                ?? "Could not complete sign-in."
        case .refreshFailed(let detail):
            return detail.map { "Could not refresh your session: \($0)" }
                ?? "Could not refresh your session."
        case .missingCredentials:
            return "No saved sign-in credentials were found."
        case .sessionPresentationFailed:
            return "Could not open the browser sign-in window."
        }
    }
}
