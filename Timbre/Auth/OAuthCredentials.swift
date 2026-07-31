import Foundation

struct OAuthCredentials: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var tokenType: String
    var scope: String?

    var isAccessTokenExpired: Bool {
        // Refresh slightly early to avoid edge races with server clock.
        Date() >= expiresAt.addingTimeInterval(-60)
    }
}

struct OAuthTokenResponse: Decodable, Equatable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int?
    let tokenType: String
    let scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
        case scope
    }

    func makeCredentials(
        previousRefreshToken: String?,
        now: Date = Date()
    ) throws -> OAuthCredentials {
        let refresh = refreshToken ?? previousRefreshToken
        guard let refresh, !refresh.isEmpty else {
            throw AuthenticationError.invalidTokenResponse
        }
        let lifetime = TimeInterval(expiresIn ?? 86_400)
        return OAuthCredentials(
            accessToken: accessToken,
            refreshToken: refresh,
            expiresAt: now.addingTimeInterval(lifetime),
            tokenType: tokenType,
            scope: scope
        )
    }
}
