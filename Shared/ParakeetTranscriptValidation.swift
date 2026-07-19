import Foundation

/// Soft transcript checks shared by the Parakeet smoke CLI and the in-app fixture gate.
enum ParakeetTranscriptValidation {
    struct Result: Equatable {
        let normalizedTranscript: String
        let hasQuickBrownFox: Bool
        let hasLazyDog: Bool
        let hasOptionalPhrase: Bool
        let matchedOptionalPhrase: String?
        let passed: Bool
    }

    private static let optionalPhrases = ["timbre", "smoke test", "parakeet"]

    static func softValidate(transcript: String) -> Result {
        let normalized = normalize(transcript)
        let hasQuickBrownFox = normalized.contains("quick brown fox")
        let hasLazyDog = normalized.contains("lazy dog")
        let matched = optionalPhrases.first(where: { normalized.contains($0) })
        let passed = !normalized.isEmpty
            && hasQuickBrownFox
            && hasLazyDog
            && matched != nil
        return Result(
            normalizedTranscript: normalized,
            hasQuickBrownFox: hasQuickBrownFox,
            hasLazyDog: hasLazyDog,
            hasOptionalPhrase: matched != nil,
            matchedOptionalPhrase: matched,
            passed: passed
        )
    }

    static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
        let scalars = lowered.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == " " {
                return Character(scalar)
            }
            return " "
        }
        return String(scalars)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}
