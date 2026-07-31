import Foundation

/// Non-secret OAuth and API endpoints loaded from the app bundle Info.plist.
struct AuthConfiguration: Equatable, Sendable {
    let clerkOAuthClientID: String
    let authorizationURL: URL
    let tokenURL: URL
    let apiBaseURL: URL
    let callbackScheme: String
    let redirectURI: String
    let scopes: String

    static let defaultScopes = "openid profile email"

    var isConfigured: Bool {
        !clerkOAuthClientID.isEmpty
            && !clerkOAuthClientID.hasPrefix("YOUR_")
            && authorizationURL.scheme == "https"
            && tokenURL.scheme == "https"
            && (apiBaseURL.scheme == "https" || apiBaseURL.scheme == "http")
            && !callbackScheme.isEmpty
            && !redirectURI.isEmpty
    }

    static func load(from bundle: Bundle = .main) -> AuthConfiguration {
        let info = bundle.infoDictionary ?? [:]
        let clientID = string(info["CLERK_OAUTH_CLIENT_ID"])
        let authURLString = string(info["CLERK_AUTHORIZATION_URL"])
        let tokenURLString = string(info["CLERK_TOKEN_URL"])
        let apiBaseString = string(info["TIMBRE_API_BASE_URL"])
        let scheme = string(info["TIMBRE_AUTH_CALLBACK_SCHEME"], fallback: "timbre-auth")
        let redirect = string(
            info["TIMBRE_AUTH_REDIRECT_URI"],
            fallback: "\(scheme)://oauth/callback"
        )

        return AuthConfiguration(
            clerkOAuthClientID: clientID,
            authorizationURL: URL(string: authURLString) ?? URL(string: "https://invalid.invalid")!,
            tokenURL: URL(string: tokenURLString) ?? URL(string: "https://invalid.invalid")!,
            apiBaseURL: URL(string: apiBaseString) ?? URL(string: "https://invalid.invalid")!,
            callbackScheme: scheme,
            redirectURI: redirect,
            scopes: defaultScopes
        )
    }

    private static func string(_ value: Any?, fallback: String = "") -> String {
        guard let raw = value as? String else { return fallback }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "$(CLERK_OAUTH_CLIENT_ID)"
            || trimmed.hasPrefix("$(")
        {
            return fallback
        }
        return trimmed
    }
}
