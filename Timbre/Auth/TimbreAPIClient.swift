import Foundation

enum TimbreAPIError: Error, Equatable, LocalizedError {
    case missingCredentials
    case unauthorized
    case networkFailure
    case invalidResponse
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "You need to sign in before Timbre can load your account."
        case .unauthorized:
            return "Your session is no longer valid. Sign in again."
        case .networkFailure:
            return "Could not reach the Timbre API. Check your network connection."
        case .invalidResponse:
            return "The Timbre API returned an unexpected response."
        case .httpStatus(let code):
            return "The Timbre API returned HTTP \(code)."
        }
    }
}

protocol TimbreAPIClienting: AnyObject {
    func fetchMe(accessToken: String) async throws -> MeUser
}

/// Minimal HTTPS client for Timbre Route Handlers.
final class TimbreAPIClient: TimbreAPIClienting, @unchecked Sendable {
    private let baseURL: URL
    private let session: URLSession

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    func fetchMe(accessToken: String) async throws -> MeUser {
        let url = baseURL.appendingPathComponent("api/me")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw TimbreAPIError.networkFailure
        }

        guard let http = response as? HTTPURLResponse else {
            throw TimbreAPIError.invalidResponse
        }

        switch http.statusCode {
        case 200:
            return try MeUserDecoder.decode(data)
        case 401:
            throw TimbreAPIError.unauthorized
        default:
            throw TimbreAPIError.httpStatus(http.statusCode)
        }
    }
}
