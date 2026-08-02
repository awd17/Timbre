import AVFoundation
import FluidAudio
import Foundation

/// Supplies Float32 mono @ 16 kHz samples for a Parakeet batch session.
@MainActor
protocol ParakeetAudioSource: AnyObject {
    var diagnosticLabel: String { get }
    func prepareAccess() async throws
    func prewarm() throws
    func begin(onAudioLevel: @escaping @MainActor (Float) -> Void) throws
    /// Stop capture if any, then return an immutable sample snapshot.
    func finish() throws -> [Float]
    func teardown()
    func shutdown()
}

extension ParakeetAudioSource {
    func prewarm() throws {}
    func shutdown() { teardown() }
}

// MARK: - Microphone

@MainActor
final class ParakeetMicrophoneAudioSource: ParakeetAudioSource {
    let diagnosticLabel = "microphone"

    private let capturer: CoreAudioInputCapturer
    private let capture = ParakeetCaptureBuffer()
    private(set) var hardwareFormatDescription = "unknown"

    init(inputDevices: CoreAudioInputDeviceManager) {
        self.capturer = CoreAudioInputCapturer(inputDevices: inputDevices)
    }

    func prepareAccess() async throws {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return
        case .denied:
            throw TranscriptionError.microphonePermissionDenied
        case .undetermined:
            let granted = await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
            guard granted else {
                throw TranscriptionError.microphonePermissionDenied
            }
        @unknown default:
            throw TranscriptionError.microphonePermissionDenied
        }
    }

    func prewarm() throws {
        try capturer.prepare()
    }

    func begin(onAudioLevel: @escaping @MainActor (Float) -> Void) throws {
        capture.clear()

        let captureBuffer = capture
        do {
            let configuration = try capturer.start(
                onBuffer: { buffer in
                    captureBuffer.append(buffer)
                },
                onAudioLevel: onAudioLevel
            )
            hardwareFormatDescription = configuration.formatDescription
            TimbreLog.line(
                "Timbre Parakeet: input-only capture format \(hardwareFormatDescription)"
            )
            TimbreLog.line("Timbre Parakeet: effective microphone \(configuration.device.name)")
            TimbreLog.line("Timbre Parakeet: listening (no live partials).")
        } catch {
            teardown()
            if error is TranscriptionError {
                throw error
            }
            throw TranscriptionError.audioEngineFailed
        }
    }

    func finish() throws -> [Float] {
        capturer.stop()
        return capture.finishAndSnapshot()
    }

    func teardown() {
        capturer.stop()
        capture.clear()
    }

    func shutdown() {
        capturer.shutdown()
        capture.clear()
    }
}

// MARK: - Fixture

@MainActor
final class ParakeetFixtureAudioSource: ParakeetAudioSource {
    let diagnosticLabel: String
    private let url: URL
    private let converter = AudioConverter()

    init(url: URL) {
        self.url = url
        self.diagnosticLabel = "fixture:\(url.lastPathComponent)"
    }

    func prepareAccess() async throws {}

    func begin(onAudioLevel: @escaping @MainActor (Float) -> Void) throws {
        _ = onAudioLevel
        TimbreLog.line("Timbre Parakeet: fixture mode — no microphone capture.")
    }

    func finish() throws -> [Float] {
        TimbreLog.line("Timbre Parakeet: loading fixture \(url.path)")
        do {
            return try converter.resampleAudioFile(url)
        } catch {
            throw TranscriptionError.recognitionFailed(
                "Failed to load fixture audio: \(error.localizedDescription)"
            )
        }
    }

    func teardown() {}
}

// MARK: - Capture buffer

/// Serial-queue owner for converted mic samples. Tap callbacks only enqueue here.
final class ParakeetCaptureBuffer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.augustdrakton.timbre.parakeet.capture")
    private let converter = AudioConverter()
    private var samples: [Float] = []

    func append(_ buffer: AVAudioPCMBuffer) {
        queue.async { [converter] in
            do {
                let converted = try converter.resampleBuffer(buffer)
                self.samples.append(contentsOf: converted)
            } catch {
                TimbreLog.line(
                    "Timbre Parakeet: buffer conversion failed: \(error.localizedDescription)"
                )
            }
        }
    }

    /// After tap removal and engine stop: drain pending appends, snapshot, clear.
    func finishAndSnapshot() -> [Float] {
        queue.sync {
            let snapshot = samples
            samples.removeAll(keepingCapacity: false)
            return snapshot
        }
    }

    func clear() {
        queue.sync {
            samples.removeAll(keepingCapacity: false)
        }
    }
}
