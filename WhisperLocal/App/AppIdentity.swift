import Foundation

/// Public Release vs the local Dev channel. Bundle ID is the source of truth so
/// `/Applications/WhisperLocal.app` and `/Applications/WhisperLocal Dev.app` can
/// coexist (settings, TCC, and the updater stay apart).
enum AppIdentity {
    static let publicBundleID = "com.usingcolor.WhisperLocal"
    static let devBundleID = "com.usingcolor.WhisperLocal.dev"

    /// Developer ID team that signs public releases. The in-app updater refuses a
    /// download that is not signed by this team, which is what stops an ad-hoc
    /// fallback build from replacing a notarized install and resetting TCC.
    static let releaseTeamID = "HA9M6YGZ68"

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

    static var marketingVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    /// Dev includes the build so two installs of the same marketing version stay distinguishable.
    static var versionSummary: String {
        isDevBuild ? "\(marketingVersion) (\(buildNumber))" : marketingVersion
    }

    static var menuVersionLine: String {
        isDevBuild ? "Dev \(versionSummary)" : "Version \(marketingVersion)"
    }

    static var settingsWindowTitle: String {
        isDevBuild ? "\(productName) \(versionSummary)" : "\(productName) Settings"
    }

    static var supportFolderName: String {
        isDevBuild ? "WhisperLocalDev" : "WhisperLocal"
    }

    static var logsFolderName: String {
        supportFolderName
    }

    /// Dev uses a real NSMenu for the menu bar item; Release keeps the SwiftUI panel
    /// until the two have been compared in full-screen Spaces.
    /// Both channels now. The SwiftUI panel it replaced is a window pinned to the
    /// icon rather than a menu, and in a full-screen Space the system only holds
    /// the menu bar down for a menu — so the bar hid the moment the pointer moved
    /// and took the panel with it. The NSMenu was written for that and ran in Dev
    /// while the two were compared; this is the comparison settled.
    static var usesNativeStatusMenu: Bool { true }

    /// Same Keychain service as the public app so API keys do not need to be re-entered.
    static var keychainService: String { publicBundleID }
}
