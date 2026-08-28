import AppKit
import SwiftUI

/// Menu-bar (LSUIElement) apps often open windows behind the current Space.
/// Activate, move onto this Space, and raise — and restore accessory policy when idle.
@MainActor
enum AppWindowFocus {
    /// Restored windows must not steal focus on launch — that kills the dictation hotkey.
    static var shouldRaiseRestoredWindows = false
    static func present(title: String, open: () -> Void) {
        shouldRaiseRestoredWindows = true
        becomeRegular()
        activate()
        open()
        focus(title: title)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            activate()
            focus(title: title)
            try? await Task.sleep(nanoseconds: 180_000_000)
            activate()
            focus(title: title)
        }
    }

    static func raise(_ window: NSWindow) {
        guard !(window is NSPanel) else { return }
        becomeRegular()
        activate()
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    static func restoreAccessoryPolicyIfIdle() {
        let hasVisibleKeyWindow = NSApp.windows.contains { window in
            window.isVisible
                && window.canBecomeKey
                && !(window is NSPanel)
                && !window.title.isEmpty
        }
        if !hasVisibleKeyWindow {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    static func activate() {
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
    }

    static func becomeRegular() {
        NSApp.setActivationPolicy(.regular)
    }

    static func focus(title: String) {
        let matches = NSApp.windows.filter { window in
            guard window.canBecomeKey, !(window is NSPanel) else { return false }
            if window.title == title { return true }
            if window.identifier?.rawValue == title { return true }
            return false
        }
        if let window = matches.last ?? matches.first {
            raise(window)
            return
        }
        // SwiftUI may not have set the title yet — raise the newest keyable window.
        if let window = NSApp.windows.reversed().first(where: { $0.canBecomeKey && !($0 is NSPanel) }) {
            raise(window)
        }
    }
}

/// Attach to a window's root view so it comes forward as soon as AppKit creates it.
struct RaiseWindowOnAppear: ViewModifier {
    func body(content: Content) -> some View {
        content.background(WindowRaiser())
    }
}

extension View {
    func raiseWindowOnAppear() -> some View {
        modifier(RaiseWindowOnAppear())
    }
}

private struct WindowRaiser: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowRaiserView {
        WindowRaiserView()
    }

    func updateNSView(_ nsView: WindowRaiserView, context: Context) {}
}

final class WindowRaiserView: NSView {
    private var closeObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        if AppWindowFocus.shouldRaiseRestoredWindows {
            Task { @MainActor in
                AppWindowFocus.raise(window)
            }
        }
        disableHostingWindowSizing(from: self)

        if closeObserver == nil {
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { _ in
                Task { @MainActor in
                    AppWindowFocus.restoreAccessoryPolicyIfIdle()
                }
            }
        }
    }

    deinit {
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
    }
}

/// macOS 26 crashes if NSHostingView drives window min/max size during Auto Layout.
private func disableHostingWindowSizing(from view: NSView) {
    DispatchQueue.main.async {
        var node: NSView? = view
        while let current = node {
            if current.responds(to: NSSelectorFromString("setSizingOptions:")) {
                current.setValue(0, forKey: "sizingOptions")
            }
            node = current.superview
        }
    }
}
