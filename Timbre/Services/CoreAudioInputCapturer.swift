import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

/// Input-only Core Audio HAL capture.
///
/// `AVAudioEngine` opens the graph output side on `start()`, which can briefly
/// interrupt AirPods/system playback even when Timbre only needs the mic. This
/// capturer enables HAL input IO and leaves output IO off so the default output
/// device is never claimed.
@MainActor
final class CoreAudioInputCapturer {
    struct Configuration: Equatable {
        let device: AudioInputDevice
        let sampleRate: Double
        let channelCount: AVAudioChannelCount

        var formatDescription: String {
            "rate=\(sampleRate) channels=\(channelCount) commonFormat=1"
        }
    }

    private let inputDevices: CoreAudioInputDeviceManager
    private var audioUnit: AudioUnit?
    private var asbd = AudioStreamBasicDescription()
    private var renderBuffer: UnsafeMutablePointer<AudioBufferList>?
    /// AU refcon target. Outlives in-flight callbacks; owns optional render state.
    private var callbackGate: CallbackGate?
    private var isRunning = false
    private var preparedDeviceID: AudioDeviceID?

    init(inputDevices: CoreAudioInputDeviceManager) {
        self.inputDevices = inputDevices
    }

    func start(
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
        onAudioLevel: @escaping @MainActor (Float) -> Void
    ) throws -> Configuration {
        stop()

        let startedAt = DispatchTime.now().uptimeNanoseconds
        let device = try resolveDevice()
        let format = try makeClientFormat(for: device.audioDeviceID)
        let reusedPreparedUnit = canReusePreparedUnit(for: device, format: format)

        do {
            if !reusedPreparedUnit {
                shutdown()
                try prepare(device: device, format: format)
            }
            guard let unit = audioUnit else {
                throw TranscriptionError.audioEngineFailed
            }
            try attachCallback(
                to: unit,
                onBuffer: onBuffer,
                onAudioLevel: onAudioLevel
            )
            try check(AudioOutputUnitStart(unit), operation: "Starting input audio unit")
            isRunning = true
        } catch {
            shutdown()
            throw error
        }

        TimbreLog.line("Timbre microphone: selected \(device.name) (input-only HAL)")
        let milliseconds = Double(
            DispatchTime.now().uptimeNanoseconds &- startedAt
        ) / 1_000_000
        TimbreLog.line(
            String(
                format: "Timbre performance: microphone-start=%.1fms preparedUnitReused=%@",
                milliseconds,
                reusedPreparedUnit ? "true" : "false"
            )
        )
        return Configuration(
            device: device,
            sampleRate: asbd.mSampleRate,
            channelCount: AVAudioChannelCount(max(asbd.mChannelsPerFrame, 1))
        )
    }

    /// Build and initialize the input-only HAL unit without starting capture.
    /// Safe to run after onboarding has microphone permission; the next Start
    /// only attaches session callbacks and starts the already-prepared unit.
    func prepare() throws {
        stop()
        let device = try resolveDevice()
        let format = try makeClientFormat(for: device.audioDeviceID)
        guard !canReusePreparedUnit(for: device, format: format) else { return }
        shutdown()
        try prepare(device: device, format: format)
        TimbreLog.line("Timbre microphone: prepared input-only HAL unit.")
    }

    func stop() {
        // Lifetime boundary for the realtime callback:
        // 1) detach render state under the gate lock (new entries no-op)
        // 2) stop IO (HAL stops synchronously w.r.t. the current render)
        // 3) wait until any in-flight entry finishes
        //
        // The stopped, initialized unit is deliberately retained. Recreating
        // and reinitializing HAL for every dictation dominated warm startup.
        let gate = callbackGate
        gate?.detach()

        if let unit = audioUnit {
            if isRunning {
                AudioOutputUnitStop(unit)
            }
        }
        isRunning = false

        gate?.waitUntilIdle()
    }

    /// Fully releases the prepared unit. Used for app termination, device
    /// changes, and failed setup; ordinary session teardown calls `stop()`.
    func shutdown() {
        stop()

        if let unit = audioUnit {
            var cleared = AURenderCallbackStruct(
                inputProc: nil,
                inputProcRefCon: nil
            )
            AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_SetInputCallback,
                kAudioUnitScope_Global,
                0,
                &cleared,
                UInt32(MemoryLayout<AURenderCallbackStruct>.size)
            )
            callbackGate?.releaseForAudioUnit()
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        audioUnit = nil
        callbackGate = nil
        preparedDeviceID = nil
        if let renderBuffer {
            freeAudioBufferList(renderBuffer)
            self.renderBuffer = nil
        }
    }

