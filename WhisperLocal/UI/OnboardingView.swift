import AppKit
import SwiftUI

struct OnboardingView: View {
    @ObservedObject var controller: DictationController
    @ObservedObject private var permissions = PermissionManager.shared
    @ObservedObject private var launchAtLogin = LaunchAtLogin.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to \(AppIdentity.productName)")
                    .font(.title2.bold())
                Text(AppIdentity.isDevBuild
                     ? "Dev \(AppIdentity.versionSummary) — default hotkey is Right Option. The public app keeps Globe / Fn. Audio stays on your Mac by default."
                     : "Speak with Globe / Fn — polished text appears at your cursor. Audio stays on your Mac by default.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Above the permissions, because none of them will stick until it is
            // fixed: macOS keeps re-launching a flagged copy from a fresh temporary
            // path, and anything keyed to the bundle starts over each time.
            if let problem = AppInstallLocation.current {
                installLocationRow(problem)
            }

            permissionRow(
                title: "Microphone",
                detail: "Needed to capture dictation audio.",
                granted: permissions.microphoneGranted,
                actionTitle: permissions.microphoneGranted ? "Granted" : "Allow Microphone"
            ) {
                Task { _ = await permissions.requestMicrophone() }
            }

            permissionRow(
                title: "Accessibility",
                detail: permissions.accessibilityHelpText,
                granted: permissions.accessibilityTrusted,
                actionTitle: permissions.accessibilityTrusted ? "Granted" : "Enable Accessibility"
            ) {
                permissions.requestAccessibility()
            }

            permissionRow(
                title: "Input Monitoring",
                detail: permissions.inputMonitoringHelpText,
                granted: permissions.inputMonitoringTrusted,
                actionTitle: permissions.inputMonitoringTrusted ? "Granted" : "Enable Input Monitoring"
            ) {
                permissions.requestInputMonitoring()
            }

            if !permissions.accessibilityTrusted || !permissions.inputMonitoringTrusted {
                Text("Running from: \(permissions.runningAppPath)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            // Asked for, not left to be discovered. This is the one place a new
            // install is guaranteed to look, and the toggle otherwise sits three
            // pages into Settings.
            if AppInstallLocation.current == nil, !launchAtLogin.isOn, !launchAtLogin.state.isBlocked {
                GroupBox {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Open at login")
                                .font(.headline)
                            Text("\(AppIdentity.productName) waits in the menu bar when you log in. No window opens and no dictation starts on its own.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Button("Turn On") { launchAtLogin.setEnabled(true) }
                    }
                    .padding(4)
                }
            }

            GroupBox("How to dictate") {
                VStack(alignment: .leading, spacing: 6) {
                    Label(
                        AppIdentity.isDevBuild
                            ? "Default hotkey: Right Option (change in Settings)"
                            : "Default hotkey: Globe / Fn (change in Settings)",
                        systemImage: "keyboard"
                    )
                    Label("Hold mode: press while speaking, release to finish", systemImage: "hand.raised")
                    Label("Tap mode: press once to start, again to stop", systemImage: "hand.tap")
                    Label("Esc cancels an in-progress dictation", systemImage: "escape")
                    Label("On-device polish is optional (Apple Intelligence or Gemma 4); if it fails, text is still pasted", systemImage: "checkmark.circle")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            HStack {
                Button("Refresh") {
                    permissions.refresh()
                }
                if !permissions.accessibilityTrusted || !permissions.inputMonitoringTrusted {
                    Button("Quit & Reopen") {
                        permissions.quitAndRelaunch()
                    }
                }
                Spacer()
                Button("Open Settings…") {
                    AppWindowFocus.present(title: AppIdentity.settingsWindowTitle) {
                        openWindow(id: "settings")
                    }
                    controller.showSettings = true
                }
                Button(permissions.allGranted ? "Start using \(AppIdentity.productName)" : "Continue anyway") {
                    controller.settings.hasCompletedOnboarding = true
                    controller.showOnboarding = false
                    // showOnboarding only gates *opening* this window; nothing observes
                    // it to close one, so without this the button looks dead.
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear {
            permissions.refresh()
            permissions.startPolling()
        }
        .onDisappear {
            permissions.stopPolling()
        }
    }

    /// The install problem, stated with the fix rather than the diagnosis.
    ///
    /// The app cannot clear the flag itself — it is sandboxed, and /Applications is
    /// outside it — so the fix is a Finder gesture, and this puts the app under the
    /// pointer ready for it. Deliberately not a Terminal command: this is a menu
    /// bar app, and nobody should have to open a shell to make it start at login.
    @ViewBuilder
    private func installLocationRow(_ problem: AppInstallLocation.Problem) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("This copy is running from a temporary location")
                        .font(.headline)
                }
                Text(AppInstallLocation.remedy(problem, productName: AppIdentity.productName))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Show in Finder") { AppInstallLocation.revealInstalledCopy() }
                    Spacer()
                    Button("Quit & Reopen") { permissions.quitAndRelaunch() }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private func permissionRow(
        title: String,
        detail: String,
        granted: Bool,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.seal.fill" : "exclamationmark.circle")
                .foregroundStyle(granted ? .green : .orange)
                .font(.title3)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(actionTitle, action: action)
                .disabled(granted)
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }
}
