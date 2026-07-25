import CoreAudio
import Foundation
@testable import Timbre
import XCTest

@MainActor
private final class FakeAudioOutputHardware: AudioOutputHardwareProviding {
    var defaultUID: String?
    var devices: [String: AudioOutputDevice] = [:]
    var volumes: [String: Float] = [:]
    var mutes: [String: Bool] = [:]
    var volumeSettable: Set<String> = []
    var muteSettable: Set<String> = []
    var volumeWrites: [(String, Float)] = []
    var muteWrites: [(String, Bool)] = []
    var volumeQuantum: Float?
    var volumeWriteStatuses: [OSStatus] = []
    var muteWriteStatuses: [OSStatus] = []
    private(set) var stopMonitoringCount = 0

    private var onDevicesChanged: (@MainActor () -> Void)?
    private var onDefaultOutputChanged: (@MainActor () -> Void)?

    func addDevice(
        uid: String,
        id: AudioDeviceID,
        volume: Float? = nil,
        mute: Bool? = nil,
        canSetVolume: Bool = true,
        canSetMute: Bool = true
    ) {
        devices[uid] = AudioOutputDevice(audioDeviceID: id, uid: uid)
        volumes[uid] = volume
        mutes[uid] = mute
        if canSetVolume, volume != nil {
            volumeSettable.insert(uid)
        }
        if canSetMute, mute != nil {
            muteSettable.insert(uid)
        }
    }

    func currentDefaultOutput() -> AudioOutputDevice? {
        defaultUID.flatMap { devices[$0] }
    }

    func outputDevice(forUID uid: String) -> AudioOutputDevice? {
        devices[uid]
    }

    func volume(of device: AudioOutputDevice) -> Float? {
        volumes[device.uid]
    }

    func canSetVolume(of device: AudioOutputDevice) -> Bool {
        volumeSettable.contains(device.uid)
    }

    func setVolume(_ value: Float, of device: AudioOutputDevice) -> OSStatus {
        guard canSetVolume(of: device) else { return kAudioHardwareUnsupportedOperationError }
        let status = volumeWriteStatuses.isEmpty
            ? noErr
            : volumeWriteStatuses.removeFirst()
        guard status == noErr else { return status }
        if let volumeQuantum {
            volumes[device.uid] = (value / volumeQuantum).rounded() * volumeQuantum
        } else {
            volumes[device.uid] = value
        }
        volumeWrites.append((device.uid, value))
        return noErr
    }

    func mute(of device: AudioOutputDevice) -> Bool? {
        mutes[device.uid]
    }

    func canSetMute(of device: AudioOutputDevice) -> Bool {
        muteSettable.contains(device.uid)
    }

    func setMute(_ muted: Bool, of device: AudioOutputDevice) -> OSStatus {
        guard canSetMute(of: device) else { return kAudioHardwareUnsupportedOperationError }
        let status = muteWriteStatuses.isEmpty
            ? noErr
            : muteWriteStatuses.removeFirst()
        guard status == noErr else { return status }
        mutes[device.uid] = muted
        muteWrites.append((device.uid, muted))
        return noErr
    }

    func startMonitoring(
        onDevicesChanged: @escaping @MainActor () -> Void,
        onDefaultOutputChanged: @escaping @MainActor () -> Void
    ) {
        self.onDevicesChanged = onDevicesChanged
        self.onDefaultOutputChanged = onDefaultOutputChanged
    }

    func stopMonitoring() {
        stopMonitoringCount += 1
        onDevicesChanged = nil
        onDefaultOutputChanged = nil
    }

    func changeDefaultOutput(to uid: String?) {
        defaultUID = uid
        onDefaultOutputChanged?()
    }

    func announceDeviceChange() {
        onDevicesChanged?()
    }
}

