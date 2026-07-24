import AppKit
import Foundation

struct PasteboardRepresentationSnapshot: Equatable {
    let type: NSPasteboard.PasteboardType
    let data: Data
}

struct PasteboardItemSnapshot: Equatable {
    let representations: [PasteboardRepresentationSnapshot]
}

struct PasteboardSnapshot: Equatable {
    let items: [PasteboardItemSnapshot]
}

enum PasteboardSnapshotCapture: Equatable {
    case snapshot(PasteboardSnapshot)
    case unavailable
}

struct TrackedTranscriptWrite: Equatable {
    fileprivate let identifier: UUID
    let changeCount: Int
}

enum ClipboardRestorationSkipReason: Equatable {
    case snapshotUnavailable
    case clipboardChanged
    case pasteNotConsumed
}

enum ClipboardRetentionOutcome: Equatable {
    case transcriptIntentionallyRetained
    case previousClipboardRestored
    case restorationSkipped(ClipboardRestorationSkipReason)
    case insertionFailedTranscriptRetained(CopyFallbackReason)
}

@MainActor
protocol TranscriptPasteboardServicing: AnyObject {
    func captureCompleteSnapshot() -> PasteboardSnapshotCapture
    func writeTranscript(
        _ transcript: String,
        restorationSnapshot: PasteboardSnapshot?,
        retainedOutcome: ClipboardRetentionOutcome,
        onOutcome: @escaping (ClipboardRetentionOutcome) -> Void
    ) -> TrackedTranscriptWrite?
    func isCurrentWriteUnchanged(_ write: TrackedTranscriptWrite) -> Bool
    func cancelRestoration(
        for write: TrackedTranscriptWrite,
        outcome: ClipboardRetentionOutcome
    )
}

@MainActor
final class TranscriptPasteboardService: TranscriptPasteboardServicing {
    static let maximumSnapshotBytes = 64 * 1_024 * 1_024

    private struct PendingTransaction {
        let write: TrackedTranscriptWrite
        let snapshot: PasteboardSnapshot
        let provider: TranscriptPasteboardDataProvider
        let onOutcome: (ClipboardRetentionOutcome) -> Void
        var expectedChangeCount: Int
        var wasConsumed = false
    }

    private let pasteboard: NSPasteboard
    private let restorationGracePeriod: Duration
    private var transactions: [UUID: PendingTransaction] = [:]

    init(
        pasteboard: NSPasteboard = .general,
        restorationGracePeriod: Duration = .milliseconds(150)
    ) {
        self.pasteboard = pasteboard
        self.restorationGracePeriod = restorationGracePeriod
    }

    func captureCompleteSnapshot() -> PasteboardSnapshotCapture {
        let startingChangeCount = pasteboard.changeCount
        let sourceItems = pasteboard.pasteboardItems ?? []
        var totalBytes = 0
        var itemSnapshots: [PasteboardItemSnapshot] = []

        for sourceItem in sourceItems {
            var representations: [PasteboardRepresentationSnapshot] = []
            for type in sourceItem.types {
                guard let data = sourceItem.data(forType: type) else {
                    return .unavailable
                }
                totalBytes += data.count
                guard totalBytes <= Self.maximumSnapshotBytes else {
                    return .unavailable
                }
                representations.append(
                    PasteboardRepresentationSnapshot(type: type, data: data)
                )
            }
            itemSnapshots.append(PasteboardItemSnapshot(representations: representations))
        }

        guard pasteboard.changeCount == startingChangeCount else {
            return .unavailable
        }
        return .snapshot(PasteboardSnapshot(items: itemSnapshots))
    }

    func writeTranscript(
        _ transcript: String,
        restorationSnapshot: PasteboardSnapshot?,
        retainedOutcome: ClipboardRetentionOutcome,
        onOutcome: @escaping (ClipboardRetentionOutcome) -> Void
    ) -> TrackedTranscriptWrite? {
        guard !transcript.isEmpty else { return nil }

        if let restorationSnapshot {
            let identifier = UUID()
            let provider = TranscriptPasteboardDataProvider(
                transcript: transcript,
                identifier: identifier,
                pasteboard: pasteboard,
                owner: self
            )
            let item = NSPasteboardItem()
            guard item.setDataProvider(provider, forTypes: [.string]) else {
                return nil
            }
            pasteboard.clearContents()
            guard pasteboard.writeObjects([item]) else {
                return nil
            }
            let write = TrackedTranscriptWrite(
                identifier: identifier,
                changeCount: pasteboard.changeCount
            )
            transactions[identifier] = PendingTransaction(
                write: write,
                snapshot: restorationSnapshot,
                provider: provider,
                onOutcome: onOutcome,
                expectedChangeCount: write.changeCount
            )
            return write
        }

        pasteboard.clearContents()
        guard pasteboard.setString(transcript, forType: .string) else {
            return nil
        }
        let write = TrackedTranscriptWrite(
            identifier: UUID(),
            changeCount: pasteboard.changeCount
        )
        onOutcome(retainedOutcome)
        log(retainedOutcome)
        return write
    }