    // MARK: - Setup

    private func resolveDevice() throws -> AudioInputDevice {
        // CoreAudioInputDeviceManager already monitors device/default changes.
        // Avoid a full hardware enumeration on every shortcut press.
        if inputDevices.effectiveDevice == nil {
            inputDevices.refresh()
        }
        if inputDevices.unavailableSelection != nil {
            TimbreLog.line(
                "Timbre microphone: preferred device is unavailable; using System Default."
            )
        }
        guard let device = inputDevices.effectiveDevice else {
            throw TranscriptionError.audioEngineFailed
        }
        return device
    }

    private func canReusePreparedUnit(
        for device: AudioInputDevice,
        format: AudioStreamBasicDescription
    ) -> Bool {
        audioUnit != nil
            && preparedDeviceID == device.audioDeviceID
            && asbd.mSampleRate == format.mSampleRate
            && asbd.mChannelsPerFrame == format.mChannelsPerFrame
    }

    private func prepare(
        device: AudioInputDevice,
        format: AudioStreamBasicDescription
    ) throws {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw TranscriptionError.audioEngineFailed
        }

        var unit: AudioUnit?
        try check(
            AudioComponentInstanceNew(component, &unit),
            operation: "Creating input audio unit"
        )
        guard let unit else {
            throw TranscriptionError.audioEngineFailed
        }
        audioUnit = unit

