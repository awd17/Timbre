import Accelerate
import AVFoundation
import Foundation

/// Converts microphone PCM buffers into a throttled, smoothed 0...1 voice level.
///
/// The meter retains no audio. Its small lock protects smoothing state because
/// the realtime audio callback runs outside the main actor.
final class AudioLevelMeter: @unchecked Sendable {
    /// Keep ordinary speech below the top of the meter even when input gain is high.
    static let floorDecibels: Float = -54
    static let ceilingDecibels: Float = -6
    static let noiseGateDecibels: Float = -42
    static let noiseGateWidthDecibels: Float = 6

    private let lock = NSLock()
    private let minimumPublishInterval: TimeInterval
    private let attackTimeConstant: TimeInterval
    private let releaseTimeConstant: TimeInterval
    private var smoothedLevel: Float = 0
    private var lastSampleTime: TimeInterval?
    private var lastPublishTime: TimeInterval?

    init(
        maximumUpdatesPerSecond: Double = 24,
        attackTimeConstant: TimeInterval = 0.12,
        releaseTimeConstant: TimeInterval = 0.28
    ) {
        minimumPublishInterval = 1 / max(maximumUpdatesPerSecond, 1)
        self.attackTimeConstant = max(attackTimeConstant, 0.001)
        self.releaseTimeConstant = max(releaseTimeConstant, 0.001)
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

        let delta = max(time - (lastSampleTime ?? time), 0)
        let coefficient: Float
        if lastSampleTime == nil {
            coefficient = 1
        } else {
            let timeConstant = target > smoothedLevel
                ? attackTimeConstant
                : releaseTimeConstant
            coefficient = Float(1 - exp(-delta / timeConstant))
        }
        smoothedLevel += (target - smoothedLevel) * coefficient
        lastSampleTime = time

        guard
            lastPublishTime == nil
                || time - (lastPublishTime ?? time) >= minimumPublishInterval
        else {
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
        let gate = (decibels - noiseGateDecibels) / noiseGateWidthDecibels
        let softGate = min(max(gate, 0), 1)
        // A squared knee makes low-level room noise effectively disappear while
        // leaving normal speech responsive once it clears the gate.
        return min(max(normalized * softGate * softGate, 0), 1)
    }
}