@MainActor
final class DictationPlaybackControllerTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "DictationPlaybackControllerTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
    }

    func testKeepUnchangedDoesNotTouchOutput() {
        let preferences = InMemoryAppPreferences(playbackDuringDictation: .keepUnchanged)
        let hardware = makeHardware(volume: 0.8)
        let controller = makeController(preferences, hardware)

        controller.beginListening()
        controller.endListening()

        XCTAssertTrue(hardware.volumeWrites.isEmpty)
        XCTAssertTrue(hardware.muteWrites.isEmpty)
        XCTAssertNil(defaults.data(forKey: DictationPlaybackController.restorationRecordsKey))
    }

    func testLowerUsesQuarterOfStartingVolumeAndRestoresIt() {
        let preferences = InMemoryAppPreferences(playbackDuringDictation: .lower)
        let hardware = makeHardware(volume: 0.8)
        let controller = makeController(preferences, hardware)

        controller.beginListening()
        assertVolume(hardware, uid: "one", equals: 0.2)
        XCTAssertNotNil(defaults.data(forKey: DictationPlaybackController.restorationRecordsKey))

        controller.endListening()
        assertVolume(hardware, uid: "one", equals: 0.8)
        XCTAssertNil(defaults.data(forKey: DictationPlaybackController.restorationRecordsKey))
    }

    func testLowerRecordsHardwareReadbackAndRestoresQuantizedVolume() {
        let preferences = InMemoryAppPreferences(playbackDuringDictation: .lower)
        let hardware = makeHardware(volume: 0.8125)
        hardware.volumeQuantum = 0.0625
        let controller = makeController(preferences, hardware)

        controller.beginListening()
        // 0.8125 × 0.25 requests 0.203125; this device applies 0.1875.
        assertVolume(hardware, uid: "one", equals: 0.1875)

        controller.endListening()
        assertVolume(hardware, uid: "one", equals: 0.8125)
        XCTAssertNil(defaults.data(forKey: DictationPlaybackController.restorationRecordsKey))
    }

    func testMuteUsesMuteControlAndRestoresIt() {
        let preferences = InMemoryAppPreferences(playbackDuringDictation: .mute)
        let hardware = makeHardware(volume: 0.8, mute: false)
        let controller = makeController(preferences, hardware)

        controller.beginListening()
        XCTAssertEqual(hardware.mutes["one"], true)
        XCTAssertTrue(hardware.volumeWrites.isEmpty)

        controller.endListening()
        XCTAssertEqual(hardware.mutes["one"], false)
    }

    func testMuteFallsBackToZeroVolume() {
        let preferences = InMemoryAppPreferences(playbackDuringDictation: .mute)
        let hardware = makeHardware(volume: 0.8, mute: nil)
        let controller = makeController(preferences, hardware)

        controller.beginListening()
        assertVolume(hardware, uid: "one", equals: 0)

        controller.endListening()
        assertVolume(hardware, uid: "one", equals: 0.8)
    }

    func testMuteFallsBackToVolumeWhenAdvertisedMuteControlRejectsWrite() {
        let preferences = InMemoryAppPreferences(playbackDuringDictation: .mute)
        let hardware = makeHardware(volume: 0.8, mute: false)
        hardware.muteWriteStatuses = [kAudioHardwareUnspecifiedError]
        let controller = makeController(preferences, hardware)

        controller.beginListening()
        XCTAssertEqual(hardware.mutes["one"], false)
        assertVolume(hardware, uid: "one", equals: 0)

        controller.endListening()
        assertVolume(hardware, uid: "one", equals: 0.8)
    }

    func testManualVolumeChangeIsNotOverwrittenDuringRestore() {
        let preferences = InMemoryAppPreferences(playbackDuringDictation: .lower)
        let hardware = makeHardware(volume: 0.8)
        let controller = makeController(preferences, hardware)

        controller.beginListening()
        hardware.volumes["one"] = 0.55
        controller.endListening()

        assertVolume(hardware, uid: "one", equals: 0.55)
        XCTAssertNil(defaults.data(forKey: DictationPlaybackController.restorationRecordsKey))
    }

    func testDefaultOutputChangeRestoresOldAndAttenuatesNewOutput() {
        let preferences = InMemoryAppPreferences(playbackDuringDictation: .lower)
        let hardware = makeHardware(volume: 0.8)
        hardware.addDevice(uid: "two", id: 2, volume: 0.6, mute: false)
        let controller = makeController(preferences, hardware)

        controller.beginListening()
        hardware.changeDefaultOutput(to: "two")

        assertVolume(hardware, uid: "one", equals: 0.8)
        assertVolume(hardware, uid: "two", equals: 0.15)

        controller.endListening()
        assertVolume(hardware, uid: "two", equals: 0.6)
    }

    func testNewControllerRecoversPersistedAppliedVolume() {
        let preferences = InMemoryAppPreferences(playbackDuringDictation: .lower)
        let hardware = makeHardware(volume: 0.8)
        var firstController: DictationPlaybackController? = makeController(
            preferences,
            hardware
        )
        firstController?.beginListening()
        assertVolume(hardware, uid: "one", equals: 0.2)

        firstController = nil
        let recovered = makeController(preferences, hardware)

        assertVolume(hardware, uid: "one", equals: 0.8)
        XCTAssertNil(defaults.data(forKey: DictationPlaybackController.restorationRecordsKey))
        withExtendedLifetime(recovered) {}
    }

    func testUnsupportedOutputLeavesPlaybackUnchanged() {
        let preferences = InMemoryAppPreferences(playbackDuringDictation: .lower)
        let hardware = makeHardware(volume: 0.8, canSetVolume: false)
        let controller = makeController(preferences, hardware)

        controller.beginListening()

        XCTAssertFalse(controller.isCurrentOutputControllable)
        assertVolume(hardware, uid: "one", equals: 0.8)
        XCTAssertTrue(hardware.volumeWrites.isEmpty)
    }

    func testTerminationRestoresSynchronouslyAndStopsMonitoring() {
        let preferences = InMemoryAppPreferences(playbackDuringDictation: .lower)
        let hardware = makeHardware(volume: 0.8)
        let controller = makeController(preferences, hardware)

        controller.beginListening()
        controller.shutdownForTermination()

        assertVolume(hardware, uid: "one", equals: 0.8)
        XCTAssertEqual(hardware.stopMonitoringCount, 1)
    }

    func testFailedRestoreStaysPendingAndRecoversOnNextLaunch() {
        let preferences = InMemoryAppPreferences(playbackDuringDictation: .lower)
        let hardware = makeHardware(volume: 0.8)
        hardware.volumeWriteStatuses = [noErr, kAudioHardwareUnspecifiedError]
        var controller: DictationPlaybackController? = makeController(
            preferences,
            hardware
        )

        controller?.beginListening()
        controller?.endListening()

        assertVolume(hardware, uid: "one", equals: 0.2)
        XCTAssertNotNil(defaults.data(forKey: DictationPlaybackController.restorationRecordsKey))

        controller = nil
        let recovered = makeController(preferences, hardware)

        assertVolume(hardware, uid: "one", equals: 0.8)
        XCTAssertNil(defaults.data(forKey: DictationPlaybackController.restorationRecordsKey))
        withExtendedLifetime(recovered) {}
    }

    func testAssistantLifecycleAppliesAndRestoresRealPlaybackTransaction() async {
        let preferences = InMemoryAppPreferences(playbackDuringDictation: .lower)
        let hardware = makeHardware(volume: 0.8)
        let playback = makeController(preferences, hardware)
        let assistant = AssistantController(
            transcription: MockTranscriptionService(
                behavior: .success(final: "Hello", partials: [])
            ),
            clipboard: FakeClipboard(),
            delivery: FakeTranscriptDelivery(result: .pasteEventPosted),
            targetProvider: FakeDictationTargetProvider(),
            playback: playback
        )

        XCTAssertEqual(hardware.volumes["one"], 0.8)
        await assistant.startDictation()
        assertVolume(hardware, uid: "one", equals: 0.2)

        await assistant.stopDictation()
        assertVolume(hardware, uid: "one", equals: 0.8)
        XCTAssertNil(defaults.data(forKey: DictationPlaybackController.restorationRecordsKey))
    }

    func testCaptureStartFailureNeverChangesPlayback() async {
        let preferences = InMemoryAppPreferences(playbackDuringDictation: .mute)
        let hardware = makeHardware(volume: 0.8, mute: false)
        let playback = makeController(preferences, hardware)
        let assistant = AssistantController(
            transcription: MockTranscriptionService(
                behavior: .startFailure(.audioEngineFailed)
            ),
            clipboard: FakeClipboard(),
            delivery: FakeTranscriptDelivery(result: .pasteEventPosted),
            targetProvider: FakeDictationTargetProvider(),
            playback: playback
        )

        await assistant.startDictation()

        XCTAssertEqual(hardware.mutes["one"], false)
        XCTAssertTrue(hardware.volumeWrites.isEmpty)
        XCTAssertTrue(hardware.muteWrites.isEmpty)
        XCTAssertNil(defaults.data(forKey: DictationPlaybackController.restorationRecordsKey))
    }

    private func makeHardware(
        volume: Float,
        mute: Bool? = false,
        canSetVolume: Bool = true
    ) -> FakeAudioOutputHardware {
        let hardware = FakeAudioOutputHardware()
        hardware.addDevice(
            uid: "one",
            id: 1,
            volume: volume,
            mute: mute,
            canSetVolume: canSetVolume
        )
        hardware.defaultUID = "one"
        return hardware
    }

    private func makeController(
        _ preferences: InMemoryAppPreferences,
        _ hardware: FakeAudioOutputHardware
    ) -> DictationPlaybackController {
        DictationPlaybackController(
            preferences: preferences,
            defaults: defaults,
            hardware: hardware
        )
    }

    private func assertVolume(
        _ hardware: FakeAudioOutputHardware,
        uid: String,
        equals expected: Float,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let value = hardware.volumes[uid] else {
            XCTFail("Missing volume for \(uid)", file: file, line: line)
            return
        }
        XCTAssertEqual(value, expected, accuracy: 0.0001, file: file, line: line)
    }
}

