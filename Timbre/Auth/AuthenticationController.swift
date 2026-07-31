import AppKit
import AuthenticationServices
import Foundation

/// App-facing authentication state: sign-in, restore, refresh, `/api/me`, sign-out.
@MainActor
@Observable
final class AuthenticationController {
    private(set) var state: AuthenticationState = .signedOut

    var onStateDidChange: (() -> Void)?

    private let configuration: AuthConfiguration
    private let authService: any AuthenticationServicing
    private let apiClient: any TimbreAPIClienting
    private let credentialStore: any CredentialStoring
    private var credentials: OAuthCredentials?
    private var restoreTask: Task<Void, Never>?
    private var signInTask: Task<Void, Never>?
    private weak var presentationAnchorProvider: AuthenticationPresentationAnchorProviding?
    #if DEBUG
    /// Testing seam: lets the integration runtime plant a signed-in session
    /// without running the real Clerk/OAuth restore flow.
    private var debugSuppressSessionRestore = false
    #endif

    var isSignedIn: Bool { state.isSignedIn }
    var user: MeUser? { state.user }
    var isConfigured: Bool { configuration.isConfigured }

    init(
        configuration: AuthConfiguration = .load(),
        authService: (any AuthenticationServicing)? = nil,
        apiClient: (any TimbreAPIClienting)? = nil,
        credentialStore: any CredentialStoring = KeychainCredentialStore(),
        presentationAnchorProvider: AuthenticationPresentationAnchorProviding? = nil
    ) {
        self.configuration = configuration
        self.authService = authService ?? AuthenticationService(configuration: configuration)
        self.apiClient = apiClient ?? TimbreAPIClient(baseURL: configuration.apiBaseURL)
        self.credentialStore = credentialStore
        self.presentationAnchorProvider = presentationAnchorProvider
    }

    func setPresentationAnchorProvider(_ provider: AuthenticationPresentationAnchorProviding?) {
        presentationAnchorProvider = provider
    }

    func start() {
        restoreTask?.cancel()
        restoreTask = Task { [weak self] in
            await self?.restoreSession()
        }
    }

    func signIn() {
        guard !state.isSigningIn else { return }
        signInTask?.cancel()
        authService.cancelSignIn()

        apply(.signingIn)
        signInTask = Task { [weak self] in
            await self?.performSignIn()
        }
    }

    /// Cancels an in-flight browser session without clearing saved credentials.
    func cancelSignIn() {
        guard state.isSigningIn else { return }
        signInTask?.cancel()
        authService.cancelSignIn()
        if credentials != nil {
            restoreTask?.cancel()
            restoreTask = Task { [weak self] in
                await self?.refreshProfileUsingStoredCredentials()
            }
        } else {
            apply(.signedOut)
            TimbreLog.line("Timbre auth: sign-in cancelled")
        }
    }

    func signOut() {
        signInTask?.cancel()
        restoreTask?.cancel()
        authService.cancelSignIn()
        credentials = nil
        do {
            try credentialStore.clearCredentials()
        } catch {
            TimbreLog.line("Timbre auth: failed to clear Keychain credentials")
        }
        apply(.signedOut)
        TimbreLog.line("Timbre auth: signed out")
    }

    func retry() {
        switch state {
        case .error where credentials != nil:
            apply(.signingIn)
            restoreTask?.cancel()
            restoreTask = Task { [weak self] in
                await self?.refreshProfileUsingStoredCredentials()
            }
        case .error, .signedOut:
            signIn()
        case .signingIn, .signedIn:
            break
        }
    }

    func authenticationDidChange() {
        // Hook for observers that need an explicit ping beyond @Observable.
        onStateDidChange?()
    }

    // MARK: - Private

    #if DEBUG
    /// Internal testing seam used by the integration runtime. Plants a signed-in
    /// account so onboarding can render its signed-in branches without a real
    /// Clerk session, and prevents `start()` from clobbering it.
    func _testApplySignedInState(user: MeUser) {
        debugSuppressSessionRestore = true
        credentials = nil
        apply(.signedIn(user))
    }
    #endif

