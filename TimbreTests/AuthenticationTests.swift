import AuthenticationServices
import Foundation
@testable import Timbre
import XCTest

final class PKCETests: XCTestCase {
    func testVerifierLengthAndAlphabet() {
        let verifier = PKCE.makeCodeVerifier()
        XCTAssertGreaterThanOrEqual(verifier.count, 43)
        XCTAssertLessThanOrEqual(verifier.count, 128)

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        XCTAssertTrue(verifier.unicodeScalars.allSatisfy { allowed.contains($0) })
    }

    func testChallengeIsDeterministicBase64URLSHA256() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let challenge = PKCE.makeCodeChallenge(for: verifier)
        // RFC 7636 appendix B
        XCTAssertEqual(challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertFalse(challenge.contains("+"))
        XCTAssertFalse(challenge.contains("/"))
        XCTAssertFalse(challenge.contains("="))
    }

    func testStateIsUnique() {
        let a = PKCE.makeState()
        let b = PKCE.makeState()
        XCTAssertNotEqual(a, b)
        XCTAssertFalse(a.isEmpty)
    }
}

final class OAuthCallbackParserTests: XCTestCase {
    func testParsesValidCallback() throws {
        let url = URL(string: "timbre-auth://oauth/callback?code=abc123&state=expected")!
        let parsed = try OAuthCallbackParser.parse(callbackURL: url, expectedState: "expected")
        XCTAssertEqual(parsed.code, "abc123")
        XCTAssertEqual(parsed.state, "expected")
    }

    func testRejectsStateMismatch() {
        let url = URL(string: "timbre-auth://oauth/callback?code=abc123&state=wrong")!
        XCTAssertThrowsError(
            try OAuthCallbackParser.parse(callbackURL: url, expectedState: "expected")
        ) { error in
            XCTAssertEqual(error as? OAuthCallbackError, .stateMismatch)
        }
    }

    func testRejectsMissingCode() {
        let url = URL(string: "timbre-auth://oauth/callback?state=expected")!
        XCTAssertThrowsError(
            try OAuthCallbackParser.parse(callbackURL: url, expectedState: "expected")
        ) { error in
            XCTAssertEqual(error as? OAuthCallbackError, .missingCode)
        }
    }

    func testMapsAuthorizationDenied() {
        let url = URL(
            string: "timbre-auth://oauth/callback?error=access_denied&error_description=Nope&state=expected"
        )!
        XCTAssertThrowsError(
            try OAuthCallbackParser.parse(callbackURL: url, expectedState: "expected")
        ) { error in
            XCTAssertEqual(
                error as? OAuthCallbackError,
                .authorizationDenied("Nope")
            )
        }
    }
}

final class MeUserDecoderTests: XCTestCase {
    func testDecodesAPIResponse() throws {
        let json = """
        {
          "userId": "user_123",
          "email": "a@example.com",
          "firstName": "Ada",
          "lastName": "Lovelace"
        }
        """.data(using: .utf8)!

        let user = try MeUserDecoder.decode(json)
        XCTAssertEqual(user.userId, "user_123")
        XCTAssertEqual(user.email, "a@example.com")
        XCTAssertEqual(user.displayName, "Ada Lovelace")
    }

    func testRejectsInvalidPayload() {
        let json = #"{"error":"Unauthorized"}"#.data(using: .utf8)!
        XCTAssertThrowsError(try MeUserDecoder.decode(json)) { error in
            XCTAssertEqual(error as? TimbreAPIError, .invalidResponse)
        }
    }
}

final class OAuthCredentialsTests: XCTestCase {
    func testTokenResponseBuildsCredentials() throws {
        let response = OAuthTokenResponse(
            accessToken: "access",
            refreshToken: "refresh",
            expiresIn: 3600,
            tokenType: "Bearer",
            scope: "openid profile email"
        )
        let now = Date()
        let credentials = try response.makeCredentials(previousRefreshToken: nil, now: now)
        XCTAssertEqual(credentials.accessToken, "access")
        XCTAssertEqual(credentials.refreshToken, "refresh")
        XCTAssertEqual(credentials.expiresAt.timeIntervalSince1970, now.addingTimeInterval(3600).timeIntervalSince1970, accuracy: 0.5)
        XCTAssertFalse(credentials.isAccessTokenExpired)
    }

    func testExpiredUsesSkew() {
        let credentials = OAuthCredentials(
            accessToken: "a",
            refreshToken: "r",
            expiresAt: Date().addingTimeInterval(30),
            tokenType: "Bearer",
            scope: nil
        )
        XCTAssertTrue(credentials.isAccessTokenExpired)
    }

