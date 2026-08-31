import Foundation

/// Public Release vs the local Dev channel. Bundle ID is the source of truth so
/// `/Applications/WhisperLocal.app` and `/Applications/WhisperLocal Dev.app` can
/// coexist (settings, TCC, and the updater stay apart).
enum AppIdentity {
    static let publicBundleID = "com.usingcolor.WhisperLocal"
    static let devBundleID = "com.usingcolor.WhisperLocal.dev"

    static var bundleID: String {
        Bundle.main.bundleIdentifier ?? publicBundleID
    }

    static var isDevBuild: Bool {
        isDev(bundleID: bundleID)
    }

    static func isDev(bundleID: String) -> Bool {
        bundleID == devBundleID
    }

    static var productName: String {
        isDevBuild ? "WhisperLocal Dev" : "WhisperLocal"
    }

    static var settingsWindowTitle: String {
        "\(productName) Settings"
    }

    static var supportFolderName: String {
        isDevBuild ? "WhisperLocalDev" : "WhisperLocal"
    }

    static var logsFolderName: String {
        supportFolderName
    }

    /// Same Keychain service as the public app so API keys do not need to be re-entered.
    static var keychainService: String { publicBundleID }
}
