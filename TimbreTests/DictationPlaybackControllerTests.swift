import CoreAudio
import Foundation
@testable import Timbre
import XCTest

@MainActor
private final class FakeAudioOutputHardware: AudioOutputHardwareProviding {
    var defaultUID: String?
    var devices: [String: AudioOutputDevice] = [:]
    var mutes: [String: Bool] = [:]
    var muteSettable: Set<String> = []
    var muteWrites: [(String, Bool)] = []
    var muteWriteStatuses: [OSStatus] = []
    private(set) var stopMonitoringCount = 0
    private(set) var currentDefaultOutputCallCount = 0
    private(set) var canSetMuteCallCount = 0

    private var onDevicesChanged: (@MainActor () -> Void)?
    private var onDefaultOutputChanged: (@MainActor () -> Void)?
    private var onPlaybackStateChanged: (@MainActor () -> Void)?

    func addDevice(
        uid: String,
        id: AudioDeviceID,
        mute: Bool? = nil,
        canSetMute: Bool = true
    ) {
        devices[uid] = AudioOutputDevice(audioDeviceID: id, uid: uid)
        mutes[uid] = mute
        if canSetMute, mute != nil {
            muteSettable.insert(uid)
        }
    }

    func currentDefaultOutput() -> AudioOutputDevice? {
        currentDefaultOutputCallCount += 1
        return defaultUID.flatMap { devices[$0] }
    }

    func outputDevice(forUID uid: String) -> AudioOutputDevice? {
        devices[uid]
    }

    func mute(of device: AudioOutputDevice) -> Bool? {
        mutes[device.uid]
    }

    func canSetMute(of device: AudioOutputDevice) -> Bool {
        canSetMuteCallCount += 1
        return muteSettable.contains(device.uid)
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
        onPlaybackStateChanged = nil
    }

    func startMonitoringPlaybackState(
        of device: AudioOutputDevice,
        onChanged: @escaping @MainActor () -> Void
    ) {
        _ = device
        onPlaybackStateChanged = onChanged
    }

    func stopMonitoringPlaybackState() {
        onPlaybackStateChanged = nil
    }

    func changeDefaultOutput(to uid: String?) {
        defaultUID = uid
        onDefaultOutputChanged?()
    }

    func announceDeviceChange() {
        onDevicesChanged?()
    }

    func announcePlaybackStateChange() {
        onPlaybackStateChanged?()
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
        let hardware = makeHardware()
        let controller = makeController(preferences, hardware)

        controller.beginListening()
        controller.endListening()

        XCTAssertTrue(hardware.muteWrites.isEmpty)
        XCTAssertNil(defaults.data(forKey: DictationPlaybackController.restorationRecordsKey))
    }

    func testMuteUsesMuteControlAndRestoresIt() {
        let preferences = InMemoryAppPreferences(playbackDuringDictation: .mute)
        let hardware = makeHardware()
        let controller = makeController(preferences, hardware)

        controller.beginListening()
        XCTAssertEqual(hardware.mutes["one"], true)
        XCTAssertNotNil(defaults.data(forKey: DictationPlaybackController.restorationRecordsKey))

        controller.endListening()
        XCTAssertEqual(hardware.mutes["one"], false)
        XCTAssertNil(defaults.data(forKey: DictationPlaybackController.restorationRecordsKey))
    }

    func testAlreadyMutedOutputIsLeftUnchanged() {
        let preferences = InMemoryAppPreferences(playbackDuringDictation: .mute)
        let hardware = makeHardware(mute: true)
        let controller = makeController(preferences, hardware)

        controller.beginListening()
        XCTAssertNotNil(defaults.data(forKey: DictationPlaybackController.restorationRecordsKey))
        controller.endListening()

        XCTAssertEqual(hardware.mutes["one"], true)
        XCTAssertTrue(hardware.muteWrites.isEmpty)
        XCTAssertNil(defaults.data(forKey: DictationPlaybackController.restorationRecordsKey))
    }

    func testInitiallyMutedOutputIsRemutedIfRouteSettlesUnmuted() {
        let preferences = InMemoryAppPreferences(playbackDuringDictation: .mute)
        let hardware = makeHardware(mute: true)
        let controller = makeController(preferences, hardware)

        controller.beginListening()
        hardware.mutes["one"] = false
        hardware.announcePlaybackStateChange()

        XCTAssertEqual(hardware.mutes["one"], true)
        XCTAssertEqual(hardware.muteWrites.count, 1)
        XCTAssertEqual(hardware.muteWrites.first?.0, "one")
        XCTAssertEqual(hardware.muteWrites.first?.1, true)

        controller.endListening()

        XCTAssertEqual(hardware.mutes["one"], true)
        XCTAssertEqual(hardware.muteWrites.count, 1)
        XCTAssertNil(defaults.data(forKey: DictationPlaybackController.restorationRecordsKey))
    }

