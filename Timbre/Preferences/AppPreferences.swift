import Combine
import Foundation

@MainActor
protocol AppPreferencesProviding: AnyObject {
    var keepTranscriptOnClipboardAfterInsertion: Bool { get set }
    var showInDock: Bool { get set }
    var changes: AnyPublisher<AppPreferenceChange, Never> { get }
}

enum AppPreferenceChange: Equatable {
    case keepTranscriptOnClipboardAfterInsertion(Bool)
    case showInDock(Bool)
}

@MainActor
final class UserDefaultsAppPreferences: ObservableObject, AppPreferencesProviding {
    static let keepTranscriptOnClipboardAfterInsertionKey =
        "timbre.keepTranscriptOnClipboardAfterInsertion"
    static let showInDockKey = "timbre.showInDock"

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

    var changes: AnyPublisher<AppPreferenceChange, Never> {
        changeSubject.eraseToAnyPublisher()
    }

    private let changeSubject = PassthroughSubject<AppPreferenceChange, Never>()

    init(
        keepTranscriptOnClipboardAfterInsertion: Bool = false,
        showInDock: Bool = false
    ) {
        self.keepTranscriptOnClipboardAfterInsertion =
            keepTranscriptOnClipboardAfterInsertion
        self.showInDock = showInDock
    }
}
