import Foundation

enum SessionState: Equatable {
    case idle
    case requestingPermission
    case listening(transcript: String)
    case finishing(transcript: String)
    case completed(transcript: String)
    case failed(message: String, transcript: String)

    var displayedTranscript: String {
        switch self {
        case .idle, .requestingPermission:
            return ""
        case .listening(let transcript),
             .finishing(let transcript),
             .completed(let transcript),
             .failed(_, let transcript):
            return transcript
        }
    }

    var statusMessage: String {
        switch self {
        case .idle:
            return "Ready"
        case .requestingPermission:
            return "Requesting permission..."
        case .listening:
            return "Listening..."
        case .finishing:
            return "Finishing transcription..."
        case .completed:
            return "Copied to clipboard."
        case .failed(let message, _):
            return message
        }
    }

    var canStart: Bool {
        switch self {
        case .idle, .completed, .failed:
            return true
        case .requestingPermission, .listening, .finishing:
            return false
        }
    }

    var canStop: Bool {
        if case .listening = self {
            return true
        }
        return false
    }

    func updatingTranscript(_ transcript: String) -> SessionState {
        switch self {
        case .listening:
            return .listening(transcript: transcript)
        case .finishing:
            return .finishing(transcript: transcript)
        case .idle, .requestingPermission, .completed, .failed:
            // Ignore partials outside an active listen/finish phase.
            return self
        }
    }
}
