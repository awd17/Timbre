import Foundation

struct DictationTargetContext: Equatable, Sendable {
    let processIdentifier: pid_t
    let bundleIdentifier: String?
    let localizedName: String?
    let launchDate: Date?

    init(
        processIdentifier: pid_t,
        bundleIdentifier: String?,
        localizedName: String?,
        launchDate: Date? = nil
    ) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.localizedName = localizedName
        self.launchDate = launchDate
    }
}

struct DictationSessionContext: Equatable, Sendable {
    let id: UUID
    let target: DictationTargetContext?

    init(id: UUID = UUID(), target: DictationTargetContext?) {
        self.id = id
        self.target = target
    }
}
