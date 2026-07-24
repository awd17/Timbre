import Foundation

protocol BundleInformationProviding {
    var appName: String { get }
    var versionDescription: String { get }
}

struct BundleInformation: BundleInformationProviding {
    let appName: String
    let versionDescription: String

    init(bundle: Bundle = .main) {
        appName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "Timbre"
        versionDescription = Self.versionDescription(
            marketingVersion: bundle.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String,
            buildNumber: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        )
    }

    init(
        appName: String = "Timbre",
        marketingVersion: String?,
        buildNumber: String?
    ) {
        self.appName = appName
        versionDescription = Self.versionDescription(
            marketingVersion: marketingVersion,
            buildNumber: buildNumber
        )
    }

    static func versionDescription(
        marketingVersion: String?,
        buildNumber: String?
    ) -> String {
        switch (nonempty(marketingVersion), nonempty(buildNumber)) {
        case let (version?, build?):
            return "Version \(version) (\(build))"
        case let (version?, nil):
            return "Version \(version)"
        case let (nil, build?):
            return "Build \(build)"
        case (nil, nil):
            return "Version unavailable"
        }
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
