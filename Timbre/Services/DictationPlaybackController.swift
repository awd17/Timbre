import AudioToolbox
import Combine
import CoreAudio
import Foundation

@MainActor
protocol DictationPlaybackControlling: AnyObject {
    func beginListening()
    func endListening()
    func shutdownForTermination()
}

@MainActor
final class NoOpDictationPlaybackController: DictationPlaybackControlling {
    func beginListening() {}
    func endListening() {}
    func shutdownForTermination() {}
}

struct AudioOutputDevice: Equatable {
    let audioDeviceID: AudioDeviceID
    let uid: String
}

@MainActor
protocol AudioOutputHardwareProviding: AnyObject {
    func currentDefaultOutput() -> AudioOutputDevice?
    func outputDevice(forUID uid: String) -> AudioOutputDevice?
    func volume(of device: AudioOutputDevice) -> Float?
    func canSetVolume(of device: AudioOutputDevice) -> Bool
    func setVolume(_ value: Float, of device: AudioOutputDevice) -> OSStatus
    func mute(of device: AudioOutputDevice) -> Bool?
    func canSetMute(of device: AudioOutputDevice) -> Bool
    func setMute(_ muted: Bool, of device: AudioOutputDevice) -> OSStatus
    func startMonitoring(
        onDevicesChanged: @escaping @MainActor () -> Void,
        onDefaultOutputChanged: @escaping @MainActor () -> Void
    )
    func stopMonitoring()
}

@MainActor
final class CoreAudioOutputHardware: AudioOutputHardwareProviding {
    private var devicesListener: AudioObjectPropertyListenerBlock?
    private var defaultOutputListener: AudioObjectPropertyListenerBlock?

    func currentDefaultOutput() -> AudioOutputDevice? {
        guard
            let deviceID = CoreAudioHardware.defaultOutputDeviceID(),
            let uid = CoreAudioHardware.deviceUID(deviceID)
        else {
            return nil
        }
        return AudioOutputDevice(audioDeviceID: deviceID, uid: uid)
    }

    func outputDevice(forUID uid: String) -> AudioOutputDevice? {
        guard
            let deviceID = CoreAudioHardware.deviceID(forUID: uid),
            CoreAudioHardware.isAlive(deviceID)
        else {
            return nil
        }
        return AudioOutputDevice(audioDeviceID: deviceID, uid: uid)
    }

    func volume(of device: AudioOutputDevice) -> Float? {
        CoreAudioHardware.floatProperty(
            objectID: device.audioDeviceID,
            selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume
        )
    }

    func canSetVolume(of device: AudioOutputDevice) -> Bool {
        CoreAudioHardware.propertyIsSettable(
            objectID: device.audioDeviceID,
            selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume
        ) && volume(of: device) != nil
    }

    func setVolume(_ value: Float, of device: AudioOutputDevice) -> OSStatus {
        CoreAudioHardware.setFloatProperty(
            value,
            objectID: device.audioDeviceID,
            selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume
        )
    }

    func mute(of device: AudioOutputDevice) -> Bool? {
        CoreAudioHardware.uint32Property(
            objectID: device.audioDeviceID,
            selector: kAudioDevicePropertyMute
        )
        .map { $0 != 0 }
    }

    func canSetMute(of device: AudioOutputDevice) -> Bool {
        CoreAudioHardware.propertyIsSettable(
            objectID: device.audioDeviceID,
            selector: kAudioDevicePropertyMute
        ) && mute(of: device) != nil
    }

    func setMute(_ muted: Bool, of device: AudioOutputDevice) -> OSStatus {
        CoreAudioHardware.setUInt32Property(
            muted ? 1 : 0,
            objectID: device.audioDeviceID,
            selector: kAudioDevicePropertyMute
        )
    }

