import SwiftUI

enum DictationIndicatorPresentation: Equatable {
    case hidden
    case preparing
    case listening
    case processing
    case copied
    case copyFallback
    case failure

    var accessibilityLabel: String {
        switch self {
        case .hidden:
            return ""
        case .preparing:
            return "Preparing dictation"
        case .listening:
            return "Listening"
        case .processing:
            return "Processing dictation"
        case .copied:
            return "Dictation copied"
        case .copyFallback:
            return "Could not insert dictation. Copied to clipboard"
        case .failure:
            return "Dictation failed"
        }
    }

    static func presentation(for state: SessionState) -> Self {
        switch state {
        case .idle:
            return .hidden
        case .preparing:
            return .preparing
        case .listening:
            return .listening
        case .finishing:
            return .processing
        case .completed(_, let outcome):
            switch outcome {
            case .inserted:
                return .hidden
            case .copiedByDesign:
                return .copied
            case .copiedAfterInsertFailure:
                return .copyFallback
            case .deliveryFailed:
                return .failure
            }
        case .failed(let kind, _, _):
            return kind == .noSpeech ? .hidden : .failure
        }
    }
}

@MainActor
@Observable
final class DictationIndicatorViewModel {
    var presentation: DictationIndicatorPresentation = .hidden
}

struct DictationIndicatorView: View {
    @Bindable var controller: AssistantController
    @Bindable var model: DictationIndicatorViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let barWeights: [CGFloat] = [0.34, 0.58, 0.82, 1, 0.82, 0.58, 0.34]

    var body: some View {
        Group {
            if model.presentation == .processing && !reduceMotion {
                TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                    content(at: context.date.timeIntervalSinceReferenceDate)
                }
            } else {
                content(at: 0)
            }
        }
        .frame(width: 84, height: 40)
        .background(
            Color.black.opacity(0.78),
            in: Capsule(style: .continuous)
        )
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(.white.opacity(0.17), lineWidth: 0.75)
        }
        .contentShape(Capsule(style: .continuous))
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("dictationIndicator")
        .accessibilityLabel(model.presentation.accessibilityLabel)
    }

    @ViewBuilder
    private func content(at time: TimeInterval) -> some View {
        switch model.presentation {
        case .preparing, .listening, .processing:
            waveform(at: time)
        case .copied:
            resultSymbol("doc.on.clipboard.fill", color: .green)
        case .copyFallback:
            resultSymbol("doc.on.clipboard.fill", color: .orange)
        case .failure:
            resultSymbol("exclamationmark", color: .red)
        case .hidden:
            EmptyView()
        }
    }

    private func waveform(at time: TimeInterval) -> some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(barWeights.indices, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(waveformColor)
                    .frame(width: 5, height: barHeight(index: index, time: time))
            }
        }
        .frame(width: 53, height: 28)
    }

    private var waveformColor: Color {
        switch model.presentation {
        case .preparing:
            return Color(white: 0.72).opacity(0.9)
        case .listening:
            return Color(red: 0.78, green: 0.91, blue: 1)
        case .processing:
            return Color(red: 0.72, green: 0.67, blue: 1)
        default:
            return .white
        }
    }

    private func barHeight(index: Int, time: TimeInterval) -> CGFloat {
        let weight = barWeights[index]
        switch model.presentation {
        case .preparing:
            return 5 + weight * 5
        case .listening:
            let level = CGFloat(min(max(controller.audioLevel, 0), 1))
            let responsiveLevel = sqrt(level)
            return 4 + weight * (5 + responsiveLevel * 20)
        case .processing:
            guard !reduceMotion else { return 7 + weight * 8 }
            let distance = abs(Double(index) - 3)
            let pulse = CGFloat((sin(time * 7 - distance * 0.9) + 1) / 2)
            return 6 + weight * 6 + pulse * 9
        default:
            return 6
        }
    }

    private func resultSymbol(_ name: String, color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(color)
            .symbolRenderingMode(.monochrome)
            .transition(.opacity.combined(with: .scale(scale: 0.72)))
    }
}
