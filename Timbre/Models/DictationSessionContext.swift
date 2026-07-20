import Foundation

struct DictationTargetContext: Equatable, Sendable {
    let processIdentifier: pid_t
    let bundleIdentifier: String?
    let localizedName: String?
}

struct DictationSessionContext: Equatable, Sendable {
    let id: UUID
    let target: DictationTargetContext?

    init(id: UUID = UUID(), target: DictationTargetContext?) {
        self.id = id
        self.target = target
    }
}
