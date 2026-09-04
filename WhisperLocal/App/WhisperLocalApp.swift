import AppKit
import SwiftUI

@main
struct WhisperLocalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = DictationController.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(controller: controller)
        } label: {
            if AppIdentity.isDevBuild {
                HStack(spacing: 4) {
                    Image(systemName: menuBarIcon(for: controller.phase))
                    Text(AppIdentity.versionSummary)
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                }
            } else {
                Label {
                    Text(AppIdentity.productName)
                } icon: {
                    Image(systemName: menuBarIcon(for: controller.phase))
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
            SessionContextEditor(controller: controller, showsIntro: true)
                .padding(20)
                .frame(minWidth: 440, minHeight: 180)
                .raiseWindowOnAppear()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }

    private func menuBarIcon(for phase: DictationPhase) -> String {
        if !controller.permissions.allGranted {
            return "exclamationmark.triangle"
        }
        if controller.transcription.isLoadingModel {
            return "arrow.down.circle"
        }
        if !controller.transcription.isReady {
            return "exclamationmark.triangle"
        }
        switch phase {
        case .waitingForMic: return "ellipsis.circle"
        case .recording: return "mic.fill"
        case .processing, .settingContext, .polishing, .inserting: return "ellipsis.circle"
        case .success, .successNote: return "checkmark.circle"
        case .error: return "exclamationmark.triangle"
        case .idle: return AppIdentity.isDevBuild ? "hammer.fill" : "waveform"
        }
    }
}

