import Foundation

enum OmniTagBranding {
    static let versionTitle = "Version Six"

    static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "OmniTag"
    }

    static var windowTitle: String {
        "\(appName) \(versionTitle)"
    }
}
