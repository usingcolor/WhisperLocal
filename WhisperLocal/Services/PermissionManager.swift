import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import Foundation
import os

@MainActor
final class PermissionManager: ObservableObject {
    static let shared = PermissionManager()

    private let logger = Logger(subsystem: "com.usingcolor.WhisperLocal", category: "permissions")

    @Published private(set) var microphoneGranted: Bool = false
    @Published private(set) var accessibilityTrusted: Bool = false
    @Published private(set) var inputMonitoringTrusted: Bool = false
    @Published private(set) var lastCheckedAt: Date = .distantPast
    @Published private(set) var runningAppPath: String = ""

    var allGranted: Bool { microphoneGranted && accessibilityTrusted && inputMonitoringTrusted }

    private var pollTask: Task<Void, Never>?
    private var becomeActiveObserver: NSObjectProtocol?

    init() {
        runningAppPath = Bundle.main.bundlePath
        refresh()
        becomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    deinit {
        if let becomeActiveObserver {
            NotificationCenter.default.removeObserver(becomeActiveObserver)
        }
    }

    func refresh() {
        runningAppPath = Bundle.main.bundlePath

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            microphoneGranted = true
        default:
            microphoneGranted = false
        }

        // Prefer the non-prompting check for Refresh.
        accessibilityTrusted = AXIsProcessTrusted()
        inputMonitoringTrusted = CGPreflightListenEventAccess()
        lastCheckedAt = Date()
    }

    /// Call while Onboarding/Settings is open so toggling in System Settings updates the UI.
    func startPolling(intervalSeconds: Double = 1.0) {
        stopPolling()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(intervalSeconds * 1_000_000_000))
                guard !Task.isCancelled else { break }
                await MainActor.run {
                    self?.refresh()
                }
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func requestMicrophone() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            microphoneGranted = true
            return true
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            microphoneGranted = granted
            return granted
        case .denied, .restricted:
            microphoneGranted = false
            openMicrophoneSettings()
            return false
        @unknown default:
            return false
        }
    }

    func requestAccessibility() {
        // Show the system prompt if never asked; always also open Settings.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        accessibilityTrusted = AXIsProcessTrustedWithOptions(options)
        lastCheckedAt = Date()
        if !accessibilityTrusted {
            openAccessibilitySettings()
        }
        startPolling()
    }

    func requestInputMonitoring() {
        _ = CGRequestListenEventAccess()
        refresh()
        if !inputMonitoringTrusted {
            openInputMonitoringSettings()
        }
        startPolling()
    }

    func openMicrophoneSettings() {
        openPrivacyPane(legacy: "Privacy_Microphone", modern: "Privacy_Microphone")
    }

    func openAccessibilitySettings() {
        openPrivacyPane(legacy: "Privacy_Accessibility", modern: "Privacy_Accessibility")
    }

    func openInputMonitoringSettings() {
        openPrivacyPane(legacy: "Privacy_ListenEvent", modern: "Privacy_ListenEvent")
    }

    /// Quit and relaunch — often required after enabling Accessibility for a rebuilt binary.
    /// Relaunch after a permission change.
    ///
    /// Asking NSWorkspace to open our own bundle and then terminating does not work:
    /// the new instance is spawned by a process that is already dying and gets torn
    /// down with it, and the 0.8s fallback terminate fired whether or not the launch
    /// had finished — which on a cold start it had not. Hand the reopen to a detached
    /// process that waits for this pid to exit first, the same way the updater
    /// relaunches after replacing the app.
    func quitAndRelaunch() {
        let bundlePath = Bundle.main.bundleURL.path
        let pid = ProcessInfo.processInfo.processIdentifier

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            "-c",
            // Poll rather than sleep a fixed amount: the wait is however long we take
            // to quit, which varies with whatever model is resident.
            #"""
            while /bin/kill -0 "$1" 2>/dev/null; do sleep 0.2; done
            sleep 0.3
            /usr/bin/open "$2"
            """#,
            "bash",
            String(pid),
            bundlePath
        ]
        do {
            try process.run()
        } catch {
            // Nothing reopens us, but quitting anyway would look like a crash.
            logger.error("Relaunch helper failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        NSApp.terminate(nil)
    }

    var accessibilityHelpText: String {
        if accessibilityTrusted {
            return "Accessibility is granted for this running copy."
        }
        return """
        Enable \(AppIdentity.productName) in System Settings → Privacy & Security → Accessibility. \
        If the toggle is already ON but this still says Missing: turn it OFF, remove the old entry, \
        open this app from \(runningAppPath), enable it again, then Quit & Reopen.
        """
    }

    var inputMonitoringHelpText: String {
        if inputMonitoringTrusted {
            return "Input Monitoring is granted. The dictation hotkey can be heard in other apps."
        }
        return """
        Enable \(AppIdentity.productName) in System Settings → Privacy & Security → Input Monitoring. \
        Without it, Globe/Fn or Right Command is only seen while \(AppIdentity.productName) itself is focused. \
        After enabling, Quit & Reopen.
        """
    }

    private func openPrivacyPane(legacy: String, modern: String) {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?\(legacy)",
            "x-apple.systempreferences:com.apple.Settings.PrivacySecurity.extension?\(modern)",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(modern)"
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) {
                return
            }
        }
        // Last resort: open Privacy & Security root
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
