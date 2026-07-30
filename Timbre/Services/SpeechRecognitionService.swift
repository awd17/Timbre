import AVFoundation
import Foundation
import Speech

/// Apple Speech + input-only HAL capture. Replaceable via `TranscriptionServicing`.
@MainActor
final class SpeechRecognitionService: TranscriptionServicing, TerminationHandling {
    private let locale: Locale
    private let speechRecognizer: SFSpeechRecognizer?
    private let capturer: CoreAudioInputCapturer

    private var session: TranscriptionSession?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var stopTimeoutTask: Task<Void, Never>?
    private var isCapturing = false

    init(
        locale: Locale = .current,
        inputDevices: CoreAudioInputDeviceManager
    ) {
        self.locale = locale
        self.capturer = CoreAudioInputCapturer(inputDevices: inputDevices)
        self.speechRecognizer = SFSpeechRecognizer(locale: locale)
    }

    func prepare() async throws {
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            throw TranscriptionError.notAvailable
        }

        let speechStatus = await requestSpeechAuthorization()
        switch speechStatus {
        case .authorized:
            break
        case .denied, .restricted, .notDetermined:
            throw TranscriptionError.speechPermissionDenied
        @unknown default:
            throw TranscriptionError.speechPermissionDenied
        }

        let micGranted = await requestMicrophonePermission()
        guard micGranted else {
            throw TranscriptionError.microphonePermissionDenied
        }
    }

    func start(
        onPartialResult: @escaping @MainActor (String) -> Void,
        onAudioLevel: @escaping @MainActor (Float) -> Void
    ) async throws {
        if session != nil {
            throw TranscriptionError.alreadyRunning
        }

        guard let speechRecognizer else {
            throw TranscriptionError.notAvailable
        }

        await tearDown(invalidateSession: true)

        let newSession = TranscriptionSession(onPartialResult: onPartialResult)
        let sessionID = newSession.id
        session = newSession

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if #available(macOS 13, *) {
            request.addsPunctuation = true
        }
        recognitionRequest = request

        do {
            _ = try capturer.start(
                onBuffer: { buffer in
                    request.append(buffer)
                },
                onAudioLevel: onAudioLevel
            )
            isCapturing = true
        } catch {
            await tearDown(invalidateSession: true)
            throw TranscriptionError.audioEngineFailed
        }

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                guard let active = self.session, active.id == sessionID, !active.isInvalidated else {
                    return
                }

                if let result {
                    let text = result.bestTranscription.formattedString
                    active.deliverPartial(text)
                    if result.isFinal {
                        active.complete(.success(text))
                    }
                }

                if let error {
                    let fallback = active.latestTranscript
                    if !fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        active.complete(.success(fallback))
                    } else {
                        active.complete(.failure(
                            TranscriptionError.recognitionFailed(error.localizedDescription)
                        ))
                    }
                }
            }
        }
    }

    func stop() async throws -> String {
        guard let activeSession = session, !activeSession.isInvalidated else {
            throw TranscriptionError.notRunning
        }

        let sessionID = activeSession.id

        let stopResult: Result<String, Error>
        do {
            let text: String = try await withCheckedThrowingContinuation { continuation in
                activeSession.beginStopping(continuation)

                recognitionRequest?.endAudio()
                stopCapture()

                stopTimeoutTask?.cancel()
                stopTimeoutTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    guard !Task.isCancelled else { return }
                    guard let current = self.session, current.id == sessionID, !current.isInvalidated else {
                        return
                    }
                    let latest = current.latestTranscript
                    if latest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        current.complete(.failure(TranscriptionError.emptyResult))
                    } else {
                        current.complete(.success(latest))
                    }
                }
            }
            stopResult = .success(text)
        } catch {
            stopResult = .failure(error)
        }

        await tearDown(invalidateSession: true)

        let text = try stopResult.get()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TranscriptionError.emptyResult
        }
        return trimmed
    }

    func cancel() async {
        tearDownSync(invalidateSession: true)
    }

    func shutdownForTermination() {
        tearDownSync(invalidateSession: true)
    }

    deinit {
        stopTimeoutTask?.cancel()
        recognitionTask?.cancel()
    }

    // MARK: - Private

    private func tearDown(invalidateSession: Bool) async {
        tearDownSync(invalidateSession: invalidateSession)
    }

    private func tearDownSync(invalidateSession: Bool) {
        stopTimeoutTask?.cancel()
        stopTimeoutTask = nil

        if invalidateSession {
            session?.invalidate(resumeWithCancellation: true)
            session = nil
        }

        stopCapture()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
    }

    private func stopCapture() {
        guard isCapturing else {
            capturer.stop()
            return
        }
        capturer.stop()
        isCapturing = false
    }

    private func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    private func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}
