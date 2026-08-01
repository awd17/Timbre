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
    private var authenticationOperationID = UUID()
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
        invalidateCurrentOperation()
        authService.cancelSignIn()
        let operationID = beginOperation()
        restoreTask = Task { [weak self] in
            await self?.restoreSession(operationID: operationID)
        }
    }

    func signIn() {
        guard !state.isSigningIn else { return }
        invalidateCurrentOperation()
        authService.cancelSignIn()

        let operationID = beginOperation()
        apply(.signingIn)
        signInTask = Task { [weak self] in
            await self?.performSignIn(operationID: operationID)
        }
    }

    /// Cancels an in-flight browser session without clearing saved credentials.
    func cancelSignIn() {
        guard state.isSigningIn else { return }
        let shouldRestoreStoredCredentials = credentials != nil
        invalidateCurrentOperation()
        authService.cancelSignIn()
        let operationID = beginOperation()
        if shouldRestoreStoredCredentials {
            apply(.signingIn)
            restoreTask = Task { [weak self] in
                await self?.refreshProfileUsingStoredCredentials(operationID: operationID)
            }
        } else {
            credentials = nil
            apply(.signedOut)
            TimbreLog.line("Timbre auth: sign-in cancelled")
        }
    }

    func signOut() {
        invalidateCurrentOperation()
        authService.cancelSignIn()
        do {
            try credentialStore.clearCredentials()
        } catch {
            TimbreLog.line("Timbre auth: failed to clear Keychain credentials")
            return
        }
        credentials = nil
        apply(.signedOut)
        TimbreLog.line("Timbre auth: signed out")
    }

    func retry() {
        switch state {
        case .error where credentials != nil:
            invalidateCurrentOperation()
            let operationID = beginOperation()
            apply(.signingIn)
            restoreTask = Task { [weak self] in
                await self?.refreshProfileUsingStoredCredentials(operationID: operationID)
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

    private func restoreSession(operationID: UUID) async {
        guard isCurrent(operationID) else { return }

        #if DEBUG
        if debugSuppressSessionRestore {
            return
        }
        #endif

        guard configuration.isConfigured else {
            guard isCurrent(operationID) else { return }
            apply(.signedOut)
            return
        }

        let stored: OAuthCredentials?
        do {
            stored = try credentialStore.loadCredentials()
        } catch {
            guard isCurrent(operationID) else { return }
            TimbreLog.line(
                "Timbre auth: Keychain load failed (\(error.localizedDescription))"
            )
            apply(.signedOut)
            return
        }

        guard isCurrent(operationID) else { return }
        guard let stored else {
            apply(.signedOut)
            return
        }

        credentials = stored
        apply(.signingIn)
        await refreshProfileUsingStoredCredentials(operationID: operationID)
    }

    private func performSignIn(operationID: UUID) async {
        guard isCurrent(operationID) else { return }

        guard configuration.isConfigured else {
            guard isCurrent(operationID) else { return }
            apply(.error(AuthenticationError.notConfigured.localizedDescription))
            return
        }

        let anchor = presentationAnchorProvider?.authenticationPresentationAnchor()
            ?? fallbackPresentationAnchor()

        do {
            let newCredentials = try await authService.signIn(presentationAnchor: anchor)
            guard isCurrent(operationID) else { return }
            try credentialStore.saveCredentials(newCredentials)
            guard isCurrent(operationID) else { return }
            credentials = newCredentials
            TimbreLog.line("Timbre auth: token exchange succeeded")
            let user = try await fetchMeWithRefresh(operationID: operationID)
            guard isCurrent(operationID) else { return }
            apply(.signedIn(user))
            TimbreLog.line("Timbre auth: signed in userId=\(user.userId)")
        } catch is CancellationError {
            guard isCurrent(operationID) else { return }
            apply(.signedOut)
        } catch let error as AuthenticationError where error == .cancelled {
            guard isCurrent(operationID) else { return }
            apply(.signedOut)
            TimbreLog.line("Timbre auth: sign-in cancelled")
        } catch {
            guard isCurrent(operationID) else { return }
            credentials = nil
            try? credentialStore.clearCredentials()
            apply(.error(Self.userFacingMessage(for: error)))
            TimbreLog.line(
                "Timbre auth: sign-in failed (\(error.localizedDescription))"
            )
        }
    }

    private func refreshProfileUsingStoredCredentials(operationID: UUID) async {
        guard isCurrent(operationID) else { return }

        do {
            let user = try await fetchMeWithRefresh(operationID: operationID)
            guard isCurrent(operationID) else { return }
            apply(.signedIn(user))
            TimbreLog.line("Timbre auth: session restored userId=\(user.userId)")
        } catch TimbreAPIError.unauthorized {
            guard isCurrent(operationID) else { return }
            credentials = nil
            try? credentialStore.clearCredentials()
            apply(.error(TimbreAPIError.unauthorized.localizedDescription))
            TimbreLog.line("Timbre auth: session unauthorized")
        } catch {
            guard isCurrent(operationID) else { return }
            apply(.error(Self.userFacingMessage(for: error)))
            TimbreLog.line(
                "Timbre auth: session restore failed (\(error.localizedDescription))"
            )
        }
    }

    private func fetchMeWithRefresh(operationID: UUID) async throws -> MeUser {
        guard isCurrent(operationID) else { throw CancellationError() }
        guard var current = credentials else {
            throw TimbreAPIError.missingCredentials
        }

        if current.isAccessTokenExpired {
            current = try await refreshAndPersist(current, operationID: operationID)
            guard isCurrent(operationID) else { throw CancellationError() }
        }

        do {
            let user = try await apiClient.fetchMe(accessToken: current.accessToken)
            guard isCurrent(operationID) else { throw CancellationError() }
            return user
        } catch TimbreAPIError.unauthorized {
            guard isCurrent(operationID) else { throw CancellationError() }
            current = try await refreshAndPersist(current, operationID: operationID)
            guard isCurrent(operationID) else { throw CancellationError() }
            let user = try await apiClient.fetchMe(accessToken: current.accessToken)
            guard isCurrent(operationID) else { throw CancellationError() }
            return user
        }
    }

    private func refreshAndPersist(
        _ current: OAuthCredentials,
        operationID: UUID
    ) async throws -> OAuthCredentials {
        do {
            guard isCurrent(operationID) else { throw CancellationError() }
            let refreshed = try await authService.refreshCredentials(current)
            guard isCurrent(operationID) else { throw CancellationError() }
            try credentialStore.saveCredentials(refreshed)
            guard isCurrent(operationID) else { throw CancellationError() }
            credentials = refreshed
            TimbreLog.line("Timbre auth: access token refreshed")
            return refreshed
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AuthenticationError.refreshFailed(nil)
        }
    }

    private func invalidateCurrentOperation() {
        signInTask?.cancel()
        restoreTask?.cancel()
        signInTask = nil
        restoreTask = nil
        authenticationOperationID = UUID()
    }

    private func beginOperation() -> UUID {
        let operationID = UUID()
        authenticationOperationID = operationID
        return operationID
    }

    private func isCurrent(_ operationID: UUID) -> Bool {
        operationID == authenticationOperationID && !Task.isCancelled
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