@MainActor
final class MicrophoneSelectionResolutionTests: XCTestCase {
    private let builtIn = AudioInputDevice(
        audioDeviceID: 1,
        uid: "built-in",
        name: "Mac Microphone"
    )
    private let usb = AudioInputDevice(
        audioDeviceID: 2,
        uid: "usb",
        name: "USB Microphone"
    )

    func testSystemDefaultResolvesCurrentDefault() {
        XCTAssertEqual(
            CoreAudioInputDeviceManager.resolve(
                .systemDefault,
                among: [builtIn, usb],
                defaultInputDeviceUID: builtIn.uid
            ),
            builtIn
        )
    }

    func testConnectedSavedDeviceWinsOverSystemDefault() {
        XCTAssertEqual(
            CoreAudioInputDeviceManager.resolve(
                usb.selection,
                among: [builtIn, usb],
                defaultInputDeviceUID: builtIn.uid
            ),
            usb
        )
    }

    func testDisconnectedSavedDeviceFallsBackAndReconnects() {
        let selection = usb.selection
        XCTAssertEqual(
            CoreAudioInputDeviceManager.resolve(
                selection,
                among: [builtIn],
                defaultInputDeviceUID: builtIn.uid
            ),
            builtIn
        )
        XCTAssertEqual(
            CoreAudioInputDeviceManager.resolve(
                selection,
                among: [builtIn, usb],
                defaultInputDeviceUID: builtIn.uid
            ),
            usb
        )
    }
}