    func startMonitoring(
        onDevicesChanged: @escaping @MainActor () -> Void,
        onDefaultOutputChanged: @escaping @MainActor () -> Void
    ) {
        stopMonitoring()
        let devicesBlock: AudioObjectPropertyListenerBlock = { _, _ in
            Task { @MainActor in onDevicesChanged() }
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

        let outputBlock: AudioObjectPropertyListenerBlock = { _, _ in
            Task { @MainActor in onDefaultOutputChanged() }
        }
        var outputAddress = Self.defaultOutputAddress
        if AudioObjectAddPropertyListenerBlock(
            CoreAudioHardware.systemObject,
            &outputAddress,
            DispatchQueue.main,
            outputBlock
        ) == noErr {
            defaultOutputListener = outputBlock
        }
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
        if let defaultOutputListener {
            var address = Self.defaultOutputAddress
            AudioObjectRemovePropertyListenerBlock(
                CoreAudioHardware.systemObject,
                &address,
                DispatchQueue.main,
                defaultOutputListener
            )
        }
        devicesListener = nil
        defaultOutputListener = nil
    }

    private static var devicesAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static var defaultOutputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}

private struct PlaybackRestorationRecord: Codable, Equatable {
    let deviceUID: String
    let originalVolume: Float?
    let appliedVolume: Float?
    let originalMute: Bool?
    let appliedMute: Bool?
}

@MainActor
final class DictationPlaybackController:
    ObservableObject,
    DictationPlaybackControlling
{
    static let restorationRecordsKey = "timbre.playbackRestorationRecords"
    static let loweredVolumeFactor: Float = 0.25

    @Published private(set) var isCurrentOutputControllable = true

    private let preferences: any AppPreferencesProviding
    private let defaults: UserDefaults
    private let hardware: any AudioOutputHardwareProviding
    private var isListening = false
    private var activeDeviceUID: String?
    private var activePlaybackMode: PlaybackDuringDictation?
    private var preferenceObservation: AnyCancellable?

    init(
        preferences: any AppPreferencesProviding,
        defaults: UserDefaults = .standard,
        hardware: (any AudioOutputHardwareProviding)? = nil
    ) {
        self.preferences = preferences
        self.defaults = defaults
        self.hardware = hardware ?? CoreAudioOutputHardware()
        recoverPendingRecords()
        refreshSupport()
        self.hardware.startMonitoring(
            onDevicesChanged: { [weak self] in
                self?.handleDeviceListChange()
            },
            onDefaultOutputChanged: { [weak self] in
                self?.handleDefaultOutputChange()
            }
        )
        preferenceObservation = preferences.changes.sink { [weak self] change in
            guard case .playbackDuringDictation = change, let self else { return }
            // The Settings control is disabled while listening. If another
            // source changes the preference, keep the current session stable
            // and use the new policy for the next recording.
            if !self.isListening {
                self.refreshSupport()
            }
        }
    }

    func beginListening() {
        guard !isListening else { return }
        isListening = true
        activePlaybackMode = preferences.playbackDuringDictation
        guard activePlaybackMode != .keepUnchanged else {
            activeDeviceUID = nil
            refreshSupport()
            return
        }
        recoverPendingRecords()
        applyToCurrentOutput()
    }

    func endListening() {
        isListening = false
        activeDeviceUID = nil
        recoverPendingRecords()
        activePlaybackMode = nil
        refreshSupport()
    }

    func shutdownForTermination() {
        endListening()
        hardware.stopMonitoring()
    }

    private func applyToCurrentOutput() {
        guard let device = hardware.currentDefaultOutput() else {
            isCurrentOutputControllable = false
            return
        }

        let mode = activePlaybackMode ?? preferences.playbackDuringDictation
        let record: PlaybackRestorationRecord
        switch mode {
        case .keepUnchanged:
            isCurrentOutputControllable = true
            return
        case .lower:
            guard
                hardware.canSetVolume(of: device),
                let originalVolume = hardware.volume(of: device)
            else {
                reportUnsupported(
                    "current output has no software volume control; leaving playback unchanged."
                )
                return
            }
            let appliedVolume = max(
                0,
                min(1, originalVolume * Self.loweredVolumeFactor)
            )
            record = PlaybackRestorationRecord(
                deviceUID: device.uid,
                originalVolume: originalVolume,
                appliedVolume: appliedVolume,
                originalMute: nil,
                appliedMute: nil
            )
        case .mute:
            if hardware.canSetMute(of: device),
               let originalMute = hardware.mute(of: device)
            {
                record = PlaybackRestorationRecord(
                    deviceUID: device.uid,
                    originalVolume: nil,
                    appliedVolume: nil,
                    originalMute: originalMute,
                    appliedMute: true
                )
            } else if hardware.canSetVolume(of: device),
                      let originalVolume = hardware.volume(of: device)
            {
                record = PlaybackRestorationRecord(
                    deviceUID: device.uid,
                    originalVolume: originalVolume,
                    appliedVolume: 0,
                    originalMute: nil,
                    appliedMute: nil
                )
            } else {
                reportUnsupported(
                    "current output cannot be muted in software; leaving playback unchanged."
                )
                return
            }
        }

        upsert(record)
        let status: OSStatus
        if let appliedMute = record.appliedMute {
            status = hardware.setMute(appliedMute, of: device)
        } else if let appliedVolume = record.appliedVolume {
            status = hardware.setVolume(appliedVolume, of: device)
        } else {
            status = noErr
        }

        guard status == noErr else {
            removeRecord(for: device.uid)
            isCurrentOutputControllable = false
            TimbreLog.line(
                "Timbre playback: failed to apply \(mode.title.lowercased()) mode (Core Audio \(status))."
            )
            return
        }
        activeDeviceUID = device.uid
        isCurrentOutputControllable = true
    }

    private func recoverPendingRecords(excluding excludedUID: String? = nil) {
        var retained: [PlaybackRestorationRecord] = []
        for record in loadRecords() {
            if record.deviceUID == excludedUID {
                retained.append(record)
                continue
            }
            guard let device = hardware.outputDevice(forUID: record.deviceUID) else {
                retained.append(record)
                continue
            }
            if !restore(record, device: device) {
                retained.append(record)
            }
        }
        saveRecords(retained)
    }

    /// Returns true when the record is resolved and can be discarded.
    private func restore(
        _ record: PlaybackRestorationRecord,
        device: AudioOutputDevice
    ) -> Bool {
        if let appliedMute = record.appliedMute,
           let originalMute = record.originalMute
        {
            guard let currentMute = hardware.mute(of: device) else { return true }
            guard currentMute == appliedMute else {
                return true
            }
            return hardware.setMute(originalMute, of: device) == noErr
        }

        if let appliedVolume = record.appliedVolume,
           let originalVolume = record.originalVolume
        {
            guard let currentVolume = hardware.volume(of: device) else { return true }
            guard abs(currentVolume - appliedVolume) <= 0.002 else {
                return true
            }
            return hardware.setVolume(originalVolume, of: device) == noErr
        }
        return true
    }

    private func handleDefaultOutputChange() {
        guard isListening else {
            recoverPendingRecords()
            refreshSupport()
            return
        }
        activeDeviceUID = nil
        recoverPendingRecords()
        applyToCurrentOutput()
    }

    private func handleDeviceListChange() {
        recoverPendingRecords(excluding: activeDeviceUID)
        if isListening,
           let activeDeviceUID,
           hardware.outputDevice(forUID: activeDeviceUID) == nil
        {
            self.activeDeviceUID = nil
            applyToCurrentOutput()
        } else {
            refreshSupport()
        }
    }

    private func refreshSupport() {
        guard preferences.playbackDuringDictation != .keepUnchanged else {
            isCurrentOutputControllable = true
            return
        }
        guard let device = hardware.currentDefaultOutput() else {
            isCurrentOutputControllable = false
            return
        }
        switch preferences.playbackDuringDictation {
        case .keepUnchanged:
            isCurrentOutputControllable = true
        case .lower:
            isCurrentOutputControllable = hardware.canSetVolume(of: device)
        case .mute:
            isCurrentOutputControllable =
                hardware.canSetMute(of: device) || hardware.canSetVolume(of: device)
        }
    }

    private func reportUnsupported(_ message: String) {
        isCurrentOutputControllable = false
        TimbreLog.line("Timbre playback: \(message)")
    }

    private func upsert(_ record: PlaybackRestorationRecord) {
        var records = loadRecords()
        records.removeAll { $0.deviceUID == record.deviceUID }
        records.append(record)
        saveRecords(records)
    }

    private func removeRecord(for uid: String) {
        saveRecords(loadRecords().filter { $0.deviceUID != uid })
    }

    private func loadRecords() -> [PlaybackRestorationRecord] {
        guard let data = defaults.data(forKey: Self.restorationRecordsKey) else {
            return []
        }
        return (try? JSONDecoder().decode([PlaybackRestorationRecord].self, from: data))
            ?? []
    }

    private func saveRecords(_ records: [PlaybackRestorationRecord]) {
        guard !records.isEmpty else {
            defaults.removeObject(forKey: Self.restorationRecordsKey)
            return
        }
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: Self.restorationRecordsKey)
    }
}
