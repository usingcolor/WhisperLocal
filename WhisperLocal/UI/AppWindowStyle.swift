import AppKit
import SwiftUI

/// The grouped content surface used throughout the app's utility windows.
struct AppGroupedForm<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .padding(.trailing, 4)
    }
}

/// Split windows place their title above the detail column; standalone windows
/// keep the standard title. Both use the same native toolbar treatment.
struct AppWindowChrome: NSViewRepresentable {
    var hidesTitle = false

    func makeNSView(context: Context) -> NSView {
        let view = AppWindowChromeView()
        view.hidesTitle = hidesTitle
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? AppWindowChromeView)?.hidesTitle = hidesTitle
    }
}

private final class AppWindowChromeView: NSView {
    var hidesTitle = false { didSet { apply() } }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        apply()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        apply()
    }

    private func apply() {
        guard let window else { return }
        window.titleVisibility = hidesTitle ? .hidden : .visible
        window.toolbarStyle = .unified
    }
}