        do {
            try enableIO(on: unit)
            try setCurrentDevice(device.audioDeviceID, on: unit)
            asbd = format
            try setClientFormat(format, on: unit)
            try prepareRenderBuffer(format: format, on: unit)
            try installCallbackGate(on: unit)
            try check(AudioUnitInitialize(unit), operation: "Initializing input audio unit")
            preparedDeviceID = device.audioDeviceID
        } catch {
            shutdown()
            throw error
        }
    }

    private func enableIO(on unit: AudioUnit) throws {
        var enable: UInt32 = 1
        try check(
            AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_EnableIO,
                kAudioUnitScope_Input,
                1,
                &enable,
                UInt32(MemoryLayout<UInt32>.size)
            ),
            operation: "Enabling input IO"
        )

        var disable: UInt32 = 0
        try check(
            AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_EnableIO,
                kAudioUnitScope_Output,
                0,
                &disable,
                UInt32(MemoryLayout<UInt32>.size)
            ),
            operation: "Disabling output IO"
        )
    }

    private func setCurrentDevice(_ deviceID: AudioDeviceID, on unit: AudioUnit) throws {
        var mutableDeviceID = deviceID
        try check(
            AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &mutableDeviceID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            ),
            operation: "Binding microphone device"
        )
    }

    private func makeClientFormat(for deviceID: AudioDeviceID) throws -> AudioStreamBasicDescription {
        guard
            let native = CoreAudioHardware.streamFormat(
                deviceID: deviceID,
                scope: kAudioObjectPropertyScopeInput
            ),
            native.mSampleRate > 0
        else {
            throw TranscriptionError.audioEngineFailed
        }

        var format = AudioStreamBasicDescription()
        format.mSampleRate = native.mSampleRate
        format.mFormatID = kAudioFormatLinearPCM
        format.mFormatFlags =
            kAudioFormatFlagIsFloat
            | kAudioFormatFlagIsPacked
            | kAudioFormatFlagIsNonInterleaved
        format.mBytesPerPacket = 4
        format.mFramesPerPacket = 1
        format.mBytesPerFrame = 4
        format.mChannelsPerFrame = max(native.mChannelsPerFrame, 1)
        format.mBitsPerChannel = 32
        return format
    }

    private func setClientFormat(
        _ format: AudioStreamBasicDescription,
        on unit: AudioUnit
    ) throws {
        var mutableFormat = format
        // For HAL input, element 1 / output scope is the format delivered to the app.
        try check(
            AudioUnitSetProperty(
                unit,
                kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Output,
                1,
                &mutableFormat,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            ),
            operation: "Setting capture stream format"
        )
    }

    private func prepareRenderBuffer(
        format: AudioStreamBasicDescription,
        on unit: AudioUnit
    ) throws {
        var maxFrames: UInt32 = 4096
        var size = UInt32(MemoryLayout<UInt32>.size)
        if AudioUnitGetProperty(
            unit,
            kAudioUnitProperty_MaximumFramesPerSlice,
            kAudioUnitScope_Global,
            0,
            &maxFrames,
            &size
        ) != noErr || maxFrames == 0 {
            maxFrames = 4096
        }

        let channels = Int(max(format.mChannelsPerFrame, 1))
        renderBuffer = allocateAudioBufferList(channels: channels, frames: Int(maxFrames))
    }

    private func attachCallback(
        to unit: AudioUnit,
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
        onAudioLevel: @escaping @MainActor (Float) -> Void
    ) throws {
        guard let renderBuffer else {
            throw TranscriptionError.audioEngineFailed
        }

        let state = CallbackState(
            audioUnit: unit,
            asbd: asbd,
            renderBuffer: renderBuffer,
            onBuffer: onBuffer,
            onAudioLevel: onAudioLevel
        )
        guard let callbackGate else {
            throw TranscriptionError.audioEngineFailed
        }
        callbackGate.attach(state)
    }

    private func installCallbackGate(on unit: AudioUnit) throws {
        let newGate = CallbackGate(state: nil)
        callbackGate = newGate
        // Retain gate for the AU refcon lifetime; balanced by shutdown().
        newGate.retainForAudioUnit()

        var callbackStruct = AURenderCallbackStruct(
            inputProc: Self.renderCallback,
            inputProcRefCon: Unmanaged.passUnretained(newGate).toOpaque()
        )
        try check(
            AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_SetInputCallback,
                kAudioUnitScope_Global,
                0,
                &callbackStruct,
                UInt32(MemoryLayout<AURenderCallbackStruct>.size)
            ),
            operation: "Installing input callback"
        )
    }

    private func check(_ status: OSStatus, operation: String) throws {
        guard status == noErr else {
            throw CoreAudioOperationError(operation: operation, status: status)
        }
    }

    // MARK: - Realtime callback

    /// AU refcon target. Strongly owns render state and tracks in-flight entries
    /// under one lock so teardown cannot free resources during callback entry.
    private final class CallbackGate: @unchecked Sendable {
        private let lock = NSLock()
        private var state: CallbackState?
        private var inFlightEntries = 0
        private var audioUnitRetained = false

        init(state: CallbackState?) {
            self.state = state
        }

        func attach(_ state: CallbackState) {
            lock.lock()
            self.state = state
            lock.unlock()
        }

        func retainForAudioUnit() {
            lock.lock()
            guard !audioUnitRetained else {
                lock.unlock()
                return
            }
            audioUnitRetained = true
            lock.unlock()
            _ = Unmanaged.passRetained(self)
        }

        func releaseForAudioUnit() {
            lock.lock()
            guard audioUnitRetained else {
                lock.unlock()
                return
            }
            audioUnitRetained = false
            lock.unlock()
            Unmanaged.passUnretained(self).release()
        }

        /// Drop render state so new entries no-op. Must run before IO stop.
        func detach() {
            lock.lock()
            state = nil
            lock.unlock()
        }

        func waitUntilIdle() {
            while true {
                lock.lock()
                let busy = inFlightEntries > 0
                lock.unlock()
                if !busy { return }
                Thread.sleep(forTimeInterval: 0.0005)
            }
        }

        /// Load state and register in-flight under one lock — no untracked window.
        func withState(
            _ body: (CallbackState) -> OSStatus
        ) -> OSStatus {
            lock.lock()
            guard let state else {
                lock.unlock()
                return noErr
            }
            inFlightEntries += 1
            lock.unlock()

            defer {
                lock.lock()
                inFlightEntries -= 1
                lock.unlock()
            }
            return body(state)
        }
    }

    private final class CallbackState: @unchecked Sendable {
        let audioUnit: AudioUnit
        let asbd: AudioStreamBasicDescription
        let format: AVAudioFormat?
        let renderBuffer: UnsafeMutablePointer<AudioBufferList>
        let onBuffer: @Sendable (AVAudioPCMBuffer) -> Void
        let onAudioLevel: @MainActor (Float) -> Void
        let meter = AudioLevelMeter()

        init(
            audioUnit: AudioUnit,
            asbd: AudioStreamBasicDescription,
            renderBuffer: UnsafeMutablePointer<AudioBufferList>,
            onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
            onAudioLevel: @escaping @MainActor (Float) -> Void
        ) {
            self.audioUnit = audioUnit
            self.asbd = asbd
            self.format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: asbd.mSampleRate,
                channels: AVAudioChannelCount(max(asbd.mChannelsPerFrame, 1)),
                interleaved: false
            )
            self.renderBuffer = renderBuffer
            self.onBuffer = onBuffer
            self.onAudioLevel = onAudioLevel
        }

        func render(
            ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
            inTimeStamp: UnsafePointer<AudioTimeStamp>,
            inBusNumber: UInt32,
            inNumberFrames: UInt32
        ) -> OSStatus {
            let channels = Int(max(asbd.mChannelsPerFrame, 1))
            let abl = UnsafeMutableAudioBufferListPointer(renderBuffer)
            for index in 0..<min(channels, abl.count) {
                abl[index].mNumberChannels = 1
                abl[index].mDataByteSize = inNumberFrames * UInt32(MemoryLayout<Float>.size)
            }

            let status = AudioUnitRender(
                audioUnit,
                ioActionFlags,
                inTimeStamp,
                inBusNumber,
                inNumberFrames,
                renderBuffer
            )
            guard status == noErr else { return status }

            guard let format,
                  let buffer = AVAudioPCMBuffer(
                    pcmFormat: format,
                    frameCapacity: inNumberFrames
                ),
                let destinations = buffer.floatChannelData
            else {
                return noErr
            }
            buffer.frameLength = inNumberFrames

            for channel in 0..<min(channels, abl.count) {
                guard let source = abl[channel].mData?.assumingMemoryBound(to: Float.self)
                else {
                    continue
                }
                destinations[channel].update(from: source, count: Int(inNumberFrames))
            }

            onBuffer(buffer)
            if let level = meter.consume(buffer) {
                Task { @MainActor in
                    onAudioLevel(level)
                }
            }
            return noErr
        }
    }

    private nonisolated static let renderCallback: AURenderCallback = {
        inRefCon,
        ioActionFlags,
        inTimeStamp,
        inBusNumber,
        inNumberFrames,
        _
        in
        // Gate is retained for the AU refcon lifetime. withState loads render
        // state and bumps in-flight under one lock, so stop() cannot free the
        // render buffer during entry or render.
        let gate = Unmanaged<CallbackGate>.fromOpaque(inRefCon).takeUnretainedValue()
        return gate.withState { state in
            state.render(
                ioActionFlags: ioActionFlags,
                inTimeStamp: inTimeStamp,
                inBusNumber: inBusNumber,
                inNumberFrames: inNumberFrames
            )
        }
    }
}

