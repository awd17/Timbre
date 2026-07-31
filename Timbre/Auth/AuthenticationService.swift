import AppKit
import AuthenticationServices
import Foundation

protocol AuthenticationServicing: AnyObject {
    func signIn(presentationAnchor: ASPresentationAnchor) async throws -> OAuthCredentials
    func refreshCredentials(_ credentials: OAuthCredentials) async throws -> OAuthCredentials
    func cancelSignIn()
}

/// Clerk OAuth Authorization Code + PKCE using ASWebAuthenticationSession.
@MainActor
final class AuthenticationService: NSObject, AuthenticationServicing {
    private let configuration: AuthConfiguration
    private let urlSession: URLSession
    private var webAuthSession: ASWebAuthenticationSession?
    private var presentationContext: AuthenticationPresentationContext?
    private var pendingVerifier: String?
    private var pendingState: String?

    init(configuration: AuthConfiguration, urlSession: URLSession = .shared) {
        self.configuration = configuration
        self.urlSession = urlSession
    }

    func cancelSignIn() {
        webAuthSession?.cancel()
        webAuthSession = nil
        clearEphemeralOAuthState()
    }

    func signIn(presentationAnchor: ASPresentationAnchor) async throws -> OAuthCredentials {
        guard configuration.isConfigured else {
            throw AuthenticationError.notConfigured
        }

        cancelSignIn()

        let verifier = PKCE.makeCodeVerifier()
        let challenge = PKCE.makeCodeChallenge(for: verifier)
        let state = PKCE.makeState()
        pendingVerifier = verifier
        pendingState = state

        let authorizationURL = try makeAuthorizationURL(
            codeChallenge: challenge,
            state: state
        )

        do {
            let callbackURL = try await startWebAuthentication(
                url: authorizationURL,
                presentationAnchor: presentationAnchor
            )
            let parsed = try OAuthCallbackParser.parse(
                callbackURL: callbackURL,
                expectedState: state
            )
            let credentials = try await exchangeCode(parsed.code, codeVerifier: verifier)
            clearEphemeralOAuthState()
            return credentials
        } catch {
            clearEphemeralOAuthState()
            throw mapSessionError(error)
        }
    }

    func refreshCredentials(_ credentials: OAuthCredentials) async throws -> OAuthCredentials {
        guard configuration.isConfigured else {
            throw AuthenticationError.notConfigured
        }

        var request = URLRequest(url: configuration.tokenURL)
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = formBody([
            "grant_type": "refresh_token",
            "refresh_token": credentials.refreshToken,
            "client_id": configuration.clerkOAuthClientID,
        ])

        let response = try await performTokenRequest(request)
        return try response.makeCredentials(previousRefreshToken: credentials.refreshToken)
    }

    // MARK: - Private

    private func clearEphemeralOAuthState() {
        pendingVerifier = nil
        pendingState = nil
        presentationContext = nil
        webAuthSession = nil
    }

    private func makeAuthorizationURL(codeChallenge: String, state: String) throws -> URL {
        guard var components = URLComponents(
            url: configuration.authorizationURL,
            resolvingAgainstBaseURL: false
        ) else {
            throw AuthenticationError.notConfigured
        }

        components.queryItems = [
            URLQueryItem(name: "client_id", value: configuration.clerkOAuthClientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURI),
            URLQueryItem(name: "scope", value: configuration.scopes),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]

        guard let url = components.url else {
            throw AuthenticationError.notConfigured
        }
        return url
    }

    private func startWebAuthentication(
        url: URL,
        presentationAnchor: ASPresentationAnchor
    ) async throws -> URL {
        let context = AuthenticationPresentationContext(anchor: presentationAnchor)
        presentationContext = context

        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: configuration.callbackScheme
            ) { callbackURL, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let callbackURL else {
                    continuation.resume(throwing: AuthenticationError.cancelled)
                    return
                }
                continuation.resume(returning: callbackURL)
            }
            session.presentationContextProvider = context
            session.prefersEphemeralWebBrowserSession = false
            self.webAuthSession = session

            guard session.start() else {
                continuation.resume(throwing: AuthenticationError.sessionPresentationFailed)
                return
            }
        }
    }

    private func exchangeCode(_ code: String, codeVerifier: String) async throws -> OAuthCredentials {
        var request = URLRequest(url: configuration.tokenURL)
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = formBody([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": configuration.redirectURI,
            "client_id": configuration.clerkOAuthClientID,
            "code_verifier": codeVerifier,
        ])

        let response = try await performTokenRequest(request)
        return try response.makeCredentials(previousRefreshToken: nil)
    }

    private func performTokenRequest(_ request: URLRequest) async throws -> OAuthTokenResponse {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw AuthenticationError.tokenExchangeFailed("Network request failed.")
        }

        guard let http = response as? HTTPURLResponse else {
            throw AuthenticationError.invalidTokenResponse
        }

        guard (200 ... 299).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8)
                .flatMap { text -> String? in
                    // Avoid echoing raw token-shaped payloads; keep short server messages.
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty, trimmed.count < 200 else { return nil }
                    return trimmed
                }
            throw AuthenticationError.tokenExchangeFailed(detail)
        }

        do {
            return try JSONDecoder().decode(OAuthTokenResponse.self, from: data)
        } catch {
            throw AuthenticationError.invalidTokenResponse
        }
    }

    private func formBody(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+:&="))
        let encoded = fields.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }
        .joined(separator: "&")
        return Data(encoded.utf8)
    }

    private func mapSessionError(_ error: Error) -> Error {
        if let authError = error as? AuthenticationError {
            return authError
        }
        if let callbackError = error as? OAuthCallbackError {
            return callbackError
        }
        let nsError = error as NSError
        if nsError.domain == ASWebAuthenticationSessionError.errorDomain,
           nsError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue
        {
            return AuthenticationError.cancelled
        }
        return error
    }
}

private final class AuthenticationPresentationContext: NSObject,
    ASWebAuthenticationPresentationContextProviding
{
    private let anchor: ASPresentationAnchor

    init(anchor: ASPresentationAnchor) {
        self.anchor = anchor
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor
    }
}
