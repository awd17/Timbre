import Foundation

enum OAuthCallbackError: Error, Equatable, LocalizedError {
    case missingCode
    case missingState
    case stateMismatch
    case authorizationDenied(String?)
    case unexpectedCallback

    var errorDescription: String? {
        switch self {
        case .missingCode:
            return "The sign-in response did not include an authorization code."
        case .missingState:
            return "The sign-in response did not include a state value."
        case .stateMismatch:
            return "The sign-in response failed state validation."
        case .authorizationDenied(let detail):
            if let detail, !detail.isEmpty {
                return "Sign-in was denied: \(detail)"
            }
            return "Sign-in was denied."
        case .unexpectedCallback:
            return "Received an unexpected sign-in callback."
        }
    }
}

struct OAuthAuthorizationCodeResponse: Equatable {
    let code: String
    let state: String
}

enum OAuthCallbackParser {
    static func parse(
        callbackURL: URL,
        expectedState: String
    ) throws -> OAuthAuthorizationCodeResponse {
        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            throw OAuthCallbackError.unexpectedCallback
        }

        let items = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item -> (String, String)? in
                guard let value = item.value else { return nil }
                return (item.name, value)
            }
        )

        if let error = items["error"] {
            throw OAuthCallbackError.authorizationDenied(items["error_description"] ?? error)
        }

        guard let state = items["state"], !state.isEmpty else {
            throw OAuthCallbackError.missingState
        }
        guard state == expectedState else {
            throw OAuthCallbackError.stateMismatch
        }
        guard let code = items["code"], !code.isEmpty else {
            throw OAuthCallbackError.missingCode
        }

        return OAuthAuthorizationCodeResponse(code: code, state: state)
    }
}
