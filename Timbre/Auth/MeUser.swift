import Foundation

struct MeUser: Codable, Equatable, Sendable, Identifiable {
    let userId: String
    let email: String?
    let firstName: String?
    let lastName: String?

    var id: String { userId }

    var displayName: String {
        let parts = [firstName, lastName].compactMap { name -> String? in
            guard let name, !name.isEmpty else { return nil }
            return name
        }
        if !parts.isEmpty {
            return parts.joined(separator: " ")
        }
        if let email, !email.isEmpty {
            return email
        }
        return userId
    }
}

enum MeUserDecoder {
    static func decode(_ data: Data) throws -> MeUser {
        let decoder = JSONDecoder()
        if let user = try? decoder.decode(MeUser.self, from: data) {
            return user
        }
        throw TimbreAPIError.invalidResponse
    }
}
