import Combine
import Foundation

enum MicrophoneSelection: Codable, Equatable, Hashable {
    case systemDefault
    case device(uid: String, name: String)

    var deviceUID: String? {
        guard case .device(let uid, _) = self else { return nil }
        return uid
    }

    var deviceName: String? {
        guard case .device(_, let name) = self else { return nil }
        return name
    }
}

enum PlaybackDuringDictation: String, CaseIterable, Codable, Identifiable {
    case keepUnchanged
    case mute

    var id: Self { self }

    var title: String {
        switch self {
        case .keepUnchanged:
            return "Keep Unchanged"
        case .mute:
            return "Mute"
        }
    }
}

@MainActor
protocol AppPreferencesProviding: AnyObject {
    var keepTranscriptOnClipboardAfterInsertion: Bool { get set }
    var showInDock: Bool { get set }
    var microphoneSelection: MicrophoneSelection { get set }
    var playbackDuringDictation: PlaybackDuringDictation { get set }
    var changes: AnyPublisher<AppPreferenceChange, Never> { get }
    func resetUserSettings()
}

enum AppPreferenceChange: Equatable {
    case keepTranscriptOnClipboardAfterInsertion(Bool)
    case showInDock(Bool)
    case microphoneSelection(MicrophoneSelection)
    case playbackDuringDictation(PlaybackDuringDictation)
}

@MainActor
final class UserDefaultsAppPreferences: ObservableObject, AppPreferencesProviding {
    static let keepTranscriptOnClipboardAfterInsertionKey =
        "timbre.keepTranscriptOnClipboardAfterInsertion"
    static let showInDockKey = "timbre.showInDock"
    static let microphoneSelectionKey = "timbre.microphoneSelection"
    static let playbackDuringDictationKey = "timbre.playbackDuringDictation"

    @Published var keepTranscriptOnClipboardAfterInsertion: Bool {
        didSet {
            guard oldValue != keepTranscriptOnClipboardAfterInsertion else { return }
            defaults.set(
                keepTranscriptOnClipboardAfterInsertion,
                forKey: Self.keepTranscriptOnClipboardAfterInsertionKey
            )
            changeSubject.send(
                .keepTranscriptOnClipboardAfterInsertion(
                    keepTranscriptOnClipboardAfterInsertion
                )
            )
        }
    }

    @Published var showInDock: Bool {
        didSet {
            guard oldValue != showInDock else { return }
            defaults.set(showInDock, forKey: Self.showInDockKey)
            changeSubject.send(.showInDock(showInDock))
        }
    }

    @Published var microphoneSelection: MicrophoneSelection {
        didSet {
            guard oldValue != microphoneSelection else { return }
            if microphoneSelection == .systemDefault {
                defaults.removeObject(forKey: Self.microphoneSelectionKey)
            } else if let data = try? JSONEncoder().encode(microphoneSelection) {
                defaults.set(data, forKey: Self.microphoneSelectionKey)
            }
            changeSubject.send(.microphoneSelection(microphoneSelection))
        }
    }

    @Published var playbackDuringDictation: PlaybackDuringDictation {
        didSet {
            guard oldValue != playbackDuringDictation else { return }
            if playbackDuringDictation == .keepUnchanged {
                defaults.removeObject(forKey: Self.playbackDuringDictationKey)
            } else {
                defaults.set(
                    playbackDuringDictation.rawValue,
                    forKey: Self.playbackDuringDictationKey
                )
            }
            changeSubject.send(.playbackDuringDictation(playbackDuringDictation))
        }
    }

    var changes: AnyPublisher<AppPreferenceChange, Never> {
        changeSubject.eraseToAnyPublisher()
    }

    let defaults: UserDefaults
    private let changeSubject = PassthroughSubject<AppPreferenceChange, Never>()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Self.keepTranscriptOnClipboardAfterInsertionKey: false,
            Self.showInDockKey: false,
        ])
        keepTranscriptOnClipboardAfterInsertion = defaults.bool(
            forKey: Self.keepTranscriptOnClipboardAfterInsertionKey
        )
        showInDock = defaults.bool(forKey: Self.showInDockKey)
        microphoneSelection = defaults.data(forKey: Self.microphoneSelectionKey)
            .flatMap { try? JSONDecoder().decode(MicrophoneSelection.self, from: $0) }
            ?? .systemDefault
        if let storedPlayback = defaults.string(
            forKey: Self.playbackDuringDictationKey
        ),
            let playback = PlaybackDuringDictation(rawValue: storedPlayback)
        {
            playbackDuringDictation = playback
        } else {
            playbackDuringDictation = .keepUnchanged
            // Remove values for playback modes that no longer exist.
            defaults.removeObject(forKey: Self.playbackDuringDictationKey)
        }
    }

    func resetUserSettings() {
        keepTranscriptOnClipboardAfterInsertion = false
        showInDock = false
        microphoneSelection = .systemDefault
        playbackDuringDictation = .keepUnchanged
        // Keep the defaults domain sparse and remove even malformed values
        // that may have decoded to their in-memory fallbacks at launch.
        defaults.removeObject(forKey: Self.keepTranscriptOnClipboardAfterInsertionKey)
        defaults.removeObject(forKey: Self.showInDockKey)
        defaults.removeObject(forKey: Self.microphoneSelectionKey)
        defaults.removeObject(forKey: Self.playbackDuringDictationKey)
    }
}

@MainActor
final class InMemoryAppPreferences: ObservableObject, AppPreferencesProviding {
    @Published var keepTranscriptOnClipboardAfterInsertion: Bool {
        didSet {
            guard oldValue != keepTranscriptOnClipboardAfterInsertion else { return }
            changeSubject.send(
                .keepTranscriptOnClipboardAfterInsertion(
                    keepTranscriptOnClipboardAfterInsertion
                )
            )
        }
    }

    @Published var showInDock: Bool {
        didSet {
            guard oldValue != showInDock else { return }
            changeSubject.send(.showInDock(showInDock))
        }
    }

    @Published var microphoneSelection: MicrophoneSelection {
        didSet {
            guard oldValue != microphoneSelection else { return }
            changeSubject.send(.microphoneSelection(microphoneSelection))
        }
    }

    @Published var playbackDuringDictation: PlaybackDuringDictation {
        didSet {
            guard oldValue != playbackDuringDictation else { return }
            changeSubject.send(.playbackDuringDictation(playbackDuringDictation))
        }
    }

    var changes: AnyPublisher<AppPreferenceChange, Never> {
        changeSubject.eraseToAnyPublisher()
    }

    private let changeSubject = PassthroughSubject<AppPreferenceChange, Never>()

    init(
        keepTranscriptOnClipboardAfterInsertion: Bool = false,
        showInDock: Bool = false,
        microphoneSelection: MicrophoneSelection = .systemDefault,
        playbackDuringDictation: PlaybackDuringDictation = .keepUnchanged
    ) {
        self.keepTranscriptOnClipboardAfterInsertion =
            keepTranscriptOnClipboardAfterInsertion
        self.showInDock = showInDock
        self.microphoneSelection = microphoneSelection
        self.playbackDuringDictation = playbackDuringDictation
    }

    func resetUserSettings() {
        keepTranscriptOnClipboardAfterInsertion = false
        showInDock = false
        microphoneSelection = .systemDefault
        playbackDuringDictation = .keepUnchanged
    }
}
