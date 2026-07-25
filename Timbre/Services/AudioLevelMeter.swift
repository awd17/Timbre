import Accelerate
import AVFoundation
import Foundation

/// Converts microphone PCM buffers into a throttled, smoothed 0...1 voice level.
///
/// The meter retains no audio. Its small lock protects smoothing state because
/// AVAudioEngine invokes taps outside the main actor.
final class AudioLevelMeter: @unchecked Sendable {
    static let floorDecibels: Float = -60
    static let ceilingDecibels: Float = -20

    private let lock = NSLock()
    private let minimumPublishInterval: TimeInterval
    private var smoothedLevel: Float = 0
    private var lastPublishTime: TimeInterval = 0

    init(maximumUpdatesPerSecond: Double = 30) {
        minimumPublishInterval = 1 / max(maximumUpdatesPerSecond, 1)
    }

    func consume(
        _ buffer: AVAudioPCMBuffer,
        time: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Float? {
        guard let channels = buffer.floatChannelData else { return nil }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return nil }

        var squaredSum: Float = 0
        for channelIndex in 0..<channelCount {
            var channelRMS: Float = 0
            vDSP_rmsqv(
                channels[channelIndex],
                1,
                &channelRMS,
                vDSP_Length(frameCount)
            )
            squaredSum += channelRMS * channelRMS
        }
        let rms = sqrt(squaredSum / Float(channelCount))
        return consume(rms: rms, time: time)
    }

    func consume(rms: Float, time: TimeInterval) -> Float? {
        let target = Self.normalizedLevel(rms: rms)

        lock.lock()
        defer { lock.unlock() }

        let coefficient: Float = target > smoothedLevel ? 0.72 : 0.24
        smoothedLevel += (target - smoothedLevel) * coefficient

        guard lastPublishTime == 0 || time - lastPublishTime >= minimumPublishInterval else {
            return nil
        }
        lastPublishTime = time
        return min(max(smoothedLevel, 0), 1)
    }

    static func normalizedLevel(rms: Float) -> Float {
        guard rms.isFinite, rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        let normalized =
            (decibels - floorDecibels) / (ceilingDecibels - floorDecibels)
        return min(max(normalized, 0), 1)
    }
}
