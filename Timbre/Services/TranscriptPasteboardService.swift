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
    func pasteWasPosted(for write: TrackedTranscriptWrite)
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
        let onOutcome: (ClipboardRetentionOutcome) -> Void
        var restorationScheduled = false
    }

    private let pasteboard: NSPasteboard
    private let restorationGracePeriod: Duration
    private var transactions: [UUID: PendingTransaction] = [:]

    init(
        pasteboard: NSPasteboard = .general,
        restorationGracePeriod: Duration = .milliseconds(500)
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
            let item = NSPasteboardItem()
            guard item.setString(transcript, forType: .string) else {
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
                onOutcome: onOutcome
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

    func pasteWasPosted(for write: TrackedTranscriptWrite) {
        guard var transaction = transactions[write.identifier],
              !transaction.restorationScheduled
        else {
            return
        }
        transaction.restorationScheduled = true
        transactions[write.identifier] = transaction

        Task { @MainActor [weak self] in
            // CGEvent posting is asynchronous. Keep the eager plain-text value
            // available while the destination app handles Command-V, then
            // restore only if nobody else has changed the clipboard.
            if let restorationGracePeriod = self?.restorationGracePeriod {
                try? await Task.sleep(for: restorationGracePeriod)
            }
            self?.restoreAfterPaste(identifier: write.identifier)
        }
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

    private func restoreAfterPaste(identifier: UUID) {
        guard let transaction = transactions.removeValue(forKey: identifier) else {
            return
        }
        guard pasteboard.changeCount == transaction.write.changeCount else {
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