    func testRejectedMuteWriteLeavesOutputUnchanged() {
        let preferences = InMemoryAppPreferences(playbackDuringDictation: .mute)
        let hardware = makeHardware()
        hardware.muteWriteStatuses = [kAudioHardwareUnspecifiedError]
        let controller = makeController(preferences, hardware)

        controller.beginListening()

        XCTAssertEqual(hardware.mutes["one"], false)
        XCTAssertFalse(controller.isCurrentOutputControllable)
        XCTAssertTrue(hardware.muteWrites.isEmpty)
        XCTAssertNil(defaults.data(forKey: DictationPlaybackController.restorationRecordsKey))
    }

    func testDefaultOutputChangeRestoresOldAndMutesNewOutput() {
        let preferences = InMemoryAppPreferences(playbackDuringDictation: .mute)
        let hardware = makeHardware()
        hardware.addDevice(uid: "two", id: 2, mute: false)
        let controller = makeController(preferences, hardware)

        controller.beginListening()
        hardware.changeDefaultOutput(to: "two")

        XCTAssertEqual(hardware.mutes["one"], false)
        XCTAssertEqual(hardware.mutes["two"], true)
        controller.endListening()
        XCTAssertEqual(hardware.mutes["two"], false)
    }

    func testDuplicateDefaultOutputNotificationDoesNotRestoreAndReapply() {
        let preferences = InMemoryAppPreferences(playbackDuringDictation: .mute)
        let hardware = makeHardware()
        let controller = makeController(preferences, hardware)

        controller.beginListening()
        XCTAssertEqual(hardware.muteWrites.count, 1)

        hardware.changeDefaultOutput(to: "one")

        XCTAssertEqual(hardware.mutes["one"], true)
        XCTAssertEqual(hardware.muteWrites.count, 1)
    }

    func testIdleHardwareNotificationsNeverWritePlaybackState() {
        let preferences = InMemoryAppPreferences(playbackDuringDictation: .mute)
        let hardware = makeHardware()
        let controller = makeController(preferences, hardware)
        let outputProbeCount = hardware.currentDefaultOutputCallCount
        let muteProbeCount = hardware.canSetMuteCallCount

        hardware.changeDefaultOutput(to: "one")
        hardware.announceDeviceChange()

        XCTAssertEqual(hardware.mutes["one"], false)
        XCTAssertTrue(hardware.muteWrites.isEmpty)
        XCTAssertEqual(hardware.currentDefaultOutputCallCount, outputProbeCount)
        XCTAssertEqual(hardware.canSetMuteCallCount, muteProbeCount)
        withExtendedLifetime(controller) {}
    }

    func testMuteReappliesWhenDeviceRevertsWhileRouteSettles() async {
        let preferences = InMemoryAppPreferences(playbackDuringDictation: .mute)
        let hardware = makeHardware()
        let controller = makeController(preferences, hardware)

        controller.beginListening()
        hardware.mutes["one"] = false

        try? await Task.sleep(nanoseconds: 180_000_000)

        XCTAssertEqual(hardware.mutes["one"], true)
        XCTAssertEqual(hardware.muteWrites.count, 2)
    }

    func testMuteImmediatelyReappliesActiveOutputStateChange() {
        let preferences = InMemoryAppPreferences(playbackDuringDictation: .mute)
        let hardware = makeHardware()
        let controller = makeController(preferences, hardware)

        controller.beginListening()
        hardware.mutes["one"] = false
        hardware.announcePlaybackStateChange()

        XCTAssertEqual(hardware.mutes["one"], true)
        XCTAssertEqual(hardware.muteWrites.count, 2)
    }

    func testIdlePlaybackStateChangeCannotWriteOutput() {
        let preferences = InMemoryAppPreferences(playbackDuringDictation: .mute)
        let hardware = makeHardware()
        let controller = makeController(preferences, hardware)

        controller.beginListening()
        controller.endListening()
        hardware.mutes["one"] = true
        hardware.announcePlaybackStateChange()

        XCTAssertEqual(hardware.mutes["one"], true)
        XCTAssertEqual(hardware.muteWrites.count, 2)
    }