    func isCurrentWriteUnchanged(_ write: TrackedTranscriptWrite) -> Bool {
        pasteboard.changeCount == write.changeCount
    }

    func cancelRestoration(
        for write: TrackedTranscriptWrite,
        outcome: ClipboardRetentionOutcome
    ) {
        guard let transaction = transactions.removeValue(forKey: write.identifier) else {
            log(outcome)
            return
        }
        transaction.onOutcome(outcome)
        log(outcome)
    }

    fileprivate func transcriptWasRequested(identifier: UUID, changeCount: Int) {
        guard var transaction = transactions[identifier] else { return }
        transaction.wasConsumed = true
        // AppKit may advance the generation when it materializes promised data.
        // Capture that generation at the point of consumption so the later
        // restoration still rejects any subsequent external clipboard write.
        transaction.expectedChangeCount = changeCount
        transactions[identifier] = transaction

        Task { @MainActor [weak self] in
            // Some editors inspect the promised value before committing the
            // paste on a later run-loop turn. Keep it available briefly, then
            // re-check ownership before restoring.
            if let restorationGracePeriod = self?.restorationGracePeriod {
                try? await Task.sleep(for: restorationGracePeriod)
            }
            self?.restoreAfterConsumption(identifier: identifier)
        }
    }

    fileprivate func providerFinished(identifier: UUID) {
        // AppKit can report provider completion reentrantly while the promised
        // value is being materialized. Give the consumption callback one main
        // actor turn to mark the transaction before treating this as lost
        // ownership.
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.finishProviderIfUnconsumed(identifier: identifier)
        }
    }

    private func finishProviderIfUnconsumed(identifier: UUID) {
        guard let transaction = transactions[identifier],
              !transaction.wasConsumed
        else {
            return
        }
        transactions.removeValue(forKey: identifier)
        let outcome = ClipboardRetentionOutcome.restorationSkipped(.clipboardChanged)
        transaction.onOutcome(outcome)
        log(outcome)
    }

    private func restoreAfterConsumption(identifier: UUID) {
        guard let transaction = transactions.removeValue(forKey: identifier) else {
            return
        }
        guard pasteboard.changeCount == transaction.expectedChangeCount else {
            let outcome = ClipboardRetentionOutcome.restorationSkipped(.clipboardChanged)
            transaction.onOutcome(outcome)
            log(outcome)
            return
        }

        let restoredItems = transaction.snapshot.items.map { snapshot in
            let item = NSPasteboardItem()
            for representation in snapshot.representations {
                item.setData(representation.data, forType: representation.type)
            }
            return item
        }

        pasteboard.clearContents()
        let restored = restoredItems.isEmpty || pasteboard.writeObjects(restoredItems)
        let outcome: ClipboardRetentionOutcome = restored
            ? .previousClipboardRestored
            : .restorationSkipped(.snapshotUnavailable)
        transaction.onOutcome(outcome)
        log(outcome)
    }

    private func log(_ outcome: ClipboardRetentionOutcome) {
        switch outcome {
        case .transcriptIntentionallyRetained:
            TimbreLog.line("Timbre clipboard: transcript intentionally retained")
        case .previousClipboardRestored:
            TimbreLog.line("Timbre clipboard: previous contents restored")
        case .restorationSkipped(.snapshotUnavailable):
            TimbreLog.line("Timbre clipboard: restoration skipped (snapshot unavailable)")
        case .restorationSkipped(.clipboardChanged):
            TimbreLog.line("Timbre clipboard: restoration skipped (clipboard changed)")
        case .restorationSkipped(.pasteNotConsumed):
            TimbreLog.line("Timbre clipboard: restoration skipped (paste not consumed)")
        case .insertionFailedTranscriptRetained(let reason):
            TimbreLog.line(
                "Timbre clipboard: insertion failed; transcript retained (\(reason))"
            )
        }
    }
}

private final class TranscriptPasteboardDataProvider:
    NSObject,
    NSPasteboardItemDataProvider
{
    private let transcript: String
    private let identifier: UUID
    private let pasteboard: NSPasteboard
    private weak var owner: TranscriptPasteboardService?

    init(
        transcript: String,
        identifier: UUID,
        pasteboard: NSPasteboard,
        owner: TranscriptPasteboardService
    ) {
        self.transcript = transcript
        self.identifier = identifier
        self.pasteboard = pasteboard
        self.owner = owner
    }

    nonisolated func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        guard type == .string else { return }
        item.setString(transcript, forType: .string)
        let materializedChangeCount = self.pasteboard.changeCount
        Task { @MainActor [weak owner] in
            owner?.transcriptWasRequested(
                identifier: identifier,
                changeCount: materializedChangeCount
            )
        }
    }

    nonisolated func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {
        Task { @MainActor [weak owner] in
            owner?.providerFinished(identifier: identifier)
        }
    }
}