    func testRefreshCanReusePreviousRefreshToken() throws {
        let response = OAuthTokenResponse(
            accessToken: "new-access",
            refreshToken: nil,
            expiresIn: 60,
            tokenType: "Bearer",
            scope: nil
        )
        let credentials = try response.makeCredentials(previousRefreshToken: "old-refresh")
        XCTAssertEqual(credentials.refreshToken, "old-refresh")
    }
}

final class AuthenticationStateTests: XCTestCase {
    func testSignedInHelpers() {
        let user = MeUser(
            userId: "user_1",
            email: "a@example.com",
            firstName: "A",
            lastName: nil
        )
        let state = AuthenticationState.signedIn(user)
        XCTAssertTrue(state.isSignedIn)
        XCTAssertEqual(state.user?.userId, "user_1")
        XCTAssertNil(state.errorMessage)
        XCTAssertFalse(state.isSigningIn)
    }

    func testErrorHelpers() {
        let state = AuthenticationState.error("Nope")
        XCTAssertFalse(state.isSignedIn)
        XCTAssertEqual(state.errorMessage, "Nope")
    }
}

final class InMemoryCredentialStore: CredentialStoring {
    private var credentials: OAuthCredentials?
    var clearError: Error?

    func loadCredentials() throws -> OAuthCredentials? { credentials }

    func saveCredentials(_ credentials: OAuthCredentials) throws {
        self.credentials = credentials
    }

    func clearCredentials() throws {
        if let clearError { throw clearError }
        credentials = nil
    }
}

@MainActor
final class FakeAuthenticationService: AuthenticationServicing {
    var credentialsToReturn: OAuthCredentials?
    var refreshCredentialsToReturn: OAuthCredentials?
    var errorToThrow: Error?
    var cancelCount = 0
    var signInCount = 0

    func signIn(presentationAnchor: ASPresentationAnchor) async throws -> OAuthCredentials {
        signInCount += 1
        if let errorToThrow { throw errorToThrow }
        guard let credentialsToReturn else {
            throw AuthenticationError.invalidTokenResponse
        }
        return credentialsToReturn
    }

    func refreshCredentials(_ credentials: OAuthCredentials) async throws -> OAuthCredentials {
        if let errorToThrow { throw errorToThrow }
        return refreshCredentialsToReturn ?? credentials
    }

    func cancelSignIn() {
        cancelCount += 1
    }
}

@MainActor
final class FakeTimbreAPIClient: TimbreAPIClienting {
    var user: MeUser?
    var error: Error?
    var fetchCount = 0
    var lastAccessToken: String?

    func fetchMe(accessToken: String) async throws -> MeUser {
        fetchCount += 1
        lastAccessToken = accessToken
        if let error { throw error }
        guard let user else { throw TimbreAPIError.invalidResponse }
        return user
    }
}

@MainActor
final class SuspendingAuthenticationService: AuthenticationServicing {
    var credentialsToReturn: OAuthCredentials?
    var signInStarted = false
    var signInFinished = false
    var cancelCount = 0
    private var signInContinuation: CheckedContinuation<OAuthCredentials, Error>?

    func signIn(presentationAnchor: ASPresentationAnchor) async throws -> OAuthCredentials {
        signInStarted = true
        let credentials = try await withCheckedThrowingContinuation { continuation in
            signInContinuation = continuation
        }
        signInFinished = true
        return credentials
    }

    func refreshCredentials(_ credentials: OAuthCredentials) async throws -> OAuthCredentials {
        credentials
    }

    func cancelSignIn() {
        cancelCount += 1
    }

    func resumeSignIn() {
        guard let credentialsToReturn else { return }
        signInContinuation?.resume(returning: credentialsToReturn)
        signInContinuation = nil
    }
}

@MainActor
final class SuspendingTimbreAPIClient: TimbreAPIClienting {
    var fetchStarted = false
    var fetchFinished = false
    private var fetchContinuation: CheckedContinuation<MeUser, Error>?

    func fetchMe(accessToken: String) async throws -> MeUser {
        fetchStarted = true
        let user = try await withCheckedThrowingContinuation { continuation in
            fetchContinuation = continuation
        }
        fetchFinished = true
        return user
    }

    func resumeFetch(with user: MeUser) {
        fetchContinuation?.resume(returning: user)
        fetchContinuation = nil
    }
}

@MainActor
final class AuthenticationControllerTests: XCTestCase {
    private func makeConfiguration() -> AuthConfiguration {
        AuthConfiguration(
            clerkOAuthClientID: "client",
            authorizationURL: URL(string: "https://example.clerk.accounts.dev/oauth/authorize")!,
            tokenURL: URL(string: "https://example.clerk.accounts.dev/oauth/token")!,
            apiBaseURL: URL(string: "https://example.com")!,
            callbackScheme: "timbre-auth",
            redirectURI: "timbre-auth://oauth/callback",
            scopes: AuthConfiguration.defaultScopes
        )
    }

