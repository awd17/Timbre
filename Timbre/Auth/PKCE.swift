import CryptoKit
import Foundation

enum PKCE {
    /// RFC 7636 unreserved characters for code_verifier.
    private static let verifierAlphabet =
        Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    /// Generates a cryptographically random PKCE code verifier (43–128 chars).
    static func makeCodeVerifier(byteCount: Int = 64) -> String {
        var bytes = [UInt8](repeating: 0, count: min(128, max(43, byteCount)))
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")

        return String(bytes.map { byte in
            verifierAlphabet[Int(byte) % verifierAlphabet.count]
        })
    }

    /// S256 code_challenge = BASE64URL-ENCODE(SHA256(ASCII(code_verifier))).
    static func makeCodeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URLEncode(Data(digest))
    }

    static func makeState(byteCount: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return base64URLEncode(Data(bytes))
    }

    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
