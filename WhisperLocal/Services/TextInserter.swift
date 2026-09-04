import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

enum InsertionMethod: String {
    case accessibility
    /// AXSet returned success but the field could not be confirmed.
    case accessibilityUnverified = "accessibility-unverified"
    case clipboard
    /// ⌘V was posted but the field could not be confirmed. The dictation is left on
    /// the clipboard so ⌘V recovers it.
    case clipboardUnverified = "clipboard-unverified"
    case failed
}

struct InsertionResult {
    let success: Bool
    let method: InsertionMethod
    let appName: String?
    /// The text is sitting on the clipboard and Cmd-V will recover it. Set when we
    /// could not type it, so a failed insert never means the take is simply gone.
    var textOnClipboard: Bool = false
}

/// Frontmost app at dictation start. Fed to polish LLMs as formatting context, not as transcript text.
struct TargetAppContext: Sendable, Equatable {
    enum Kind: String, Sendable, CaseIterable, Identifiable {
        case codeEditor = "code editor"
        case terminal = "terminal"
        case chat = "chat app"
        case browser = "browser"
        case mail = "mail app"
        case notes = "notes app"
        case other = "app"

        var id: String { rawValue }

        var menuLabel: String {
            switch self {
            case .other: return "Other"
            default: return rawValue.capitalized
            }
        }
    }

    let name: String
    let bundleID: String?
    let kind: Kind
    /// The process this take was aimed at. Insertion resolves this rather than
    /// asking for the frontmost app again, which after a Space switch is somebody
    /// else entirely.
    var pid: pid_t?

    var promptLine: String {
        kind == .other ? name : "\(name) — \(kind.rawValue)"
    }

    static func captureFrontmost() -> TargetAppContext? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        if let id = app.bundleIdentifier, id == Bundle.main.bundleIdentifier {
            return nil
        }
        let name = app.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else { return nil }
        let bundleID = app.bundleIdentifier
        return TargetAppContext(
            name: name,
            bundleID: bundleID,
            kind: kind(bundleID: bundleID, name: name),
            pid: app.processIdentifier
        )
    }

    static func kind(bundleID: String?, name: String?) -> Kind {
        let id = (bundleID ?? "").lowercased()
        let n = (name ?? "").lowercased()

        if matches(id, n, ids: [
            "com.anysphere.cursor", "com.anysphere.sand", "com.todesktop.230313mzl4w4u92",
            "com.microsoft.vscode", "com.apple.dt.xcode", "com.panic.nova",
            "com.sublimetext.4", "com.microsoft.VSCode"
        ], names: ["cursor", "visual studio code", "vs code", "xcode", "nova", "sublime text"]) {
            return .codeEditor
        }
        if matches(id, n, ids: [
            "com.apple.terminal", "com.googlecode.iterm2", "net.kovidgoyal.kitty",
            "io.alacritty", "dev.warp.warp-stable", "dev.warp.warp",
            "com.mitchellh.ghostty", "com.github.wez.wezterm"
        ], names: ["terminal", "iterm", "kitty", "alacritty", "warp", "ghostty", "wezterm"]) {
            return .terminal
        }
        if matches(id, n, ids: [
            "com.tinyspeck.slackmacgap", "com.hnc.discord", "com.openai.chat",
            "com.anthropic.claudefordesktop", "net.whatsapp.whatsapp",
            "com.apple.ichat", "com.apple.MobileSMS", "ru.keepcoder.telegram"
        ], names: ["slack", "discord", "chatgpt", "claude", "messages", "telegram", "whatsapp"]) {
            return .chat
        }
        if matches(id, n, ids: [
            "com.google.chrome", "com.apple.safari", "company.thebrowser.browser",
            "com.brave.browser", "com.microsoft.edgemac", "org.mozilla.firefox"
        ], names: ["chrome", "safari", "arc", "brave", "edge", "firefox"]) {
            return .browser
        }
        if matches(id, n, ids: ["com.apple.mail", "com.readdle.smartemail-mac"], names: ["mail", "spark"]) {
            return .mail
        }
        if matches(id, n, ids: [
            "com.apple.notes", "md.obsidian", "notion.id", "com.apple.iwork.pages"
        ], names: ["notes", "obsidian", "notion", "pages"]) {
            return .notes
        }
        if id.contains("anysphere") || n.contains("cursor") { return .codeEditor }
        if id.contains("terminal") || id.contains("iterm") { return .terminal }
        if id.contains("chrom") || id.contains("safari") { return .browser }
        return .other
    }

    private static func matches(
        _ id: String,
        _ name: String,
        ids: [String],
        names: [String]
    ) -> Bool {
        if ids.contains(where: { id == $0.lowercased() || id.hasPrefix($0.lowercased() + ".") }) {
            return true
        }
        return names.contains { name.contains($0) }
    }
}

