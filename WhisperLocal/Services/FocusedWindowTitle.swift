import ApplicationServices
import Foundation

/// The title of the window a take is dictated into: the document in Overleaf,
/// the chat in Claude, the folder in Terminal, the subject in Mail.
///
/// Dev only, and only recorded in the dictation log — never sent anywhere, not
/// even to polish. It is being collected to find out whether titles carry the
/// names and projects a take then uses, before anything is built on them: a
/// window title can be as private as an email subject.
enum FocusedWindowTitle {
    static var isEnabled: Bool { AppIdentity.isDevBuild }

    static let maxLength = 200
    /// An app that does not answer is waited on for this long, not the six
    /// seconds Accessibility allows by default.
    static let timeout: Float = 0.25

    /// Asks the app over Accessibility, so it can block; call it off the main thread.
    static func read(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        let element = window as! AXUIElement
        AXUIElementSetMessagingTimeout(element, timeout)
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title) == .success,
              let text = title as? String else { return nil }
        return clean(text)
    }

    /// One line, trimmed and capped. Nil when there is nothing to keep.
    static func clean(_ raw: String) -> String? {
        let oneLine = raw
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !oneLine.isEmpty else { return nil }
        guard oneLine.count > maxLength else { return oneLine }
        return String(oneLine.prefix(maxLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
