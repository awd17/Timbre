import Foundation
import FluidAudio

struct ParakeetTranscriptionDiagnostics: Sendable {
    let cacheDirectory: URL
    let cacheDirectoryExistedBefore: Bool
    let modelsAvailableBefore: Bool
    let cacheSizeBytesBefore: UInt64
    let cacheSizeBytesAfter: UInt64
    let cacheGrewMeaningfully: Bool
    let preparationDuration: TimeInterval
    let transcriptionWallDuration: TimeInterval
    let audioDuration: TimeInterval
    let reportedProcessingTime: TimeInterval
    let confidence: Float
    let transcript: String
    let tokenTimingCount: Int?
}

enum ParakeetFileTranscriberError: Error, LocalizedError {
    case appleSiliconRequired
    case modelPreparationFailed(String)
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .appleSiliconRequired:
            return "Parakeet models require Apple Silicon."
        case .modelPreparationFailed(let message):
            return "Model download/load failed: \(message)"
        case .transcriptionFailed(let message):
            return "Transcription failed: \(message)"
        }
    }
}

enum ParakeetFileTranscriber {
    static let modelVersion: AsrModelVersion = .v2

    static func cacheDirectory() -> URL {
        AsrModels.defaultCacheDirectory(for: modelVersion)
    }

    static func modelsAvailable(at cacheDirectory: URL) -> Bool {
        AsrModels.modelsExist(at: cacheDirectory, version: modelVersion)
    }

    static func directoryByteSize(_ directory: URL) -> UInt64 {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var total: UInt64 = 0
        for case let fileURL as URL in enumerator {
            guard
                let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                values.isRegularFile == true,
                let size = values.fileSize
            else {
                continue
            }
            total += UInt64(size)
        }
        return total
    }

    static func transcribe(audioURL: URL) async throws -> ParakeetTranscriptionDiagnostics {
#if !arch(arm64)
        throw ParakeetFileTranscriberError.appleSiliconRequired
#endif
        let cacheDirectory = cacheDirectory()
        let cacheDirectoryExistedBefore = FileManager.default.fileExists(atPath: cacheDirectory.path)
        let modelsAvailableBefore = modelsAvailable(at: cacheDirectory)
        let cacheSizeBytesBefore = cacheDirectoryExistedBefore
            ? directoryByteSize(cacheDirectory)
            : 0

        let preparationStarted = Date()
        let models: AsrModels
        do {
            models = try await AsrModels.downloadAndLoad(version: modelVersion)
        } catch {
            throw ParakeetFileTranscriberError.modelPreparationFailed(error.localizedDescription)
        }
        let preparationDuration = Date().timeIntervalSince(preparationStarted)

        let cacheSizeBytesAfter = directoryByteSize(cacheDirectory)
        let sizeDelta = cacheSizeBytesAfter > cacheSizeBytesBefore
            ? cacheSizeBytesAfter - cacheSizeBytesBefore
            : 0
        // Treat growth under 1 MiB as non-meaningful (metadata / compiled sidecars).
        let cacheGrewMeaningfully = sizeDelta >= 1_048_576

        let manager = AsrManager(config: .default, models: models)
        var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)

        let transcriptionStarted = Date()
        let result: ASRResult
        do {
            result = try await manager.transcribe(audioURL, decoderState: &decoderState)
        } catch {
            throw ParakeetFileTranscriberError.transcriptionFailed(error.localizedDescription)
        }
        let transcriptionWallDuration = Date().timeIntervalSince(transcriptionStarted)

        return ParakeetTranscriptionDiagnostics(
            cacheDirectory: cacheDirectory,
            cacheDirectoryExistedBefore: cacheDirectoryExistedBefore,
            modelsAvailableBefore: modelsAvailableBefore,
            cacheSizeBytesBefore: cacheSizeBytesBefore,
            cacheSizeBytesAfter: cacheSizeBytesAfter,
            cacheGrewMeaningfully: cacheGrewMeaningfully,
            preparationDuration: preparationDuration,
            transcriptionWallDuration: transcriptionWallDuration,
            audioDuration: result.duration,
            reportedProcessingTime: result.processingTime,
            confidence: result.confidence,
            transcript: result.text,
            tokenTimingCount: result.tokenTimings?.count
        )
    }
}
