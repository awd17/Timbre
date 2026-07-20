import Foundation
@testable import Timbre
import XCTest

@MainActor
final class FakeParakeetModelManager: ParakeetModelManaging {
    private(set) var state: ModelPreparationState
    private(set) var progress: ModelPreparationProgress = .idle
    private(set) var ensureInstalledCallCount = 0
    private(set) var installOperationCount = 0
    private(set) var unloadCallCount = 0
    private(set) var refreshCallCount = 0

    var ensureInstalledHandler: (() async throws -> Void)?
    var suspendsInstallation = false

    private var installTask: Task<Void, Error>?
    private var installStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var installationGate: CheckedContinuation<Void, Never>?
    private var installationMayProceed = false

    init(initialState: ModelPreparationState = .notInstalled) {
        self.state = initialState
    }

    func refreshAvailability() {
        refreshCallCount += 1
    }

    func ensureInstalled() async throws {
        ensureInstalledCallCount += 1

        if let installTask {
            try await installTask.value
            return
        }

        let task = Task<Void, Error> { @MainActor in
            self.installOperationCount += 1
            self.state = .downloading
            self.progress = ModelPreparationProgress(
                fraction: 0.1,
                detail: "Downloading…",
                estimatedSecondsRemaining: 120
            )
            let waiters = self.installStartWaiters
            self.installStartWaiters.removeAll()
            waiters.forEach { $0.resume() }

            if self.suspendsInstallation {
                if self.installationMayProceed {
                    self.installationMayProceed = false
                } else {
                    await withCheckedContinuation { continuation in
                        self.installationGate = continuation
                    }
                }
            }
            if let handler = self.ensureInstalledHandler {
                try await handler()
            }
            self.state = .installed
            self.progress = .idle
        }
        installTask = task

        do {
            try await task.value
            installTask = nil
        } catch {
            installTask = nil
            state = .failed(message: "Something went wrong while getting Timbre ready.")
            progress = .idle
            throw error
        }
    }

    func waitForInstallStart() async {
        if installOperationCount > 0 {
            return
        }
        await withCheckedContinuation { continuation in
            installStartWaiters.append(continuation)
        }
    }

    func resumeInstallation() {
        if let installationGate {
            self.installationGate = nil
            installationGate.resume()
        } else {
            installationMayProceed = true
        }
    }

    func unload() {
        unloadCallCount += 1
        if state.isLoaded || state == .loading {
            state = .installed
        }
    }

    func setState(_ newState: ModelPreparationState) {
        state = newState
    }
}

@MainActor
final class FakeMicrophonePermission: MicrophonePermissionProviding {
    var status: MicrophonePermissionStatus
    private(set) var requestCallCount = 0
    private(set) var openSettingsCallCount = 0
    var statusAfterRequest: MicrophonePermissionStatus?

    init(status: MicrophonePermissionStatus = .undetermined) {
        self.status = status
    }

    func requestAccessIfNeeded() async -> MicrophonePermissionStatus {
        requestCallCount += 1
        switch status {
        case .granted, .denied:
            return status
        case .undetermined:
            let next = statusAfterRequest ?? .granted
            status = next
            return next
        }
    }

    func openSystemSettings() {
        openSettingsCallCount += 1
    }
}

@MainActor
final class FakeAccessibilityPermission: AccessibilityPermissionProviding {
    var trustState: AccessibilityTrustState
    private(set) var hasOfferedPrompt: Bool
    private(set) var requestCallCount = 0
    private(set) var openSettingsCallCount = 0
    /// When set, `requestAccessIfNeeded` updates `trustState` to this value.
    var trustAfterRequest: AccessibilityTrustState?

    init(
        trustState: AccessibilityTrustState = .trusted,
        hasOfferedPrompt: Bool = false
    ) {
        self.trustState = trustState
        self.hasOfferedPrompt = hasOfferedPrompt
    }

    func requestAccessIfNeeded() async -> AccessibilityTrustState {
        requestCallCount += 1
        if trustState == .trusted {
            return .trusted
        }
        hasOfferedPrompt = true
        if let trustAfterRequest {
            trustState = trustAfterRequest
        }
        return trustState
    }

    func openSystemSettings() {
        openSettingsCallCount += 1
    }
}
