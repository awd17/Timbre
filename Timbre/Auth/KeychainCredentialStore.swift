import Foundation
import Security

protocol CredentialStoring {
    func loadCredentials() throws -> OAuthCredentials?
    func saveCredentials(_ credentials: OAuthCredentials) throws
    func clearCredentials() throws
}

enum KeychainCredentialStoreError: Error, Equatable, LocalizedError {
    case unexpectedStatus(OSStatus)
    case encodingFailed
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            return "Keychain error (\(status))."
        case .encodingFailed:
            return "Could not encode credentials for Keychain storage."
        case .decodingFailed:
            return "Could not decode credentials from Keychain."
        }
    }
}

/// Stores OAuth tokens in the macOS Keychain. Never logs token values.
struct KeychainCredentialStore: CredentialStoring {
    let service: String
    let account: String

    init(
        service: String = "com.augustdrakton.Timbre.oauth",
        account: String = "clerk-oauth-credentials"
    ) {
        self.service = service
        self.account = account
    }

    func loadCredentials() throws -> OAuthCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                throw KeychainCredentialStoreError.decodingFailed
            }
            do {
                return try JSONDecoder().decode(OAuthCredentials.self, from: data)
            } catch {
                throw KeychainCredentialStoreError.decodingFailed
            }
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainCredentialStoreError.unexpectedStatus(status)
        }
    }

    func saveCredentials(_ credentials: OAuthCredentials) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(credentials)
        } catch {
            throw KeychainCredentialStoreError.encodingFailed
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainCredentialStoreError.unexpectedStatus(addStatus)
            }
        default:
            throw KeychainCredentialStoreError.unexpectedStatus(updateStatus)
        }
    }

    func clearCredentials() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainCredentialStoreError.unexpectedStatus(status)
        }
    }
}