@MainActor
final class TextInserter {
    static let shared = TextInserter()

    /// Bundle IDs where AX selected-text insert is unreliable — use clipboard paste.
    private let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "net.kovidgoyal.kitty",
        "io.alacritty",
        "dev.warp.Warp-Stable",
        "dev.warp.Warp",
        "com.mitchellh.ghostty",
        "com.github.wez.wezterm",
        "co.zeit.hyper",
        "com.termius-dmg.mac"
    ]

    /// Electron / Chromium apps where AXSet selected-text often returns success and types nothing
    /// (Cursor, Slack, Chrome, VS Code, …).
    private let clipboardFirstBundleIDs: Set<String> = [
        "com.anysphere.sand",              // Cursor (Anysphere)
        "com.anysphere.cursor",
        "com.todesktop.230313mzl4w4u92",   // Cursor (older id)
        "com.microsoft.VSCode",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.google.Chrome.dev",
        "company.thebrowser.Browser",      // Arc
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "com.tinyspeck.slackmacgap",
        "com.hnc.Discord",
        "com.openai.chat",
        "com.anthropic.claudefordesktop",
        "com.apple.Safari.WebApp"          // PWAs / web-app wrappers
    ]

    /// Name substrings for terminals without a known bundle ID.
    private let terminalNameHints = [
        "terminal", "iterm", "kitty", "alacritty", "warp", "ghostty",
        "wezterm", "hyper", "tabby", "termius", "waveterm", "console"
    ]

    func insert(_ text: String, into target: TargetAppContext? = nil) async -> InsertionResult {
        // Prefer the app the take was aimed at. Re-reading the frontmost app here
        // means a Space switch mid-dictation pastes into whatever happens to be in
        // front of the new Space.
        let frontApp = Self.resolveTarget(target) ?? NSWorkspace.shared.frontmostApplication
        let appName = frontApp?.localizedName
        let bundleID = frontApp?.bundleIdentifier

        // Strip BEL (\u{0007}) and other C0 controls — Terminal rings the bell on these.
        let sanitized = Self.sanitizeForPaste(text)
        guard !sanitized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return InsertionResult(success: false, method: .failed, appName: appName)
        }

        guard AXIsProcessTrusted() else {
            // Nothing can be typed without Accessibility, but the take must not
            // evaporate — park it where the user can paste it themselves.
            parkOnClipboard(sanitized)
            return InsertionResult(
                success: false, method: .failed, appName: appName, textOnClipboard: true
            )
        }

        let isTerminal = isTerminalApp(bundleID: bundleID, name: appName)
        let useClipboardFirst = isTerminal || prefersClipboardPaste(app: frontApp, bundleID: bundleID)

        // Electron/Chromium (Cursor, Slack, Chrome, …): AX insert lies about success.
        switch insertViaAccessibility(sanitized, skip: useClipboardFirst) {
        case .inserted:
            return InsertionResult(success: true, method: .accessibility, appName: appName)
        case .unverified:
            return InsertionResult(success: true, method: .accessibilityUnverified, appName: appName)
        case .skipped, .failed:
            break
        }

        let method = await insertViaClipboard(
            sanitized,
            into: frontApp,
            preferSlowTiming: useClipboardFirst
        )
        if method == .failed {
            parkOnClipboard(sanitized)
        }
        return InsertionResult(
            success: method != .failed,
            method: method,
            appName: appName,
            // Unverified already leaves the dictation on the clipboard.
            textOnClipboard: method == .failed || method == .clipboardUnverified
        )
    }

    /// Last resort: leave the text somewhere recoverable. A take that got this far
    /// is real user effort, and silently dropping it is the one outcome with no
    /// way back. Marked concealed/transient so clipboard managers still skip it.
    private func parkOnClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        pasteboard.writeObjects([item])
    }

    /// The captured process if it is still alive, else nil so the caller falls back
    /// to whatever is frontmost.
    private static func resolveTarget(_ target: TargetAppContext?) -> NSRunningApplication? {
        guard let target else { return nil }
        if let pid = target.pid,
           let app = NSRunningApplication(processIdentifier: pid),
           !app.isTerminated {
            return app
        }
        guard let bundleID = target.bundleID else { return nil }
        return NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .first { !$0.isTerminated }
    }

    /// Keep newlines/tabs/trailing spaces; drop BEL and other control chars that make Terminal beep.
    nonisolated static func sanitizeForPaste(_ text: String) -> String {
        let filtered = text.unicodeScalars.filter { scalar in
            if scalar == "\n" || scalar == "\t" || scalar == "\r" { return true }
            return scalar.value >= 0x20 && scalar.value != 0x7F
        }
        return String(String.UnicodeScalarView(filtered))
    }

    private func prefersClipboardPaste(app: NSRunningApplication?, bundleID: String?) -> Bool {
        if let bundleID, clipboardFirstBundleIDs.contains(bundleID) {
            return true
        }
        if let bundleID {
            let lower = bundleID.lowercased()
            if lower.contains("anysphere") || lower.contains("electron") || lower.contains("chrom") {
                return true
            }
        }
        return isElectronApp(app)
    }

    /// Cursor, VS Code, Slack, etc. ship `Electron Framework.framework`.
    private func isElectronApp(_ app: NSRunningApplication?) -> Bool {
        guard let bundleURL = app?.bundleURL else { return false }
        let electron = bundleURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("Frameworks")
            .appendingPathComponent("Electron Framework.framework")
        return FileManager.default.fileExists(atPath: electron.path)
    }

    private func isTerminalApp(bundleID: String?, name: String?) -> Bool {
        if let bundleID, terminalBundleIDs.contains(bundleID) {
            return true
        }
        if let bundleID {
            let lower = bundleID.lowercased()
            if lower.contains("terminal") || lower.contains("iterm") || lower.contains("kitty")
                || lower.contains("alacritty") || lower.contains("warp") || lower.contains("ghostty") {
                return true
            }
        }
        guard let name else { return false }
        let normalized = name.lowercased()
        return terminalNameHints.contains { normalized.contains($0) }
    }

    private enum AccessibilityInsert {
        case inserted
        /// AXSet returned success but we could not confirm. Treat as done so we do not paste twice.
        case unverified
        case skipped
        case failed
    }

    private func insertViaAccessibility(_ text: String, skip: Bool) -> AccessibilityInsert {
        if skip { return .skipped }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let focusStatus = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )
        guard focusStatus == .success, let focusedRef else { return .failed }
        let element = focusedRef as! AXUIElement

        var roleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
           let role = roleRef as? String {
            // Chromium/Electron composers are usually AXWebArea / AXGroup — AXSet is a no-op.
            if role == "AXWebArea" || role == "AXUnknown" {
                return .failed
            }
        }

        let setStatus = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )
        guard setStatus == .success else { return .failed }

        // Chromium often returns success without changing the field. Confirm it landed.
        if accessibilityInsertVisible(on: element, text: text) {
            return .inserted
        }
        return .unverified
    }

    private func accessibilityInsertVisible(on element: AXUIElement, text: String) -> Bool {
        var selectedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selectedRef) == .success,
           let selected = selectedRef as? String,
           selected == text {
            return true
        }
        var valueRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
           let value = valueRef as? String,
           value.contains(text) {
            return true
        }
        return false
    }

    private func insertViaClipboard(
        _ text: String,
        into targetApp: NSRunningApplication?,
        preferSlowTiming: Bool
    ) async -> InsertionMethod {
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)

        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        // Well-behaved clipboard managers skip items marked concealed/transient.
        // Universal Clipboard and history stores that honor nspasteboard.org will not keep dictation.
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        let wrote = pasteboard.writeObjects([item])
        guard wrote else { return .failed }

        await focusTargetApp(targetApp)

        // Brief settle so the target app sees the new clipboard contents.
        try? await Task.sleep(nanoseconds: preferSlowTiming ? 180_000_000 : 120_000_000)

        postCommandV(to: targetApp?.processIdentifier)

        // Poll rather than restoring on a fixed timer. The receiver reads the
        // pasteboard asynchronously and that read scales with payload size, so a
        // flat 450/700 ms window put the old clipboard back while a long paste was
        // still being pulled — and the paste landed empty. Short text still returns
        // at the old floor; only long text waits longer.
        let confirmed = await waitForPaste(text, slow: preferSlowTiming)
        if confirmed {
            restore(saved, to: pasteboard)
        }
        // Unconfirmed: leave the dictation on the clipboard. Restoring here is the
        // worse failure — the take is destroyed and the clipboard silently changes
        // under the user, so nothing they press recovers the text. Holding it means
        // ⌘V still works. The caller says so in the HUD.
        return confirmed ? .clipboard : .clipboardUnverified
    }

    /// Waits the previous fixed floor, then keeps polling up to a length-scaled
    /// deadline. Strictly additive: identical timing for short pastes.
    private func waitForPaste(_ text: String, slow: Bool) async -> Bool {
        let floor: TimeInterval = slow ? 0.7 : 0.45
        let deadline = min(Self.maxPasteWait, floor + Double(text.count) * 0.003)

        try? await Task.sleep(nanoseconds: UInt64(floor * 1_000_000_000))
        if clipboardInsertVisible(text) { return true }

        var elapsed = floor
        while elapsed < deadline {
            try? await Task.sleep(nanoseconds: Self.pastePollStep)
            elapsed += Double(Self.pastePollStep) / 1_000_000_000
            if clipboardInsertVisible(text) { return true }
        }
        return false
    }

    private static let maxPasteWait: TimeInterval = 3.0
    private static let pastePollStep: UInt64 = 60_000_000
    /// Enough of the text to identify it, short enough to survive reflow.
    private static let pasteProbeLength = 64

    private func clipboardInsertVisible(_ text: String) -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let focusStatus = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )
        guard focusStatus == .success, let focusedRef else { return false }
        let element = focusedRef as! AXUIElement
        if accessibilityInsertVisible(on: element, text: text) { return true }
        // A long paste is often reflowed, or AX exposes only part of the field, so
        // whole-string matching fails for exactly the pastes worth confirming.
        guard text.count > Self.pasteProbeLength else { return false }
        return accessibilityValueContains(element, String(text.prefix(Self.pasteProbeLength)))
    }

    private func accessibilityValueContains(_ element: AXUIElement, _ probe: String) -> Bool {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let value = valueRef as? String else { return false }
        return value.contains(probe)
    }

    private func focusTargetApp(_ app: NSRunningApplication?) async {
        guard let app else { return }
        let selfPID = ProcessInfo.processInfo.processIdentifier
        guard app.processIdentifier != selfPID else { return }
        if !app.isActive {
            app.activate(options: [.activateIgnoringOtherApps])
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
    }

    /// Four-event ⌘V via HID, posted to the target pid when possible.
    /// Session-tap + flags-on-V-only is ignored by many Electron webviews (Cursor, Slack).
    private func postCommandV(to pid: pid_t?) {
        let source = CGEventSource(stateID: .hidSystemState)
        let cmd: CGKeyCode = CGKeyCode(kVK_Command)
        let v: CGKeyCode = CGKeyCode(kVK_ANSI_V)

        let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: cmd, keyDown: true)
        let vDown = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true)
        let vUp = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false)
        let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: cmd, keyDown: false)
        vDown?.flags = .maskCommand
        vUp?.flags = .maskCommand

        let events = [cmdDown, vDown, vUp, cmdUp]
        if let pid {
            for (index, event) in events.enumerated() {
                event?.postToPid(pid)
                usleep(index == 1 ? 12_000 : 8_000)
            }
        } else {
            for (index, event) in events.enumerated() {
                event?.post(tap: .cghidEventTap)
                usleep(index == 1 ? 12_000 : 8_000)
            }
        }
        usleep(20_000)
    }

    private struct PasteboardSnapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]
    }

    private func snapshot(_ pasteboard: NSPasteboard) -> PasteboardSnapshot {
        var items: [[NSPasteboard.PasteboardType: Data]] = []
        for item in pasteboard.pasteboardItems ?? [] {
            var map: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    map[type] = data
                }
            }
            items.append(map)
        }
        return PasteboardSnapshot(items: items)
    }

    private func restore(_ snapshot: PasteboardSnapshot, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let items: [NSPasteboardItem] = snapshot.items.map { map in
            let item = NSPasteboardItem()
            for (type, data) in map {
                item.setData(data, forType: type)
            }
            return item
        }
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }
}
