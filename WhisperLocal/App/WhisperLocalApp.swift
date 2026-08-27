import AppKit
import SwiftUI

@main
struct WhisperLocalApp: App {
    @StateObject private var controller = DictationController.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(controller: controller)
        } label: {
            Label {
                Text("WhisperLocal")
            } icon: {
                Image(systemName: menuBarIcon(for: controller.phase))
            }
        }
        .menuBarExtraStyle(.menu)

        Window("WhisperLocal Settings", id: "settings") {
            SettingsView(controller: controller)
                .raiseWindowOnAppear()
        }
        .defaultSize(width: 560, height: 680)
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
        .defaultSize(width: 500, height: 420)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }

    private func menuBarIcon(for phase: DictationPhase) -> String {
        if controller.transcription.isLoadingModel {
            return "arrow.down.circle"
        }
        if !controller.transcription.isReady {
            return "exclamationmark.triangle"
        }
        switch phase {
        case .recording: return "mic.fill"
        case .processing, .polishing, .inserting: return "ellipsis.circle"
        case .success, .successNote: return "checkmark.circle"
        case .error: return "exclamationmark.triangle"
        case .idle: return "waveform"
        }
    }
}

struct MenuBarContent: View {
    @ObservedObject var controller: DictationController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(statusLine)
        Divider()
        Button("Settings…") {
            AppWindowFocus.present(title: "WhisperLocal Settings") {
                openWindow(id: "settings")
            }
            controller.showSettings = true
        }
        .keyboardShortcut(",", modifiers: .command)
        Button("Dictation Log…") {
            AppWindowFocus.present(title: "Dictation Log") {
                openWindow(id: "log")
            }
        }
        Button("Permissions / Onboarding…") {
            AppWindowFocus.present(title: "Welcome") {
                openWindow(id: "onboarding")
            }
            controller.showOnboarding = true
        }
        Divider()
        Button("Reload speech model") {
            Task { await controller.transcription.ensureModel(named: controller.settings.asrModel, force: true) }
        }
        Divider()
        Button("Quit WhisperLocal") {
            controller.stop()
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
        .onAppear {
            controller.start()
            if controller.showOnboarding {
                AppWindowFocus.present(title: "Welcome") {
                    openWindow(id: "onboarding")
                }
            }
        }
    }

    private var statusLine: String {
        if controller.transcription.isLoadingModel || !controller.transcription.isReady {
            return controller.transcription.statusMessage
        }
        switch controller.phase {
        case .idle, .success:
            return controller.readyStatusLine
        default:
            return controller.phase.label
        }
    }
}
