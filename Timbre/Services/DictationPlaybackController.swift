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
    func mute(of device: AudioOutputDevice) -> Bool?
    func canSetMute(of device: AudioOutputDevice) -> Bool
    func setMute(_ muted: Bool, of device: AudioOutputDevice) -> OSStatus
    func startMonitoring(
        onDevicesChanged: @escaping @MainActor () -> Void,
        onDefaultOutputChanged: @escaping @MainActor () -> Void
    )
    func startMonitoringPlaybackState(
        of device: AudioOutputDevice,
        onChanged: @escaping @MainActor () -> Void
    )
    func stopMonitoringPlaybackState()
    func stopMonitoring()
}

@MainActor
final class CoreAudioOutputHardware: AudioOutputHardwareProviding {
    private var devicesListener: AudioObjectPropertyListenerBlock?
    private var defaultOutputListener: AudioObjectPropertyListenerBlock?
    private var playbackStateListeners: [(
        deviceID: AudioDeviceID,
        address: AudioObjectPropertyAddress,
        block: AudioObjectPropertyListenerBlock
    )] = []

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
        )
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
        stopMonitoringPlaybackState()
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

    func startMonitoringPlaybackState(
        of device: AudioOutputDevice,
        onChanged: @escaping @MainActor () -> Void
    ) {
        stopMonitoringPlaybackState()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(device.audioDeviceID, &address) else {
            return
        }
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            Task { @MainActor in onChanged() }
        }
        guard AudioObjectAddPropertyListenerBlock(
            device.audioDeviceID,
            &address,
            DispatchQueue.main,
            block
        ) == noErr else {
            return
        }
        playbackStateListeners.append((device.audioDeviceID, address, block))
    }

    func stopMonitoringPlaybackState() {
        for listener in playbackStateListeners {
            var address = listener.address
            AudioObjectRemovePropertyListenerBlock(
                listener.deviceID,
                &address,
                DispatchQueue.main,
                listener.block
            )
        }
        playbackStateListeners.removeAll()
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

private struct MuteRestorationRecord: Codable, Equatable {
    let deviceUID: String
    // Optional so records written by the removed volume mode decode and are
    // discarded safely on the next launch.
    let originalMute: Bool?
    let appliedMute: Bool?
}

@MainActor
final class DictationPlaybackController:
    ObservableObject,
    DictationPlaybackControlling
{
    static let restorationRecordsKey = "timbre.playbackRestorationRecords"

    @Published private(set) var isCurrentOutputControllable = true

    private let preferences: any AppPreferencesProviding
    private let defaults: UserDefaults
    private let hardware: any AudioOutputHardwareProviding
    private var isListening = false
    private var activeDeviceUID: String?
    private var activePlaybackMode: PlaybackDuringDictation?
    private var preferenceObservation: AnyCancellable?
    private var stabilizationTask: Task<Void, Never>?
    private var restorationRetryTask: Task<Void, Never>?

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
        restorationRetryTask?.cancel()
        restorationRetryTask = nil

        // Snapshot the policy for this hotkey session. Keep Unchanged must not
        // arm mute transactions or device handlers — mic-open route churn can
        // otherwise poke output controls and cause a brief audible glitch.
        let mode = preferences.playbackDuringDictation
        guard mode == .mute else {
            activePlaybackMode = nil
            activeDeviceUID = nil
            // Compare-before-write restore only; never applies a new mute.
            recoverPendingRecords()
            scheduleRestorationRetriesIfNeeded()
            refreshSupport()
            return
        }

        activePlaybackMode = mode
        isListening = true
        recoverPendingRecords()
        applyToCurrentOutput()
    }

    func endListening() {
        stabilizationTask?.cancel()
        stabilizationTask = nil
        hardware.stopMonitoringPlaybackState()
        isListening = false
        activeDeviceUID = nil
        activePlaybackMode = nil
        // Safe for Keep Unchanged: restores only hotkey-owned mute records.
        recoverPendingRecords()
        refreshSupport()
        scheduleRestorationRetriesIfNeeded()
    }

    func shutdownForTermination() {
        restorationRetryTask?.cancel()
        restorationRetryTask = nil
        endListening()
        restorationRetryTask?.cancel()
        restorationRetryTask = nil
        hardware.stopMonitoring()
    }

    private func applyToCurrentOutput() {
        // Mute writes are only valid while a hotkey-owned mute transaction is
        // active. Never fall back to the live preference here — a settings
        // change mid-session must not start muting under Keep Unchanged.
        guard isListening, activePlaybackMode == .mute else {
            isCurrentOutputControllable = true
            return
        }
        guard let device = hardware.currentDefaultOutput() else {
            isCurrentOutputControllable = false
            return
        }

        guard hardware.canSetMute(of: device),
              let originalMute = hardware.mute(of: device)
        else {
            reportUnsupported(
                "current output cannot be muted in software; leaving playback unchanged."
            )
            return
        }
        if !applyMute(startingAt: originalMute, device: device) {
            reportApplyFailure(mode: .mute, status: nil)
        }
    }

    private func applyMute(
        startingAt originalMute: Bool,
        device: AudioOutputDevice
    ) -> Bool {
        if originalMute {
            upsert(
                MuteRestorationRecord(
                    deviceUID: device.uid,
                    originalMute: originalMute,
                    appliedMute: true
                )
            )
            markApplied(to: device)
            return true
        }

        let record = MuteRestorationRecord(
            deviceUID: device.uid,
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
                // Put it back best-effort and leave playback unchanged.
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

    private func markApplied(to device: AudioOutputDevice) {
        activeDeviceUID = device.uid
        isCurrentOutputControllable = true
        hardware.startMonitoringPlaybackState(of: device) { [weak self] in
            self?.handlePlaybackStateChange(for: device.uid)
        }
        scheduleStabilization(for: device.uid)
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
        var retained: [MuteRestorationRecord] = []
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
        _ record: MuteRestorationRecord,
        device: AudioOutputDevice
    ) -> Bool {
        if let appliedMute = record.appliedMute,
           let originalMute = record.originalMute
        {
            guard let currentMute = hardware.mute(of: device) else { return true }
            guard currentMute == appliedMute else {
                return true
            }
            guard currentMute != originalMute else {
                return true
            }
            guard hardware.setMute(originalMute, of: device) == noErr else {
                return false
            }
            return hardware.mute(of: device) == originalMute
        }
        return true
    }

    private func handleDefaultOutputChange() {
        // Output notifications can arrive while AVAudioEngine is opening the
        // microphone. Only a live mute transaction may touch output controls.
        guard hasActiveMuteTransaction else { return }

        guard let currentDevice = hardware.currentDefaultOutput() else {
            isCurrentOutputControllable = false
            return
        }
        // Core Audio may announce the same default output while a Bluetooth
        // route settles. Unmuting and immediately re-muting in that case can
        // cause an audible glitch and lose the true original.
        guard currentDevice.uid != activeDeviceUID else { return }

        stabilizationTask?.cancel()
        stabilizationTask = nil
        hardware.stopMonitoringPlaybackState()
        activeDeviceUID = nil
        recoverPendingRecords()
        applyToCurrentOutput()
    }

    private func handleDeviceListChange() {
        // Device-list notifications are global and commonly occur while an
        // app opens a microphone. Idle and Keep Unchanged sessions must not
        // touch output controls or interfere with input-route negotiation.
        guard hasActiveMuteTransaction else { return }

        if let activeDeviceUID,
           hardware.outputDevice(forUID: activeDeviceUID) == nil {
            stabilizationTask?.cancel()
            stabilizationTask = nil
            hardware.stopMonitoringPlaybackState()
            self.activeDeviceUID = nil
            applyToCurrentOutput()
        } else {
            refreshSupport()
        }
    }

    private func handlePlaybackStateChange(for deviceUID: String) {
        guard
            hasActiveMuteTransaction,
            activeDeviceUID == deviceUID,
            hardware.currentDefaultOutput()?.uid == deviceUID
        else {
            return
        }
        stabilizePlayback(on: deviceUID)
    }

    /// True only while mute mode owns the current hotkey listening session.
    private var hasActiveMuteTransaction: Bool {
        isListening && activePlaybackMode == .mute
    }

    /// Some outputs accept a mute write, report it back, then replace it while
    /// their route is still settling. Verify for a bounded startup window and
    /// reapply the existing transaction without replacing its saved original.
    private func scheduleStabilization(for deviceUID: String) {
        stabilizationTask?.cancel()
        stabilizationTask = Task { [weak self] in
            let delays: [UInt64] = [
                120_000_000,
                380_000_000,
                900_000_000,
                1_800_000_000,
            ]
            for delay in delays {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
                guard let self, self.hasActiveMuteTransaction,
                      self.activeDeviceUID == deviceUID
                else {
                    return
                }
                self.stabilizePlayback(on: deviceUID)
            }
        }
    }

    private func stabilizePlayback(on deviceUID: String) {
        guard
            hasActiveMuteTransaction,
            activeDeviceUID == deviceUID,
            hardware.currentDefaultOutput()?.uid == deviceUID,
            let device = hardware.outputDevice(forUID: deviceUID),
            let record = loadRecords().first(where: { $0.deviceUID == deviceUID })
        else {
            return
        }

        guard let expectedMute = record.appliedMute else { return }
        guard hardware.mute(of: device) != expectedMute else { return }
        let status = hardware.setMute(expectedMute, of: device)
        guard status == noErr, hardware.mute(of: device) == expectedMute else {
            reportApplyFailure(mode: .mute, status: status)
            return
        }
        isCurrentOutputControllable = true
    }

    /// Unmute writes can also settle asynchronously. Retrying only saved
    /// hotkey-owned transactions fixes a stuck mute while compare-before-write
    /// continues to protect later manual changes.
    private func scheduleRestorationRetriesIfNeeded() {
        restorationRetryTask?.cancel()
        guard !loadRecords().isEmpty else {
            restorationRetryTask = nil
            return
        }

        restorationRetryTask = Task { [weak self] in
            let delays: [UInt64] = [
                120_000_000,
                380_000_000,
                900_000_000,
                1_800_000_000,
            ]
            for delay in delays {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
                guard let self, !self.isListening else { return }
                self.recoverPendingRecords()
                if self.loadRecords().isEmpty {
                    self.restorationRetryTask = nil
                    return
                }
            }
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
        case .mute:
            isCurrentOutputControllable = hardware.canSetMute(of: device)
        }
    }

    private func reportUnsupported(_ message: String) {
        isCurrentOutputControllable = false
        TimbreLog.line("Timbre playback: \(message)")
    }

    private func upsert(_ record: MuteRestorationRecord) {
        var records = loadRecords()
        records.removeAll { $0.deviceUID == record.deviceUID }
        records.append(record)
        saveRecords(records)
    }

    private func removeRecord(for uid: String) {
        saveRecords(loadRecords().filter { $0.deviceUID != uid })
    }

    private func loadRecords() -> [MuteRestorationRecord] {
        guard let data = defaults.data(forKey: Self.restorationRecordsKey) else {
            return []
        }
        return (try? JSONDecoder().decode([MuteRestorationRecord].self, from: data))
            ?? []
    }

    private func saveRecords(_ records: [MuteRestorationRecord]) {
        guard !records.isEmpty else {
            defaults.removeObject(forKey: Self.restorationRecordsKey)
            return
        }
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: Self.restorationRecordsKey)
    }
}
