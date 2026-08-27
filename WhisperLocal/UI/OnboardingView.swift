import SwiftUI

struct OnboardingView: View {
    @ObservedObject var controller: DictationController
    @ObservedObject private var permissions = PermissionManager.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to WhisperLocal")
                    .font(.title2.bold())
                Text("Speak with Globe / Fn — polished text appears at your cursor. Audio stays on your Mac by default.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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

            if !permissions.accessibilityTrusted {
                Text("Running from: \(permissions.runningAppPath)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            GroupBox("How to dictate") {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Default hotkey: Globe / Fn (change in Settings)", systemImage: "keyboard")
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
                if !permissions.accessibilityTrusted {
                    Button("Quit & Reopen") {
                        permissions.quitAndRelaunch()
                    }
                }
                Spacer()
                Button("Open Settings…") {
                    AppWindowFocus.present(title: "WhisperLocal Settings") {
                        openWindow(id: "settings")
                    }
                    controller.showSettings = true
                }
                Button(permissions.allGranted ? "Start using WhisperLocal" : "Continue anyway") {
                    controller.settings.hasCompletedOnboarding = true
                    controller.showOnboarding = false
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