    func testSignOutClearsCredentialsAndState() async throws {
        let store = InMemoryCredentialStore()
        let service = FakeAuthenticationService()
        let api = FakeTimbreAPIClient()
        let user = MeUser(userId: "u1", email: "a@example.com", firstName: "A", lastName: nil)
        let credentials = OAuthCredentials(
            accessToken: "access",
            refreshToken: "refresh",
            expiresAt: Date().addingTimeInterval(3_600),
            tokenType: "Bearer",
            scope: nil
        )
        service.credentialsToReturn = credentials
        api.user = user

        let controller = AuthenticationController(
            configuration: makeConfiguration(),
            authService: service,
            apiClient: api,
            credentialStore: store
        )

        controller.signIn()
        await waitUntil {
            if case .signedIn = controller.state { return true }
            return false
        }
        XCTAssertNotNil(try store.loadCredentials())

        controller.signOut()
        XCTAssertEqual(controller.state, .signedOut)
        XCTAssertNil(try store.loadCredentials())
        XCTAssertEqual(service.cancelCount, 2) // once before sign-in, once on sign-out
    }

    func testSignOutFailureKeepsTheExistingSessionActive() async throws {
        let store = InMemoryCredentialStore()
        let service = FakeAuthenticationService()
        let api = FakeTimbreAPIClient()
        let user = MeUser(userId: "u1", email: "a@example.com", firstName: "A", lastName: nil)
        let credentials = OAuthCredentials(
            accessToken: "access",
            refreshToken: "refresh",
            expiresAt: Date().addingTimeInterval(3_600),
            tokenType: "Bearer",
            scope: nil
        )
        service.credentialsToReturn = credentials
        api.user = user
        let controller = AuthenticationController(
            configuration: makeConfiguration(),
            authService: service,
            apiClient: api,
            credentialStore: store
        )

        controller.signIn()
        await waitUntil {
            if case .signedIn = controller.state { return true }
            return false
        }

        store.clearError = NSError(domain: "AuthenticationTests", code: 1)
        controller.signOut()

        XCTAssertEqual(controller.state, .signedIn(user))
        XCTAssertNotNil(try store.loadCredentials())
    }

    func testSignOutInvalidatesAStaleSignInCompletion() async throws {
        let store = InMemoryCredentialStore()
        let service = SuspendingAuthenticationService()
        let api = SuspendingTimbreAPIClient()
        let user = MeUser(userId: "u1", email: "a@example.com", firstName: "A", lastName: nil)
        let credentials = OAuthCredentials(
            accessToken: "access",
            refreshToken: "refresh",
            expiresAt: Date().addingTimeInterval(3_600),
            tokenType: "Bearer",
            scope: nil
        )
        service.credentialsToReturn = credentials
        let controller = AuthenticationController(
            configuration: makeConfiguration(),
            authService: service,
            apiClient: api,
            credentialStore: store
        )

        controller.signIn()
        await waitUntil { service.signInStarted }
        service.resumeSignIn()
        await waitUntil { api.fetchStarted }

        controller.signOut()
        api.resumeFetch(with: user)
        await waitUntil { api.fetchFinished }

        XCTAssertEqual(controller.state, .signedOut)
        XCTAssertNil(try store.loadCredentials())
    }

    func testCancelSignInInvalidatesAStaleAuthenticationCompletion() async throws {
        let store = InMemoryCredentialStore()
        let service = SuspendingAuthenticationService()
        let api = FakeTimbreAPIClient()
        let user = MeUser(userId: "u1", email: "a@example.com", firstName: "A", lastName: nil)
        let credentials = OAuthCredentials(
            accessToken: "access",
            refreshToken: "refresh",
            expiresAt: Date().addingTimeInterval(3_600),
            tokenType: "Bearer",
            scope: nil
        )
        service.credentialsToReturn = credentials
        api.user = user
        let controller = AuthenticationController(
            configuration: makeConfiguration(),
            authService: service,
            apiClient: api,
            credentialStore: store
        )

        controller.signIn()
        await waitUntil { service.signInStarted }
        controller.cancelSignIn()
        service.resumeSignIn()
        await waitUntil { service.signInFinished }

        XCTAssertEqual(controller.state, .signedOut)
        XCTAssertNil(try store.loadCredentials())
        XCTAssertEqual(api.fetchCount, 0)
    }
}
