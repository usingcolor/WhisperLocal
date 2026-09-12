import AppKit
import Foundation

/// Where this copy of the app is really running from, and whether that is a place
/// it can work properly.
///
/// macOS runs an app still flagged as downloaded from a randomised read-only image
/// under `AppTranslocation` rather than from where it sits. The bundle path is then
/// different on every launch and gone the moment the app quits, which breaks the
/// login item outright and is the wrong footing for anything else keyed to the
/// bundle. Dragging a DMG to Applications in Finder clears the flag; copying it any
/// other way — a script, an installer, this app's own updater before 0.2.2 — does
/// not, and nothing tells the user.
///
/// It lives apart from `LaunchAtLogin` because the login item is only the first
/// thing it breaks, and the app has to be able to say so in the menu bar and in
/// onboarding, not just in one Settings row nobody has opened.
enum AppInstallLocation {
    enum Problem: Equatable {
        /// Running from the randomised copy, with the real app installed.
        case temporaryCopyOfInstalledApp
        /// Running from the randomised copy, and not installed anywhere yet.
        case temporaryCopy
        /// Running straight off a mounted image.
        case readOnlyVolume
    }

    /// The facts are passed in rather than read, so every case can be tested
    /// without moving an app around.
    static func problem(
        forBundleAt path: String,
        onReadOnlyVolume: Bool,
        hasApplicationsCopy: Bool
    ) -> Problem? {
        // Everything under a translocated path looks like a normal /private/var
        // path, so the marker directory is the only tell.
        if path.contains("/AppTranslocation/") {
            return hasApplicationsCopy ? .temporaryCopyOfInstalledApp : .temporaryCopy
        }
        // A mounted image is read-only; an external drive is not, and an app kept
        // there has as durable a path as one in /Applications.
        if onReadOnlyVolume {
            return .readOnlyVolume
        }
        return nil
    }

    static var current: Problem? {
        let url = Bundle.main.bundleURL
        let readOnly = (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
        return problem(
            forBundleAt: url.path,
            onReadOnlyVolume: readOnly,
            hasApplicationsCopy: FileManager.default.fileExists(
                atPath: "/Applications/\(url.lastPathComponent)"
            )
        )
    }

    /// One line for the menu bar, where there is room for a sentence and no room
    /// for instructions.
    static func headline(_ problem: Problem, productName: String) -> String {
        switch problem {
        case .temporaryCopyOfInstalledApp, .temporaryCopy:
            return "Running from a temporary copy — open at login and permissions won’t stick"
        case .readOnlyVolume:
            return "Running from a disk image — drag \(productName) to Applications first"
        }
    }

    /// What to actually do about it, for onboarding, where there is room.
    static func remedy(_ problem: Problem, productName: String) -> String {
        switch problem {
        case .temporaryCopyOfInstalledApp:
            return "\(productName) is in your Applications folder, but macOS is running this copy from a temporary location because the app is still flagged as downloaded. In Finder, drag it out of Applications and back in — that clears the flag — then quit and open it from Applications."
        case .temporaryCopy:
            return "macOS is running this copy from a temporary location, which disappears when the app quits. Drag \(productName) into your Applications folder in Finder, then open it from there."
        case .readOnlyVolume:
            return "This copy is running from a disk image. Drag \(productName) into your Applications folder in Finder, then open it from there."
        }
    }

    /// Selects the installed copy in Finder, which is where the drag has to happen.
    @MainActor
    static func revealInstalledCopy() {
        let name = Bundle.main.bundleURL.lastPathComponent
        let installed = URL(fileURLWithPath: "/Applications/\(name)")
        guard FileManager.default.fileExists(atPath: installed.path) else {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: "/Applications")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([installed])
    }
}
