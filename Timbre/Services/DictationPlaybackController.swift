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
    /// The scalar requested before Core Audio reports the device's actual value.
    ///
    /// This remains separate from `appliedVolume` because hardware may quantize
    /// a requested scalar. It also makes the on-disk record crash-safe across
    /// the small interval between the write and its read-back.
    let requestedVolume: Float?
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
    private static let appliedValueTolerance: Float = 0.002
    private static let pendingWriteTolerance: Float = 0.05

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
            applyVolume(
                appliedVolume,
                startingAt: originalVolume,
                mode: mode,
                device: device
            )
        case .mute:
            if hardware.canSetMute(of: device),
               let originalMute = hardware.mute(of: device)
            {
                if applyMute(startingAt: originalMute, device: device) {
                    return
                }
            }
            if hardware.canSetVolume(of: device),
               let originalVolume = hardware.volume(of: device)
            {
                applyVolume(
                    0,
                    startingAt: originalVolume,
                    mode: mode,
                    device: device
                )
            } else {
                reportUnsupported(
                    "current output cannot be muted in software; leaving playback unchanged."
                )
            }
        }
    }

    private func applyVolume(
        _ requestedVolume: Float,
        startingAt originalVolume: Float,
        mode: PlaybackDuringDictation,
        device: AudioOutputDevice
    ) {
        if approximatelyEqual(originalVolume, requestedVolume) {
            markApplied(to: device)
            return
        }

        // Persist before changing the device so an unexpected termination can
        // still restore the starting scalar.
        let pendingRecord = PlaybackRestorationRecord(
            deviceUID: device.uid,
            originalVolume: originalVolume,
            requestedVolume: requestedVolume,
            appliedVolume: nil,
            originalMute: nil,
            appliedMute: nil
        )
        upsert(pendingRecord)
        let status = hardware.setVolume(requestedVolume, of: device)
        guard status == noErr else {
            resolveFailedVolumeWrite(
                pendingRecord,
                device: device,
                status: status,
                mode: mode
            )
            return
        }

        guard let actualVolume = hardware.volume(of: device) else {
            // The device exposed a scalar before the write but stopped
            // reporting it afterward. Restore best-effort and do not claim
            // that attenuation is active.
            _ = hardware.setVolume(originalVolume, of: device)
            removeRecord(for: device.uid)
            reportApplyFailure(mode: mode, status: nil)
            return
        }

        guard actualVolume <= originalVolume + Self.appliedValueTolerance else {
            // Never leave playback louder than it began if a driver behaves
            // unexpectedly.
            _ = hardware.setVolume(originalVolume, of: device)
            removeRecord(for: device.uid)
            reportApplyFailure(mode: mode, status: nil)
            return
        }

        if approximatelyEqual(actualVolume, originalVolume) {
            removeRecord(for: device.uid)
            reportApplyFailure(mode: mode, status: nil)
            return
        } else {
            // Store the read-back scalar, not the request. Many output devices
            // quantize their volume controls, and restoration must compare
            // against what the device actually applied.
            upsert(
                PlaybackRestorationRecord(
                    deviceUID: device.uid,
                    originalVolume: originalVolume,
                    requestedVolume: requestedVolume,
                    appliedVolume: actualVolume,
                    originalMute: nil,
                    appliedMute: nil
                )
            )
        }
        markApplied(to: device)
    }

    private func applyMute(
        startingAt originalMute: Bool,
        device: AudioOutputDevice
    ) -> Bool {
        if originalMute {
            markApplied(to: device)
            return true
        }

        let record = PlaybackRestorationRecord(
            deviceUID: device.uid,
            originalVolume: nil,
            requestedVolume: nil,
            appliedVolume: nil,
            originalMute: originalMute,
            appliedMute: true
        )
        upsert(record)
        let status = hardware.setMute(true, of: device)
        let appliedMute = hardware.mute(of: device)
        guard status == noErr, appliedMute == true else {
            if appliedMute == true {
                // A driver may report an error after applying the write. Keep
                // the record so Stop can still restore it.
                markApplied(to: device)
                return true
            } else {
                // A nominally writable mute control can still reject a write.
                // Put it back best-effort, then let the caller try volume zero.
                if appliedMute == nil {
                    _ = hardware.setMute(originalMute, of: device)
                }
                removeRecord(for: device.uid)
                return false
            }
        }
        markApplied(to: device)
        return true
    }

    private func resolveFailedVolumeWrite(
        _ pendingRecord: PlaybackRestorationRecord,
        device: AudioOutputDevice,
        status: OSStatus,
        mode: PlaybackDuringDictation
    ) {
        guard let currentVolume = hardware.volume(of: device) else {
            removeRecord(for: device.uid)
            reportApplyFailure(mode: mode, status: status)
            return
        }

        if !approximatelyEqual(currentVolume, pendingRecord.originalVolume ?? currentVolume) {
            upsert(
                PlaybackRestorationRecord(
                    deviceUID: device.uid,
                    originalVolume: pendingRecord.originalVolume,
                    requestedVolume: pendingRecord.requestedVolume,
                    appliedVolume: currentVolume,
                    originalMute: nil,
                    appliedMute: nil
                )
            )
            activeDeviceUID = device.uid
        } else {
            removeRecord(for: device.uid)
        }
        reportApplyFailure(mode: mode, status: status)
    }

    private func markApplied(to device: AudioOutputDevice) {
        activeDeviceUID = device.uid
        isCurrentOutputControllable = true
    }

    private func reportApplyFailure(
        mode: PlaybackDuringDictation,
        status: OSStatus?
    ) {
        isCurrentOutputControllable = false
        let statusDescription = status.map { " (Core Audio \($0))" } ?? ""
        TimbreLog.line(
            "Timbre playback: failed to apply \(mode.title.lowercased()) mode\(statusDescription)."
        )
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
            guard hardware.setMute(originalMute, of: device) == noErr else {
                return false
            }
            return hardware.mute(of: device) == originalMute
        }

        if let originalVolume = record.originalVolume {
            guard let currentVolume = hardware.volume(of: device) else { return true }
            let expectedVolume = record.appliedVolume ?? record.requestedVolume
            guard let expectedVolume else { return true }
            let tolerance = record.appliedVolume == nil || record.requestedVolume == nil
                ? Self.pendingWriteTolerance
                : Self.appliedValueTolerance
            guard abs(currentVolume - expectedVolume) <= tolerance else {
                return true
            }
            guard hardware.setVolume(originalVolume, of: device) == noErr else {
                return false
            }
            guard let restoredVolume = hardware.volume(of: device) else {
                return false
            }
            return approximatelyEqual(restoredVolume, originalVolume)
        }
        return true
    }

    private func approximatelyEqual(_ lhs: Float, _ rhs: Float) -> Bool {
        abs(lhs - rhs) <= Self.appliedValueTolerance
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
