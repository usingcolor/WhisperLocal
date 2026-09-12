import AppKit
import SwiftUI

@main
struct WhisperLocalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = DictationController.shared

    var body: some Scene {
        // Release keeps this panel. Dev replaces it with a real NSMenu while the two
        // are compared: a panel does not hold the menu bar down in a full-screen
        // Space, so it vanishes with the bar the moment the mouse leaves the top.
        // Not inserted, SwiftUI parks the item off-screen, and as the first scene it
        // still stops the Window scenes below from opening at launch.
        MenuBarExtra(isInserted: menuBarItemInserted) {
            MenuBarView(controller: controller)
        } label: {
            if AppIdentity.isDevBuild {
                HStack(spacing: 4) {
                    Image(systemName: MenuBarIcon.symbol(for: controller))
                    Text(AppIdentity.versionSummary)
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                }
            } else {
                Label {
                    Text(AppIdentity.productName)
                } icon: {
                    Image(systemName: MenuBarIcon.symbol(for: controller))
                }
            }
        }
        // .window, not .menu: NSMenuItems ignore font and colour, so the
        // Battery-menu style hierarchy is only possible in a panel.
        .menuBarExtraStyle(.window)

        Window(AppIdentity.settingsWindowTitle, id: "settings") {
            SettingsView(controller: controller)
                .raiseWindowOnAppear()
        }
        .defaultSize(width: 740, height: 560)
        .windowResizability(.contentMinSize)
        .defaultPosition(.center)

        Window("Dictation Log", id: "log") {
            DictationLogView()
                .raiseWindowOnAppear()
        }
        .defaultSize(width: 780, height: 480)
        .defaultPosition(.center)

        Window("Welcome", id: "onboarding") {
            OnboardingView(controller: controller)
                .raiseWindowOnAppear()
        }
        .defaultSize(width: 520, height: 560)
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("Session context", id: "session-context") {
            SessionContextEditor(controller: controller, showsIntro: true, closesAfterSave: true)
                .padding(20)
                .frame(minWidth: 460, minHeight: 220)
                .raiseWindowOnAppear()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }

    /// Release shows SwiftUI's item; Dev hides it for `StatusMenuController`.
    ///
    /// Passing `isInserted` at all changes the item: a plain `MenuBarExtra` quits
    /// the app when it is ⌘-dragged out of the menu bar, and one given a binding
    /// only hides (status item behavior 6 → 2, measured). A constant binding then
    /// left a Release app running with the hotkey live and no menu to reach
    /// Settings or Quit. SwiftUI writes `false` here on removal — measured too — so
    /// the setter puts quit-on-removal back.
    private var menuBarItemInserted: Binding<Bool> {
        Binding(
            get: { !AppIdentity.usesNativeStatusMenu },
            set: { inserted in
                guard !inserted, !AppIdentity.usesNativeStatusMenu else { return }
                MenuBarRemoval.quit()
            }
        )
    }
}

/// The menu bar symbol for the current state. Shared by the SwiftUI item and the
/// NSMenu one so the two cannot drift while they are being compared.
@MainActor
enum MenuBarIcon {
    static func symbol(for controller: DictationController) -> String {
        // A copy running from a temporary location is as broken as a missing
        // permission, and just as invisible without this: nothing else in the app
        // says so unless the user opens the one Settings row that mentions it.
        if AppInstallLocation.current != nil {
            return "exclamationmark.triangle"
        }
        if !controller.permissions.allGranted {
            return "exclamationmark.triangle"
        }
        if controller.transcription.isLoadingModel {
            return "arrow.down.circle"
        }
        if !controller.transcription.isReady {
            return "exclamationmark.triangle"
        }
        switch controller.phase {
        case .waitingForMic: return "ellipsis.circle"
        case .recording: return "mic.fill"
        case .processing, .settingContext, .polishing, .inserting: return "ellipsis.circle"
        case .success, .successNote: return "checkmark.circle"
        case .error: return "exclamationmark.triangle"
        case .idle: return AppIdentity.isDevBuild ? "hammer.fill" : "waveform"
        }
    }
}

/// Quits when the menu bar item is dragged away. SwiftUI reports the removal
/// twice, and quitting with work in flight opens a confirmation — without this
/// guard the second report would stack a second alert under the first.
@MainActor
enum MenuBarRemoval {
    private static var quitting = false

    static func quit() {
        guard !quitting else { return }
        quitting = true
        NSApplication.shared.terminate(nil)
        // Only reached when the user cancelled the quit to keep a take.
        quitting = false
    }
}

