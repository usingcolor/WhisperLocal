import AppKit
import Carbon.HIToolbox
import Foundation

enum HotkeyMode: String, CaseIterable, Identifiable, Codable {
    case hold
    case tap

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .hold: return "Hold to talk"
        case .tap: return "Tap to toggle"
        }
    }

    var helpText: String {
        switch self {
        case .hold: return "Press and hold while speaking, release to finish."
        case .tap: return "Press once to start, press again to stop."
        }
    }
}

/// Global hotkey manager with hold-to-talk or tap-to-toggle.
/// Default: Globe / Fn (macOS). Esc cancels while recording.
@MainActor
final class HotKeyManager: ObservableObject {
    static let shared = HotKeyManager()

    enum KeyChoice: String, CaseIterable, Identifiable {
        case fn
        case rightOption
        case leftOption
        case rightCommand

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .fn: return "Globe / Fn"
            case .rightOption: return "Right Option (⌥)"
            case .leftOption: return "Left Option (⌥)"
            case .rightCommand: return "Right Command (⌘)"
            }
        }

        var keyCode: UInt16 {
            switch self {
            case .fn: return 63
            case .rightOption: return 61
            case .leftOption: return 58
            case .rightCommand: return 54
            }
        }
    }

    @Published var selectedKey: KeyChoice {
        didSet {
            UserDefaults.standard.set(selectedKey.rawValue, forKey: "hotkeyChoice")
        }
    }

    @Published var mode: HotkeyMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: "hotkeyMode")
        }
    }

    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onCancel: (() -> Void)?

    private var flagsMonitor: Any?
    private var keyMonitor: Any?
    private var localFlagsMonitor: Any?
    private var localKeyMonitor: Any?
    private var isHolding = false
    /// True while a hold-session is active (used so Esc can cancel).
    private(set) var isSessionActive = false
    /// Shift was down on the hotkey press that started this take. Read once in `beginRecording`.
    private(set) var intentModifierHeld = false

    init() {
        if let raw = UserDefaults.standard.string(forKey: "hotkeyChoice"),
           let key = KeyChoice(rawValue: raw) {
            selectedKey = key
        } else {
            selectedKey = AppIdentity.isDevBuild ? .rightOption : .fn
        }

        if let raw = UserDefaults.standard.string(forKey: "hotkeyMode"),
           let mode = HotkeyMode(rawValue: raw) {
            self.mode = mode
        } else {
            self.mode = .hold
        }
    }

    func markSessionActive(_ active: Bool) {
        isSessionActive = active
        if !active {
            isHolding = false
        }
    }

    func start() {
        stop()

        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.handleFlagsChanged(event)
                }
            }
        }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.handleKeyDown(event)
                }
            }
        }
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleFlagsChanged(event)
            }
            return event
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleKeyDown(event)
            }
            return event
        }
    }

    func stop() {
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let localFlagsMonitor { NSEvent.removeMonitor(localFlagsMonitor) }
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        flagsMonitor = nil
        keyMonitor = nil
        localFlagsMonitor = nil
        localKeyMonitor = nil
        isHolding = false
        isSessionActive = false
        intentModifierHeld = false
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        guard event.keyCode == selectedKey.keyCode else { return }

        let pressed: Bool
        switch selectedKey {
        case .rightOption, .leftOption:
            pressed = event.modifierFlags.contains(.option)
        case .rightCommand:
            pressed = event.modifierFlags.contains(.command)
        case .fn:
            pressed = event.modifierFlags.contains(.function)
        }

        switch mode {
        case .hold:
            if pressed && !isHolding {
                intentModifierHeld = event.modifierFlags.contains(.shift)
                isHolding = true
                isSessionActive = true
                onPress?()
            } else if !pressed && isHolding {
                isHolding = false
                onRelease?()
            }
        case .tap:
            // Toggle on key-down edge only (ignore release).
            if pressed && !isHolding {
                intentModifierHeld = event.modifierFlags.contains(.shift)
                isHolding = true
                onPress?()
            } else if !pressed && isHolding {
                isHolding = false
            }
        }
    }

    private func handleKeyDown(_ event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape), isSessionActive {
            isHolding = false
            isSessionActive = false
            onCancel?()
        }
    }
}
