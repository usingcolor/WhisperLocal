import AppKit
import SwiftUI

/// Menu-bar panel, laid out like Apple's own Battery and Wi-Fi menus: a bold title
/// with the value trailing on the same line, secondary detail lines under it, and
/// actions grouped by separators.
///
/// This needs `.menuBarExtraStyle(.window)`. The classic `.menu` style converts the
/// content to NSMenuItems — `Text` becomes a disabled grey row and font, colour, and
/// alignment modifiers are dropped — so none of this hierarchy survives there.
struct MenuBarView: View {
    @ObservedObject var controller: DictationController
    @ObservedObject private var permissions = PermissionManager.shared
    @ObservedObject private var hotKey = HotKeyManager.shared
    @ObservedObject private var updater = AppUpdater.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            MenuSeparator()

            if let contextLine = controller.sessionContextLine {
                MenuSectionLabel("Session Context")
                MenuDetail(contextLine)
                    .padding(.bottom, 2)
                MenuRow("Edit Context…") { present("Session context", "session-context") }
                if controller.hasActiveSessionContext {
                    // Deliberately no dismiss(): seeing the context line disappear is
                    // the only confirmation this worked.
                    MenuRow("Clear Context") { controller.clearSessionContext() }
                }
                MenuSeparator()
            }

            MenuRow(updater.menuTitle, isEnabled: !(updater.isBusy && !AppIdentity.isDevBuild)) {
                dismiss()
                Task { await updater.handleMenuClick() }
            }
            MenuSeparator()

            MenuRow("Settings…", shortcut: "⌘,") {
                present(AppIdentity.settingsWindowTitle, "settings")
                controller.showSettings = true
            }
            MenuRow("Dictation Log…") { present("Dictation Log", "log") }
            MenuRow("Permissions / Onboarding…") {
                present("Welcome", "onboarding")
                controller.showOnboarding = true
            }
            MenuSeparator()

            MenuRow("Reload Speech Model") {
                dismiss()
                Task {
                    await controller.transcription.ensureModel(
                        named: controller.settings.asrModel, force: true
                    )
                }
            }
            MenuSeparator()

            MenuRow("Quit \(AppIdentity.productName)", shortcut: "⌘Q") {
                controller.stop()
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.vertical, 6)
        .frame(width: 292)
        .onAppear {
            controller.start()
            if controller.showOnboarding {
                // openOnly: present() dismisses, and dismissing the panel from inside
                // its own onAppear is not a state change worth making.
                openOnly("Welcome", "onboarding")
            }
        }
    }

    /// Title and version share a line, the way "Battery" and "80%" do.
    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(AppIdentity.productName)
                    .font(.headline)
                Spacer(minLength: 8)
                Text(AppIdentity.versionSummary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Text(statusLine)
                .font(.subheadline)
                .foregroundStyle(statusIsWarning ? Color.orange : .secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(controller.polishStatusLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }

    /// A `.window` style panel does not dismiss itself the way an NSMenu does, so
    /// every row that leads somewhere has to close it explicitly.
    private func present(_ title: String, _ id: String) {
        dismiss()
        openOnly(title, id)
    }

    private func openOnly(_ title: String, _ id: String) {
        AppWindowFocus.present(title: title) { openWindow(id: id) }
    }

    /// Missing permissions are the one status worth colouring — everything else is
    /// informational and stays secondary so the title keeps the emphasis.
    private var statusIsWarning: Bool {
        HotKeyManager.secureInputActive
            || !permissions.inputMonitoringTrusted
            || !permissions.accessibilityTrusted
    }

    private var statusLine: String {
        // Checked before the permission lines: with secure input on, the hotkey is
        // dead no matter how the permissions look, and this is the only place the
        // user can be told — the hotkey cannot fire to show anything itself.
        if HotKeyManager.secureInputActive {
            return "A password field is focused — the hotkey won’t fire until you click elsewhere"
        }
        if !permissions.inputMonitoringTrusted {
            return "Input Monitoring missing — hotkey won’t fire in other apps"
        }
        if !permissions.accessibilityTrusted {
            return "Accessibility missing — text won’t paste into other apps"
        }
        if controller.transcription.isLoadingModel || !controller.transcription.isReady {
            return controller.transcription.statusMessage
        }
        switch controller.phase {
        case .idle, .success:
            return controller.readyStatusLine
        case .recording, .waitingForMic:
            return controller.isIntentTake ? "Listening for context…" : controller.phase.label
        default:
            return controller.phase.label
        }
    }
}

// MARK: - Pieces

/// A menu item. `.window` style gives no row highlighting for free, so the hover
/// fill that makes a list read as a menu has to be drawn here.
private struct MenuRow: View {
    let title: String
    var shortcut: String?
    var isEnabled: Bool = true
    let action: () -> Void

    @State private var hovering = false

    init(_ title: String, shortcut: String? = nil, isEnabled: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.shortcut = shortcut
        self.isEnabled = isEnabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                Spacer(minLength: 8)
                if let shortcut {
                    Text(shortcut)
                        .foregroundStyle(hovering ? Color.white.opacity(0.8) : .secondary)
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(hovering ? Color.white : .primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(hovering ? Color.accentColor : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .padding(.horizontal, 5)
        .onHover { hovering = isEnabled && $0 }
    }
}

/// Group heading, matching the weight Apple gives "Energy Mode".
private struct MenuSectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.top, 2)
            .padding(.bottom, 1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MenuDetail: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MenuSeparator: View {
    var body: some View {
        Divider()
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
    }
}
