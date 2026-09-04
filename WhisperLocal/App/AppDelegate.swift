import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // MenuBarExtra `.menu` content often does not appear until the user
        // clicks the status item — so hotkeys must start here, not in onAppear.
        AppleSpeechASR.sweepStaleTempAudio()
        DictationController.shared.start()
        if !AppIdentity.isDevBuild {
            AppUpdater.shared.presentPendingInstallFailureIfNeeded()
        }
    }

    /// Quitting used to discard a take in flight without a word — including one
    /// already transcribing, where minutes of speech can be waiting on a model.
    /// Ask, the way any app with unsaved work does.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let controller = DictationController.shared
        guard let work = controller.workInProgressDescription else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = "\(AppIdentity.productName) is still \(work)."
        alert.informativeText = "Quitting now discards it."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit Anyway")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        DictationController.shared.stop()
    }
}