    private func apply(_ newState: AuthenticationState) {
        state = newState
        onStateDidChange?()
    }

    private func restoreSession() async {
        #if DEBUG
        if debugSuppressSessionRestore {
            return
        }
        #endif

        guard configuration.isConfigured else {
            apply(.signedOut)
            return
        }

        let stored: OAuthCredentials?
        do {
            stored = try credentialStore.loadCredentials()
        } catch {
            TimbreLog.line("Timbre auth: Keychain load failed")
            apply(.signedOut)
            return
        }

        guard let stored else {
            apply(.signedOut)
            return
        }

        credentials = stored
        apply(.signingIn)
        await refreshProfileUsingStoredCredentials()
    }

    private func performSignIn() async {
        guard configuration.isConfigured else {
            apply(.error(AuthenticationError.notConfigured.localizedDescription))
            return
        }

        let anchor = presentationAnchorProvider?.authenticationPresentationAnchor()
            ?? fallbackPresentationAnchor()

        do {
            let newCredentials = try await authService.signIn(presentationAnchor: anchor)
            try credentialStore.saveCredentials(newCredentials)
            credentials = newCredentials
            TimbreLog.line("Timbre auth: token exchange succeeded")
            let user = try await fetchMeWithRefresh()
            apply(.signedIn(user))
            TimbreLog.line("Timbre auth: signed in userId=\(user.userId)")
        } catch is CancellationError {
            apply(.signedOut)
        } catch let error as AuthenticationError where error == .cancelled {
            apply(.signedOut)
            TimbreLog.line("Timbre auth: sign-in cancelled")
        } catch {
            credentials = nil
            try? credentialStore.clearCredentials()
            apply(.error(Self.userFacingMessage(for: error)))
            TimbreLog.line("Timbre auth: sign-in failed")
        }
    }

    private func refreshProfileUsingStoredCredentials() async {
        do {
            let user = try await fetchMeWithRefresh()
            apply(.signedIn(user))
            TimbreLog.line("Timbre auth: session restored userId=\(user.userId)")
        } catch TimbreAPIError.unauthorized {
            credentials = nil
            try? credentialStore.clearCredentials()
            apply(.error(TimbreAPIError.unauthorized.localizedDescription))
            TimbreLog.line("Timbre auth: session unauthorized")
        } catch {
            apply(.error(Self.userFacingMessage(for: error)))
            TimbreLog.line("Timbre auth: session restore failed")
        }
    }

    private func fetchMeWithRefresh() async throws -> MeUser {
        guard var current = credentials else {
            throw TimbreAPIError.missingCredentials
        }

        if current.isAccessTokenExpired {
            current = try await refreshAndPersist(current)
        }

        do {
            return try await apiClient.fetchMe(accessToken: current.accessToken)
        } catch TimbreAPIError.unauthorized {
            current = try await refreshAndPersist(current)
            return try await apiClient.fetchMe(accessToken: current.accessToken)
        }
    }

    private func refreshAndPersist(_ current: OAuthCredentials) async throws -> OAuthCredentials {
        do {
            let refreshed = try await authService.refreshCredentials(current)
            try credentialStore.saveCredentials(refreshed)
            credentials = refreshed
            TimbreLog.line("Timbre auth: access token refreshed")
            return refreshed
        } catch {
            throw AuthenticationError.refreshFailed(nil)
        }
    }

    private func fallbackPresentationAnchor() -> ASPresentationAnchor {
        if let key = NSApp.keyWindow {
            return key
        }
        if let first = NSApp.windows.first(where: \.isVisible) {
            return first
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private static func userFacingMessage(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return "Something went wrong while signing in. Try again."
    }
}

@MainActor
protocol AuthenticationPresentationAnchorProviding: AnyObject {
    func authenticationPresentationAnchor() -> ASPresentationAnchor
}

/// Narrow status surface for setup policy without depending on full controller APIs.
@MainActor
protocol AuthenticationStatusProviding: AnyObject {
    var isSignedIn: Bool { get }
}

extension AuthenticationController: AuthenticationStatusProviding {}
