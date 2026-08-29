import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // MenuBarExtra `.menu` content often does not appear until the user
        // clicks the status item — so hotkeys must start here, not in onAppear.
        AppleSpeechASR.sweepStaleTempAudio()
        DictationController.shared.start()
    }
}
