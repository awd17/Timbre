import AudioToolbox
import AVFoundation
import Combine
import CoreAudio
import Foundation

struct AudioInputDevice: Identifiable, Equatable, Hashable {
    let audioDeviceID: AudioDeviceID
    let uid: String
    let name: String

    var id: String { uid }

    var selection: MicrophoneSelection {
        .device(uid: uid, name: name)
    }
}

struct CoreAudioOperationError: Error, LocalizedError {
    let operation: String
    let status: OSStatus

    var errorDescription: String? {
        "\(operation) failed with Core Audio status \(status)."
    }
}

enum CoreAudioHardware {
    static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    static func devices() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            systemObject,
            &address,
            0,
            nil,
            &size
        ) == noErr else {
            return []
        }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.stride
        guard count > 0 else { return [] }
        var devices = Array(repeating: AudioDeviceID(0), count: count)
        let status = devices.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(
                systemObject,
                &address,
                0,
                nil,
                &size,
                bytes.baseAddress!
            )
        }
        return status == noErr ? devices : []
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        devices().first { deviceUID($0) == uid }
    }

    static func defaultInputDeviceID() -> AudioDeviceID? {
        scalarProperty(
            objectID: systemObject,
            selector: kAudioHardwarePropertyDefaultInputDevice,
            scope: kAudioObjectPropertyScopeGlobal,
            defaultValue: AudioDeviceID(kAudioObjectUnknown)
        )
        .flatMap { $0 == kAudioObjectUnknown ? nil : $0 }
    }

    static func defaultOutputDeviceID() -> AudioDeviceID? {
        scalarProperty(
            objectID: systemObject,
            selector: kAudioHardwarePropertyDefaultOutputDevice,
            scope: kAudioObjectPropertyScopeGlobal,
            defaultValue: AudioDeviceID(kAudioObjectUnknown)
        )
        .flatMap { $0 == kAudioObjectUnknown ? nil : $0 }
    }

    static func deviceUID(_ deviceID: AudioDeviceID) -> String? {
        stringProperty(
            objectID: deviceID,
            selector: kAudioDevicePropertyDeviceUID,
            scope: kAudioObjectPropertyScopeGlobal
        )
    }

    static func deviceName(_ deviceID: AudioDeviceID) -> String? {
        stringProperty(
            objectID: deviceID,
            selector: kAudioObjectPropertyName,
            scope: kAudioObjectPropertyScopeGlobal
        )
    }

    static func isAlive(_ deviceID: AudioDeviceID) -> Bool {
        scalarProperty(
            objectID: deviceID,
            selector: kAudioDevicePropertyDeviceIsAlive,
            scope: kAudioObjectPropertyScopeGlobal,
            defaultValue: UInt32(0)
        ) == 1
    }

    static func inputChannelCount(_ deviceID: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            deviceID,
            &address,
            0,
            nil,
            &size
        ) == noErr, size >= MemoryLayout<AudioBufferList>.size else {
            return 0
        }

        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }
        let list = storage.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            list
        ) == noErr else {
            return 0
        }
        return UnsafeMutableAudioBufferListPointer(list)
            .reduce(0) { $0 + $1.mNumberChannels }
    }

    static func floatProperty(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput
    ) -> Float? {
        scalarProperty(
            objectID: objectID,
            selector: selector,
            scope: scope,
            defaultValue: Float(0)
        )
    }

    static func uint32Property(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput
    ) -> UInt32? {
        scalarProperty(
            objectID: objectID,
            selector: selector,
            scope: scope,
            defaultValue: UInt32(0)
        )
    }

    static func setFloatProperty(
        _ value: Float,
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput
    ) -> OSStatus {
        var mutableValue = value
        return setScalarProperty(
            &mutableValue,
            objectID: objectID,
            selector: selector,
            scope: scope
        )
    }

    static func setUInt32Property(
        _ value: UInt32,
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput
    ) -> OSStatus {
        var mutableValue = value
        return setScalarProperty(
            &mutableValue,
            objectID: objectID,
            selector: selector,
            scope: scope
        )
    }

    static func propertyIsSettable(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(objectID, &address, &settable) == noErr else {
            return false
        }
        return settable.boolValue
    }

    private static func scalarProperty<T>(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        defaultValue: T
    ) -> T? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = defaultValue
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutableBytes(of: &value) { bytes in
            AudioObjectGetPropertyData(
                objectID,
                &address,
                0,
                nil,
                &size,
                bytes.baseAddress!
            )
        }
        guard status == noErr else {
            return nil
        }
        return value
    }

    private static func stringProperty(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &size,
            &value
        ) == noErr else {
            return nil
        }
        return value?.takeRetainedValue() as String?
    }

    private static func setScalarProperty<T>(
        _ value: inout T,
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> OSStatus {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        return withUnsafeBytes(of: &value) { bytes in
            AudioObjectSetPropertyData(
                objectID,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<T>.size),
                bytes.baseAddress!
            )
        }
    }
}

