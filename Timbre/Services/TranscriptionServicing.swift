import Foundation

enum TranscriptionError: Error, Equatable, LocalizedError {
    case notAvailable
    case microphonePermissionDenied
    case speechPermissionDenied
    case alreadyRunning
    case notRunning
    case audioEngineFailed
    case recognitionFailed(String)
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .notAvailable:
            return "Speech recognition is not available."
        case .microphonePermissionDenied:
            return "Microphone access is required. Enable it in System Settings → Privacy & Security → Microphone."
        case .speechPermissionDenied:
            return "Speech recognition access is required. Enable it in System Settings → Privacy & Security → Speech Recognition."
        case .alreadyRunning:
            return "Transcription is already running."
        case .notRunning:
            return "Transcription is not running."
        case .audioEngineFailed:
            return "Could not start the microphone."
        case .recognitionFailed(let message):
            return message
        case .emptyResult:
            return "No speech detected."
        }
    }
}

@MainActor
protocol TranscriptionServicing: AnyObject {
    func prepare() async throws
    func start(onPartialResult: @escaping @MainActor (String) -> Void) async throws
    func stop() async throws -> String
    func cancel() async
}
