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
    /// Shift pressed while a take is running. `true` = context, `false` = paste. Can flip either way.
    var onIntentModifierChanged: ((Bool) -> Void)?

    private var flagsMonitor: Any?
    private var keyMonitor: Any?
    private var localFlagsMonitor: Any?
    private var localKeyMonitor: Any?
    private var isHolding = false
    /// True while a hold-session is active (used so Esc can cancel).
    private(set) var isSessionActive = false
    /// Shift switch for the current take. Sampled at start, toggled by later Shift presses, read at finish.
    private(set) var intentModifierHeld = false
    private var shiftWasDown = false

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

    /// Is the hotkey modifier physically down *right now*?
    ///
    /// The state machine is edge-driven, so a `flagsChanged` it never receives
    /// leaves it stuck: `isHolding` stays true, the next press is swallowed by the
    /// `pressed && !isHolding` guard, and the app goes completely silent. A Space
    /// switch is one way to lose that edge. This is the ground truth to reconcile
    /// against, rather than trusting we saw every transition.
    static func hotkeyIsDown(_ key: KeyChoice, flags: NSEvent.ModifierFlags = NSEvent.modifierFlags) -> Bool {
        switch key {
        case .rightOption, .leftOption: return flags.contains(.option)
        case .rightCommand: return flags.contains(.command)
        case .fn: return flags.contains(.function)
        }
    }

    /// True when we believe a hold is running but the key is not actually held.
    var missedHotkeyRelease: Bool {
        guard mode == .hold, isHolding else { return false }
        return !Self.hotkeyIsDown(selectedKey)
    }

    func markSessionActive(_ active: Bool) {
        isSessionActive = active
        if !active {
            isHolding = false
        }
    }

    func start() {
        stop()
        shiftWasDown = NSEvent.modifierFlags.contains(.shift)

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
        shiftWasDown = false
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let shiftDown = event.modifierFlags.contains(.shift)
        let shiftPressed = shiftDown && !shiftWasDown
        shiftWasDown = shiftDown

        let isHotkeyEvent = event.keyCode == selectedKey.keyCode
        if isHotkeyEvent {
            handleHotkeyFlagsChanged(event, shiftDown: shiftDown)
        }

        // Shift is a switch for this take: press to turn context on, press again to turn it off.
        // Skip the hotkey event so Shift+hotkey at start is counted once, and stop doesn't flip it.
        if isSessionActive, shiftPressed, !isHotkeyEvent {
            intentModifierHeld.toggle()
            onIntentModifierChanged?(intentModifierHeld)
        }
    }

    private func handleHotkeyFlagsChanged(_ event: NSEvent, shiftDown: Bool) {
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
                intentModifierHeld = shiftDown
                isHolding = true
                isSessionActive = true
                onPress?()
            } else if !pressed && isHolding {
                isHolding = false
                isSessionActive = false
                onRelease?()
            }
        case .tap:
            // Toggle on key-down edge only (ignore release).
            if pressed && !isHolding {
                if !isSessionActive {
                    intentModifierHeld = shiftDown
                    isSessionActive = true
                } else {
                    // Stopping: freeze the switch so the finish path reads the last choice.
                    isSessionActive = false
                }
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
