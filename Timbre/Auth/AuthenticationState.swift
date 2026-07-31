import Foundation

enum AuthenticationState: Equatable {
    case signedOut
    case signingIn
    case signedIn(MeUser)
    case error(String)

    var isSignedIn: Bool {
        if case .signedIn = self { return true }
        return false
    }

    var user: MeUser? {
        if case .signedIn(let user) = self { return user }
        return nil
    }

    var errorMessage: String? {
        if case .error(let message) = self { return message }
        return nil
    }

    var isSigningIn: Bool {
        if case .signingIn = self { return true }
        return false
    }
}
