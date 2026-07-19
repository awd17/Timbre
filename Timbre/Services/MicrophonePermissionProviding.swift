import AppKit
import AVFoundation
import Foundation

enum MicrophonePermissionStatus: Equatable {
    case undetermined
    case granted
    case denied
}

@MainActor
protocol MicrophonePermissionProviding: AnyObject {
    var status: MicrophonePermissionStatus { get }
    /// Requests permission when undetermined. Does not re-prompt when already denied.
    func requestAccessIfNeeded() async -> MicrophonePermissionStatus
    func openSystemSettings()
}

@MainActor
final class MicrophonePermissionService: MicrophonePermissionProviding {
    var status: MicrophonePermissionStatus {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return .granted
        case .denied:
            return .denied
        case .undetermined:
            return .undetermined
        @unknown default:
            return .denied
        }
    }

    func requestAccessIfNeeded() async -> MicrophonePermissionStatus {
        let current = status
        switch current {
        case .granted, .denied:
            return current
        case .undetermined:
            let granted = await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
            return granted ? .granted : .denied
        }
    }

    func openSystemSettings() {
        let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
