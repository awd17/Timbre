import AVFoundation
import Foundation
import Speech

/// Apple Speech + AVAudioEngine transcription. Replaceable via `TranscriptionServicing`.
@MainActor
final class SpeechRecognitionService: TranscriptionServicing {
    private let locale: Locale
    private let speechRecognizer: SFSpeechRecognizer?

    private var session: TranscriptionSession?
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var hasInstalledTap = false
    private var stopTimeoutTask: Task<Void, Never>?

    init(locale: Locale = .current) {
        self.locale = locale
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

    func start(onPartialResult: @escaping @MainActor (String) -> Void) async throws {
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

        let engine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if #available(macOS 13, *) {
            request.addsPunctuation = true
        }

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            await tearDown(invalidateSession: true)
            throw TranscriptionError.audioEngineFailed
        }

        // Capture the request locally so the tap never races assignment onto `self`.
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        hasInstalledTap = true
        audioEngine = engine
        recognitionRequest = request

        engine.prepare()
        do {
            try engine.start()
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
                removeTapIfNeeded()
                audioEngine?.stop()

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
        return text
    }

    func cancel() async {
        await tearDown(invalidateSession: true)
    }

    deinit {
        stopTimeoutTask?.cancel()
        recognitionTask?.cancel()
        if hasInstalledTap {
            audioEngine?.inputNode.removeTap(onBus: 0)
        }
        audioEngine?.stop()
    }

    // MARK: - Private

    private func tearDown(invalidateSession: Bool) async {
        stopTimeoutTask?.cancel()
        stopTimeoutTask = nil

        if invalidateSession {
            session?.invalidate(resumeWithCancellation: true)
            session = nil
        }

        removeTapIfNeeded()
        audioEngine?.stop()
        audioEngine = nil
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
    }

    private func removeTapIfNeeded() {
        guard hasInstalledTap else { return }
        audioEngine?.inputNode.removeTap(onBus: 0)
        hasInstalledTap = false
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