// MARK: - Buffer list helpers

private func allocateAudioBufferList(
    channels: Int,
    frames: Int
) -> UnsafeMutablePointer<AudioBufferList> {
    let byteSize = MemoryLayout<AudioBufferList>.size
        + max(channels - 1, 0) * MemoryLayout<AudioBuffer>.size
    let raw = UnsafeMutableRawPointer.allocate(
        byteCount: byteSize,
        alignment: MemoryLayout<AudioBufferList>.alignment
    )
    let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
    list.pointee.mNumberBuffers = UInt32(channels)

    let abl = UnsafeMutableAudioBufferListPointer(list)
    for index in 0..<channels {
        let data = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        data.initialize(repeating: 0, count: frames)
        abl[index].mNumberChannels = 1
        abl[index].mDataByteSize = UInt32(frames * MemoryLayout<Float>.size)
        abl[index].mData = UnsafeMutableRawPointer(data)
    }
    return list
}

private func freeAudioBufferList(_ list: UnsafeMutablePointer<AudioBufferList>) {
    let abl = UnsafeMutableAudioBufferListPointer(list)
    for buffer in abl {
        if let data = buffer.mData {
            data.assumingMemoryBound(to: Float.self).deallocate()
        }
    }
    UnsafeMutableRawPointer(list).deallocate()
}

extension CoreAudioHardware {
    static func streamFormat(
        deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope
    ) -> AudioStreamBasicDescription? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = withUnsafeMutableBytes(of: &format) { bytes in
            AudioObjectGetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                &size,
                bytes.baseAddress!
            )
        }
        guard status == noErr, format.mSampleRate > 0 else { return nil }
        return format
    }
}
