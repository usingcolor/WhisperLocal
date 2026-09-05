import AppKit
import ServiceManagement
import os

/// The "open at login" login item, backed by `SMAppService.mainApp`.
///
/// There is deliberately no stored preference behind this. The system owns the
/// state — the user can switch the login item off in System Settings › General ›
/// Login Items and nothing notifies the app — so a remembered bool would drift
/// out of sync and show a lie. `refresh()` reads the truth back instead.
@MainActor
final class LaunchAtLogin: ObservableObject {
    static let shared = LaunchAtLogin()

    enum State: Equatable {
        case on
        case off
        /// Registered, but the user revoked it in System Settings. `register()`
        /// cannot undo that — only they can, in the Login Items pane.
        case blockedByUser
        /// The registration exists but points at a bundle that is no longer there.
        case stale
        /// This copy of the app is somewhere a login item cannot survive.
        case unavailable(reason: String)

        init(_ status: SMAppService.Status) {
            switch status {
            case .enabled: self = .on
            case .notRegistered: self = .off
            case .requiresApproval: self = .blockedByUser
            case .notFound: self = .stale
            @unknown default: self = .off
            }
        }

        var isOn: Bool { self == .on }

        /// Nothing `register()` can do will move the toggle out of these two.
        var isBlocked: Bool {
            switch self {
            case .blockedByUser, .unavailable: return true
            case .on, .off, .stale: return false
            }
        }
    }

    @Published private(set) var state: State = .off
    /// Last registration error, shown next to the toggle. Cleared by the next attempt.
    @Published private(set) var failure: String?

    /// Where we were when the login item was registered. A recorded fact, not a
    /// preference: it is how we notice the app has been moved since, which leaves
    /// the login item pointing at nothing.
    private let registeredPathKey = "launchAtLoginRegisteredPath"
    private let logger = Logger(subsystem: "com.usingcolor.WhisperLocal", category: "login-item")

    private var becomeActiveObserver: NSObjectProtocol?

    private init() {
        refresh()
        // The Login Items pane is the other place this can be changed, and it tells
        // us nothing when it is. Coming back to our own window is the moment the
        // toggle is about to be looked at again, so re-read the truth there.
        becomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    var isOn: Bool { state.isOn }

    /// A copy running from a read-only mount or an App Translocation container has
    /// no durable path, so a login item made from it would point at nothing after
    /// the next restart. Registering would appear to work and then silently fail,
    /// which is worse than refusing.
    ///
    /// Takes the path rather than reading the bundle so the rule can be tested.
    nonisolated static func unavailableReason(forBundleAt path: String, productName: String) -> String? {
        // Gatekeeper runs a quarantined app from a randomised read-only image whose
        // path is gone the moment the app quits. Everything under it looks like a
        // normal /private/var path, so the marker directory is the only tell.
        if path.contains("/AppTranslocation/") {
            return "macOS is running this copy from a temporary location. Move \(productName) to your Applications folder, then reopen it."
        }
        if path.hasPrefix("/Volumes/") {
            return "This copy is running from a disk image. Drag \(productName) to your Applications folder, then open it from there."
        }
        return nil
    }

    private static var unavailableReason: String? {
        unavailableReason(forBundleAt: Bundle.main.bundlePath, productName: AppIdentity.productName)
    }

    func refresh() {
        if let reason = Self.unavailableReason {
            state = .unavailable(reason: reason)
            return
        }
        state = State(SMAppService.mainApp.status)
    }

    /// Called at launch. Re-points the login item if the app has been moved since it
    /// was registered — this only ever runs when the item is already on, so it can
    /// restore the user's choice but never override a decision to switch it off.
    func reconcileAfterLaunch() {
        refresh()
        let current = Bundle.main.bundlePath
        let recorded = UserDefaults.standard.string(forKey: registeredPathKey)

        switch state {
        case .on:
            guard recorded != current else { return }
            guard recorded != nil else {
                // Enabled before this version started recording the path.
                UserDefaults.standard.set(current, forKey: registeredPathKey)
                return
            }
            logger.notice("app moved since registration; re-registering the login item")
            try? SMAppService.mainApp.unregister()
            reregister(at: current)
        case .stale:
            guard recorded != nil else { return }
            logger.notice("login item registration went stale; re-registering")
            reregister(at: current)
        case .off, .blockedByUser, .unavailable:
            return
        }
    }

    private func reregister(at path: String) {
        do {
            try SMAppService.mainApp.register()
            UserDefaults.standard.set(path, forKey: registeredPathKey)
        } catch {
            logger.error("re-registering the login item failed: \(error.localizedDescription, privacy: .public)")
        }
        refresh()
    }

    func setEnabled(_ enabled: Bool) {
        failure = nil
        guard Self.unavailableReason == nil else {
            refresh()
            return
        }
        do {
            if enabled {
                try SMAppService.mainApp.register()
                UserDefaults.standard.set(Bundle.main.bundlePath, forKey: registeredPathKey)
            } else {
                try SMAppService.mainApp.unregister()
                UserDefaults.standard.removeObject(forKey: registeredPathKey)
            }
        } catch {
            handle(error, enabling: enabled)
        }
        refresh()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Both no-op codes are successes wearing an error's clothes: asking for a state
    /// the system is already in. Reporting them would make the toggle look broken.
    private func handle(_ error: Error, enabling: Bool) {
        let code = (error as NSError).code
        if enabling, code == Int(kSMErrorAlreadyRegistered) { return }
        if !enabling, code == Int(kSMErrorJobNotFound) { return }

        logger.error("login item \(enabling ? "register" : "unregister", privacy: .public) failed: \(error.localizedDescription, privacy: .public)")

        if enabling, code == Int(kSMErrorLaunchDeniedByUser) {
            // Not really a failure — `refresh()` will report .blockedByUser, which
            // says the same thing with a button that goes somewhere useful.
            return
        }
        if enabling, code == Int(kSMErrorInvalidSignature) {
            failure = "macOS rejected this copy's code signature. Reinstall \(AppIdentity.productName) from the official release."
            return
        }
        failure = error.localizedDescription
    }
}
