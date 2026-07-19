import Foundation
@testable import Timbre
import XCTest

@MainActor
final class FakeParakeetModelManager: ParakeetModelManaging {
    private(set) var state: ModelPreparationState
    private(set) var progress: ModelPreparationProgress = .idle
    private(set) var ensureInstalledCallCount = 0
    private(set) var unloadCallCount = 0
    private(set) var refreshCallCount = 0

    var ensureInstalledHandler: (() async throws -> Void)?
    var delayNanoseconds: UInt64 = 0

    private var installTask: Task<Void, Error>?

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
            self.state = .downloading
            self.progress = ModelPreparationProgress(
                fraction: 0.1,
                detail: "Downloading…",
                estimatedSecondsRemaining: 120
            )
            if self.delayNanoseconds > 0 {
                try await Task.sleep(nanoseconds: self.delayNanoseconds)
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
