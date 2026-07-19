import AVFoundation
import FluidAudio
import Foundation

/// Supplies Float32 mono @ 16 kHz samples for a Parakeet batch session.
@MainActor
protocol ParakeetAudioSource: AnyObject {
    var diagnosticLabel: String { get }
    func prepareAccess() async throws
    func begin() throws
    /// Stop capture if any, then return an immutable sample snapshot.
    func finish() throws -> [Float]
    func teardown()
}

// MARK: - Microphone

@MainActor
final class ParakeetMicrophoneAudioSource: ParakeetAudioSource {
    let diagnosticLabel = "microphone"

    private let capture = ParakeetCaptureBuffer()
    private var audioEngine: AVAudioEngine?
    private var hasInstalledTap = false
    private(set) var hardwareFormatDescription = "unknown"

    func prepareAccess() async throws {
        let granted = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        guard granted else {
            throw TranscriptionError.microphonePermissionDenied
        }
    }

    func begin() throws {
        teardown()

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw TranscriptionError.audioEngineFailed
        }

        hardwareFormatDescription =
            "rate=\(format.sampleRate) channels=\(format.channelCount) commonFormat=\(format.commonFormat.rawValue)"
        TimbreLog.line("Timbre Parakeet: hardware input format \(hardwareFormatDescription)")

        let captureBuffer = capture
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            captureBuffer.append(buffer)
        }
        hasInstalledTap = true
        audioEngine = engine

        engine.prepare()
        do {
            try engine.start()
        } catch {
            teardown()
            throw TranscriptionError.audioEngineFailed
        }

        TimbreLog.line("Timbre Parakeet: listening (no live partials).")
    }

    func finish() throws -> [Float] {
        removeTapIfNeeded()
        audioEngine?.stop()
        audioEngine = nil
        return capture.finishAndSnapshot()
    }

    func teardown() {
        removeTapIfNeeded()
        audioEngine?.stop()
        audioEngine = nil
        capture.clear()
    }

    private func removeTapIfNeeded() {
        guard hasInstalledTap else { return }
        audioEngine?.inputNode.removeTap(onBus: 0)
        hasInstalledTap = false
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

    func begin() throws {
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
