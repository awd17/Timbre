import Foundation

enum CopyFallbackReason: Equatable, Sendable {
    case missingTarget
    case targetTerminated
    case targetIsSelf
    case frontmostChanged
    case accessibilityUntrusted
    case pasteboardChanged
    case eventPostFailed
    case secureInputField
    case ambiguousTargetIdentity
}

enum TranscriptDeliveryFailure: Equatable, Sendable {
    case clipboardUnavailable
    case emptyTranscript
}

enum TranscriptDeliveryResult: Equatable, Sendable {
    case pasteEventPosted
    case copiedByDesign
    case copiedAfterInsertFailure(CopyFallbackReason)
    case failed(TranscriptDeliveryFailure)
    case cancelled
}

/// Session-scoped authorization checked immediately before delivery side effects.
///
/// Delivery implementations may suspend while validating or activating a
/// target. They must re-check this token after suspension and before writing
/// to the clipboard or posting paste events.
@MainActor
final class TranscriptDeliveryCancellationToken {
    private(set) var isCancelled = false

    func cancel() {
        isCancelled = true
    }
}

@MainActor
protocol TranscriptDeliveryServicing {
    func deliver(
        _ transcript: String,
        to target: DictationTargetContext?,
        cancellation: TranscriptDeliveryCancellationToken
    ) async -> TranscriptDeliveryResult
}

extension TranscriptDeliveryServicing {
    func deliver(
        _ transcript: String,
        to target: DictationTargetContext?
    ) async -> TranscriptDeliveryResult {
        await deliver(
            transcript,
            to: target,
            cancellation: TranscriptDeliveryCancellationToken()
        )
    }
}

@MainActor
protocol PasteCommandEventPosting {
    func postCommandV() -> Bool
}

/// Writes the transcript to the pasteboard and never posts Command-V.
/// Used for DEBUG mock, fixture, and UI-test composition.
@MainActor
final class ClipboardOnlyTranscriptDelivery: TranscriptDeliveryServicing {
    private let clipboard: ClipboardServicing

    init(clipboard: ClipboardServicing = ClipboardService()) {
        self.clipboard = clipboard
    }

    func deliver(
        _ transcript: String,
        to target: DictationTargetContext?,
        cancellation: TranscriptDeliveryCancellationToken
    ) async -> TranscriptDeliveryResult {
        _ = target
        guard !cancellation.isCancelled else { return .cancelled }
        guard clipboard.copy(transcript) else {
            return .failed(.clipboardUnavailable)
        }
        TimbreLog.line("Timbre delivery: clipboard-only mode (paste disabled)")
        return .copiedByDesign
    }
}
