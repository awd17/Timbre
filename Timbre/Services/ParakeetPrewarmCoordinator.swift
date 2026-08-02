import Foundation

@MainActor
final class ParakeetPrewarmCoordinator {
    enum Source: String {
        case launchReadiness
        case setupReadinessChanged
    }

    static let disableArgument = "--disable-model-prewarm"

    private let modelManager: any ParakeetModelManaging
    private let isEligible: () -> Bool
    private let isParakeetProductionBackend: Bool
    private let disablePrewarm: Bool
    private let onModelStateChanged: () -> Void

    private var wasEligible = false
    private var awaitTask: Task<Void, Never>?
    private var runID = 0

    var isAwaitingPrewarm: Bool {
        awaitTask != nil
    }

    init(
        modelManager: any ParakeetModelManaging,
        isEligible: @escaping () -> Bool,
        isParakeetProductionBackend: Bool,
        disablePrewarm: Bool = false,
        onModelStateChanged: @escaping () -> Void = {}
    ) {
        self.modelManager = modelManager
        self.isEligible = isEligible
        self.isParakeetProductionBackend = isParakeetProductionBackend
        self.onModelStateChanged = onModelStateChanged
#if DEBUG
        self.disablePrewarm = disablePrewarm
#else
        self.disablePrewarm = false
#endif
    }

    deinit {
        awaitTask?.cancel()
    }

    static func shouldDisablePrewarm(arguments: [String], isDebug: Bool) -> Bool {
        guard isDebug else { return false }
#if DEBUG
        return arguments.contains(disableArgument)
#else
        return false
#endif
    }

    func evaluate(source: Source) {
        let eligible = computeEligibility()
        defer { wasEligible = eligible.isEligible }

        guard eligible.isEligible else {
            if wasEligible {
                TimbreLog.line(
                    "Timbre prewarm: no longer eligible (\(source.rawValue); \(eligible.reason))."
                )
            } else {
                TimbreLog.line(
                    "Timbre prewarm: not eligible (\(source.rawValue); \(eligible.reason))."
                )
            }
            return
        }

        guard !wasEligible else {
            TimbreLog.line("Timbre prewarm: duplicate trigger ignored (\(source.rawValue)).")
            return
        }

        guard awaitTask == nil else {
            TimbreLog.line("Timbre prewarm: already in flight (\(source.rawValue)).")
            return
        }

        if modelManager.state.isLoaded {
            TimbreLog.line("Timbre prewarm: already loaded (\(source.rawValue)).")
            return
        }

        runID += 1
        let currentRunID = runID
        let startedAt = Date()
        TimbreLog.line("Timbre prewarm: requested (\(source.rawValue)).")

        // Unstructured load task: cancelling the coordinator await must not cancel this work.
        let prewarmTask = Task(priority: .userInitiated) { @MainActor [modelManager] in
            try await modelManager.loadInstalledAndRetain()
        }

        awaitTask = Task { [weak self] in
            do {
                try await prewarmTask.value
                let seconds = Date().timeIntervalSince(startedAt)
                self?.finishRun(
                    currentRunID,
                    message: String(format: "Timbre prewarm: completed in %.2fs.", seconds)
                )
            } catch is CancellationError {
                self?.finishRun(currentRunID, message: "Timbre prewarm: await cancelled.")
            } catch {
                self?.finishRun(
                    currentRunID,
                    message: "Timbre prewarm: failed (\(error.localizedDescription))."
                )
            }
        }
    }

    private struct Eligibility {
        let isEligible: Bool
        let reason: String
    }

    private func computeEligibility() -> Eligibility {
        if disablePrewarm {
            return Eligibility(isEligible: false, reason: "prewarm disabled")
        }
        if !isParakeetProductionBackend {
            return Eligibility(isEligible: false, reason: "non-production backend")
        }
        if !isEligible() {
            return Eligibility(isEligible: false, reason: "model not ready")
        }
        return Eligibility(isEligible: true, reason: "ready")
    }

    func cancel() {
        runID += 1
        awaitTask?.cancel()
        awaitTask = nil
        wasEligible = false
    }

    private func finishRun(_ id: Int, message: String) {
        guard runID == id else { return }
        TimbreLog.line(message)
        awaitTask = nil
        onModelStateChanged()
    }
}