    func testNewControllerRecoversPersistedMute() {
        let preferences = InMemoryAppPreferences(playbackDuringDictation: .mute)
        let hardware = makeHardware()
        var firstController: DictationPlaybackController? = makeController(
            preferences,
            hardware
        )
        firstController?.beginListening()
        XCTAssertEqual(hardware.mutes["one"], true)

        firstController = nil
        let recovered = makeController(preferences, hardware)

        XCTAssertEqual(hardware.mutes["one"], false)
        XCTAssertNil(defaults.data(forKey: DictationPlaybackController.restorationRecordsKey))
        withExtendedLifetime(recovered) {}
    }

    func testUnsupportedOutputLeavesPlaybackUnchanged() {
        let preferences = InMemoryAppPreferences(playbackDuringDictation: .mute)
        let hardware = makeHardware(mute: nil, canSetMute: false)
        let controller = makeController(preferences, hardware)

        controller.beginListening()

        XCTAssertFalse(controller.isCurrentOutputControllable)
        XCTAssertTrue(hardware.muteWrites.isEmpty)
    }

    func testTerminationRestoresSynchronouslyAndStopsMonitoring() {
        let preferences = InMemoryAppPreferences(playbackDuringDictation: .mute)
        let hardware = makeHardware()
        let controller = makeController(preferences, hardware)

        controller.beginListening()
        controller.shutdownForTermination()

        XCTAssertEqual(hardware.mutes["one"], false)
        XCTAssertEqual(hardware.stopMonitoringCount, 1)
    }

    func testFailedRestoreStaysPendingAndRecoversOnNextLaunch() {
        let preferences = InMemoryAppPreferences(playbackDuringDictation: .mute)
        let hardware = makeHardware()
        hardware.muteWriteStatuses = [noErr, kAudioHardwareUnspecifiedError]
        var controller: DictationPlaybackController? = makeController(
            preferences,
            hardware
        )

        controller?.beginListening()
        controller?.endListening()

        XCTAssertEqual(hardware.mutes["one"], true)
        XCTAssertNotNil(defaults.data(forKey: DictationPlaybackController.restorationRecordsKey))

        controller = nil
        let recovered = makeController(preferences, hardware)

        XCTAssertEqual(hardware.mutes["one"], false)
        XCTAssertNil(defaults.data(forKey: DictationPlaybackController.restorationRecordsKey))
        withExtendedLifetime(recovered) {}
    }

    func testFailedUnmuteIsRetriedAfterListeningEnds() async {
        let preferences = InMemoryAppPreferences(playbackDuringDictation: .mute)
        let hardware = makeHardware()
        hardware.muteWriteStatuses = [
            noErr,
            kAudioHardwareUnspecifiedError,
            noErr,
        ]
        let controller = makeController(preferences, hardware)

        controller.beginListening()
        controller.endListening()
        XCTAssertEqual(hardware.mutes["one"], true)

        try? await Task.sleep(nanoseconds: 180_000_000)

        XCTAssertEqual(hardware.mutes["one"], false)
        XCTAssertNil(defaults.data(forKey: DictationPlaybackController.restorationRecordsKey))
    }

    func testAssistantLifecycleAppliesAndRestoresMuteTransaction() async {
        let preferences = InMemoryAppPreferences(playbackDuringDictation: .mute)
        let hardware = makeHardware()
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

        XCTAssertEqual(hardware.mutes["one"], false)
        await assistant.startDictationFromShortcut()
        XCTAssertEqual(hardware.mutes["one"], true)

        await assistant.stopDictation()
        XCTAssertEqual(hardware.mutes["one"], false)
        XCTAssertNil(defaults.data(forKey: DictationPlaybackController.restorationRecordsKey))
    }

    func testCaptureStartFailureNeverChangesPlayback() async {
        let preferences = InMemoryAppPreferences(playbackDuringDictation: .mute)
        let hardware = makeHardware()
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

        await assistant.startDictationFromShortcut()

        XCTAssertEqual(hardware.mutes["one"], false)
        XCTAssertTrue(hardware.muteWrites.isEmpty)
        XCTAssertNil(defaults.data(forKey: DictationPlaybackController.restorationRecordsKey))
    }

    private func makeHardware(
        mute: Bool? = false,
        canSetMute: Bool = true
    ) -> FakeAudioOutputHardware {
        let hardware = FakeAudioOutputHardware()
        hardware.addDevice(
            uid: "one",
            id: 1,
            mute: mute,
            canSetMute: canSetMute
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
