import Foundation

enum SmokeTestExitCode: Int32 {
    case success = 0
    case usageError = 2
    case missingFixture = 3
    case invalidAudio = 4
    case modelFailure = 5
    case emptyTranscript = 6
    case validationFailure = 7
    case unexpectedFailure = 1
}

struct SoftValidationResult {
    let normalizedTranscript: String
    let hasQuickBrownFox: Bool
    let hasLazyDog: Bool
    let hasOptionalPhrase: Bool
    let matchedOptionalPhrase: String?
    let passed: Bool
}

enum ParakeetSmokeTestRunner {
    static func run(audioPath: String) async -> SmokeTestExitCode {
        print("=== Timbre Parakeet Smoke Test ===")
        print("FluidAudio model: FluidInference/parakeet-tdt-0.6b-v2-coreml (AsrModelVersion.v2)")
        print("Audio path: \(audioPath)")

        guard audioPath.hasPrefix("/") else {
            fputs("error: --audio must be an absolute path\n", stderr)
            return .usageError
        }

        let audioURL = URL(fileURLWithPath: audioPath)
        print("Resolved audio URL: \(audioURL.path)")

        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            fputs("error: audio file does not exist at \(audioURL.path)\n", stderr)
            return .missingFixture
        }

        do {
            try validateAudioFixture(at: audioURL)
        } catch {
            fputs("error: invalid audio fixture: \(error.localizedDescription)\n", stderr)
            return .invalidAudio
        }

        let diagnostics: ParakeetTranscriptionDiagnostics
        do {
            diagnostics = try await ParakeetFileTranscriber.transcribe(audioURL: audioURL)
        } catch let error as ParakeetFileTranscriberError {
            switch error {
            case .appleSiliconRequired, .modelPreparationFailed:
                fputs("error: \(error.localizedDescription)\n", stderr)
                return .modelFailure
            case .transcriptionFailed:
                fputs("error: \(error.localizedDescription)\n", stderr)
                return .unexpectedFailure
            }
        } catch {
            fputs("error: unexpected failure: \(error.localizedDescription)\n", stderr)
            return .unexpectedFailure
        }

        printDiagnostics(diagnostics)

        let trimmed = diagnostics.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            fputs("error: transcript is empty\n", stderr)
            return .emptyTranscript
        }

        let validation = softValidate(transcript: diagnostics.transcript)
        printValidation(validation)

        guard validation.passed else {
            fputs("error: soft validation failed\n", stderr)
            return .validationFailure
        }

        print("RESULT: PASS")
        return .success
    }

    private static func validateAudioFixture(at url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afinfo")
        process.arguments = [url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "ParakeetSmokeTest",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "afinfo failed:\n\(output)"]
            )
        }

        print("--- afinfo ---")
        print(output.trimmingCharacters(in: .whitespacesAndNewlines))

        let lower = output.lowercased()
        guard lower.contains("1 ch") || lower.contains("1 channel") else {
            throw NSError(
                domain: "ParakeetSmokeTest",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "expected mono (1 channel) audio"]
            )
        }
        guard lower.contains("16000") && lower.contains("hz") else {
            throw NSError(
                domain: "ParakeetSmokeTest",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "expected 16000 Hz sample rate"]
            )
        }
        guard lower.contains("int16") || lower.contains("pcm") || lower.contains("i16") else {
            throw NSError(
                domain: "ParakeetSmokeTest",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "expected PCM audio"]
            )
        }

        if let duration = parseEstimatedDuration(from: output), duration <= 0 {
            throw NSError(
                domain: "ParakeetSmokeTest",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "audio duration must be non-zero"]
            )
        }
    }

    private static func parseEstimatedDuration(from afinfoOutput: String) -> Double? {
        for line in afinfoOutput.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("estimated duration:") else { continue }
            let parts = trimmed.split(whereSeparator: { $0.isWhitespace })
            guard parts.count >= 3, let value = Double(parts[2]) else { return nil }
            return value
        }
        return nil
    }

    private static func printDiagnostics(_ diagnostics: ParakeetTranscriptionDiagnostics) {
        print("--- diagnostics ---")
        print("cache_directory: \(diagnostics.cacheDirectory.path)")
        print("cache_directory_existed_before: \(diagnostics.cacheDirectoryExistedBefore)")
        print("models_available_before: \(diagnostics.modelsAvailableBefore)")
        print("cache_size_before_bytes: \(diagnostics.cacheSizeBytesBefore)")
        print("cache_size_before_human: \(formatBytes(diagnostics.cacheSizeBytesBefore))")
        print("cache_size_after_bytes: \(diagnostics.cacheSizeBytesAfter)")
        print("cache_size_after_human: \(formatBytes(diagnostics.cacheSizeBytesAfter))")
        print("cache_grew_meaningfully: \(diagnostics.cacheGrewMeaningfully)")
        print(
            "likely_full_download: \(diagnostics.cacheGrewMeaningfully || !diagnostics.modelsAvailableBefore)"
        )
        print("likely_cache_reuse: \(diagnostics.modelsAvailableBefore && !diagnostics.cacheGrewMeaningfully)")
        print(
            String(
                format: "download_and_model_preparation_seconds: %.3f",
                diagnostics.preparationDuration
            )
        )
        print(String(format: "transcription_wall_seconds: %.3f", diagnostics.transcriptionWallDuration))
        print(String(format: "audio_duration_seconds: %.3f", diagnostics.audioDuration))
        print(
            String(
                format: "reported_processing_time_seconds: %.3f",
                diagnostics.reportedProcessingTime
            )
        )
        print(String(format: "confidence: %.4f", diagnostics.confidence))
        if let tokenTimingCount = diagnostics.tokenTimingCount {
            print("token_timing_count: \(tokenTimingCount)")
        }
        print("transcript: \(diagnostics.transcript)")
    }

    private static func softValidate(transcript: String) -> SoftValidationResult {
        let normalized = normalize(transcript)
        let hasQuickBrownFox = normalized.contains("quick brown fox")
        let hasLazyDog = normalized.contains("lazy dog")
        let optionalPhrases = ["timbre", "smoke test", "parakeet"]
        let matched = optionalPhrases.first(where: { normalized.contains($0) })
        let passed = !normalized.isEmpty
            && hasQuickBrownFox
            && hasLazyDog
            && matched != nil
        return SoftValidationResult(
            normalizedTranscript: normalized,
            hasQuickBrownFox: hasQuickBrownFox,
            hasLazyDog: hasLazyDog,
            hasOptionalPhrase: matched != nil,
            matchedOptionalPhrase: matched,
            passed: passed
        )
    }

    private static func printValidation(_ validation: SoftValidationResult) {
        print("--- soft validation ---")
        print("normalized_transcript: \(validation.normalizedTranscript)")
        print("has_quick_brown_fox: \(validation.hasQuickBrownFox)")
        print("has_lazy_dog: \(validation.hasLazyDog)")
        print("has_optional_phrase: \(validation.hasOptionalPhrase)")
        if let matched = validation.matchedOptionalPhrase {
            print("matched_optional_phrase: \(matched)")
        }
        print("validation_passed: \(validation.passed)")
    }

    private static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
        let scalars = lowered.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == " " {
                return Character(scalar)
            }
            return " "
        }
        let joined = String(scalars)
        return joined
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func formatBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