@MainActor
final class CoreAudioInputDeviceManager: ObservableObject {
    @Published private(set) var devices: [AudioInputDevice] = []
    @Published private(set) var defaultInputDeviceUID: String?

    private let preferences: any AppPreferencesProviding
    private var devicesListener: AudioObjectPropertyListenerBlock?
    private var defaultInputListener: AudioObjectPropertyListenerBlock?

    init(preferences: any AppPreferencesProviding) {
        self.preferences = preferences
        refresh()
        startMonitoring()
    }

    var unavailableSelection: MicrophoneSelection? {
        guard case .device(let uid, _) = preferences.microphoneSelection else {
            return nil
        }
        return devices.contains(where: { $0.uid == uid })
            ? nil
            : preferences.microphoneSelection
    }

    var effectiveDevice: AudioInputDevice? {
        Self.resolve(
            preferences.microphoneSelection,
            among: devices,
            defaultInputDeviceUID: defaultInputDeviceUID
        )
    }

    static func resolve(
        _ selection: MicrophoneSelection,
        among devices: [AudioInputDevice],
        defaultInputDeviceUID: String?
    ) -> AudioInputDevice? {
        if case .device(let uid, _) = selection,
           let selected = devices.first(where: { $0.uid == uid })
        {
            return selected
        }
        guard let defaultInputDeviceUID else { return nil }
        return devices.first(where: { $0.uid == defaultInputDeviceUID })
    }

    func refresh() {
        devices = CoreAudioHardware.devices()
            .filter {
                CoreAudioHardware.isAlive($0)
                    && CoreAudioHardware.inputChannelCount($0) > 0
            }
            .compactMap { deviceID in
                guard
                    let uid = CoreAudioHardware.deviceUID(deviceID),
                    let name = CoreAudioHardware.deviceName(deviceID)
                else {
                    return nil
                }
                return AudioInputDevice(
                    audioDeviceID: deviceID,
                    uid: uid,
                    name: name
                )
            }
            .sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        defaultInputDeviceUID = CoreAudioHardware.defaultInputDeviceID()
            .flatMap(CoreAudioHardware.deviceUID)
    }

    @discardableResult
    func configureInputNode(_ inputNode: AVAudioInputNode) throws -> AudioInputDevice? {
        refresh()
        let requestedSelection = preferences.microphoneSelection
        guard let selected = effectiveDevice else {
            return nil
        }
        if case .device(let uid, _) = requestedSelection,
           !devices.contains(where: { $0.uid == uid })
        {
            TimbreLog.line(
                "Timbre microphone: preferred device is unavailable; using System Default."
            )
        }
        guard let audioUnit = inputNode.audioUnit else {
            throw TranscriptionError.audioEngineFailed
        }

        let firstStatus = bind(selected, to: audioUnit)
        if firstStatus == noErr {
            TimbreLog.line("Timbre microphone: selected \(selected.name)")
            return selected
        }

        // The device can disappear between enumeration and AudioUnitSetProperty.
        // Resolve again and bind the new effective default before format lookup.
        refresh()
        if let retryDevice = effectiveDevice,
           retryDevice.audioDeviceID != selected.audioDeviceID
        {
            let retryStatus = bind(retryDevice, to: audioUnit)
            if retryStatus == noErr {
                TimbreLog.line(
                    "Timbre microphone: input changed during startup; using \(retryDevice.name)."
                )
                return retryDevice
            }
        }

        throw CoreAudioOperationError(
            operation: "Selecting microphone \(selected.name)",
            status: firstStatus
        )
    }

    private func bind(
        _ device: AudioInputDevice,
        to audioUnit: AudioUnit
    ) -> OSStatus {
        var deviceID = device.audioDeviceID
        return AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
    }

    func stopMonitoring() {
        if let devicesListener {
            var address = Self.devicesAddress
            AudioObjectRemovePropertyListenerBlock(
                CoreAudioHardware.systemObject,
                &address,
                DispatchQueue.main,
                devicesListener
            )
        }
        if let defaultInputListener {
            var address = Self.defaultInputAddress
            AudioObjectRemovePropertyListenerBlock(
                CoreAudioHardware.systemObject,
                &address,
                DispatchQueue.main,
                defaultInputListener
            )
        }
        devicesListener = nil
        defaultInputListener = nil
    }

    private func startMonitoring() {
        let devicesBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
        var devicesAddress = Self.devicesAddress
        if AudioObjectAddPropertyListenerBlock(
            CoreAudioHardware.systemObject,
            &devicesAddress,
            DispatchQueue.main,
            devicesBlock
        ) == noErr {
            devicesListener = devicesBlock
        }

        let defaultBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
        var defaultAddress = Self.defaultInputAddress
        if AudioObjectAddPropertyListenerBlock(
            CoreAudioHardware.systemObject,
            &defaultAddress,
            DispatchQueue.main,
            defaultBlock
        ) == noErr {
            defaultInputListener = defaultBlock
        }
    }

    private static var devicesAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static var defaultInputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
