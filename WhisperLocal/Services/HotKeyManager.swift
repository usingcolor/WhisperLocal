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

enum ContextWindowShortcut: String, CaseIterable, Identifiable {
    case controlShiftK, controlShiftJ, none
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .controlShiftK: return "⌃⇧K"
        case .controlShiftJ: return "⌃⇧J"
        case .none: return "None"
        }
    }
    func matches(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        guard self != .none else { return false }
        let key = self == .controlShiftK ? kVK_ANSI_K : kVK_ANSI_J
        let modifiers = flags.intersection([.control, .shift, .command, .option, .function])
        return keyCode == UInt16(key) && modifiers == [.control, .shift]
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
            defaults.set(selectedKey.rawValue, forKey: "hotkeyChoice")
        }
    }

    @Published var mode: HotkeyMode {
        didSet {
            defaults.set(mode.rawValue, forKey: "hotkeyMode")
        }
    }

    @Published var contextShortcut: ContextWindowShortcut {
        didSet { defaults.set(contextShortcut.rawValue, forKey: "contextWindowShortcut") }
    }

    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onCancel: (() -> Void)?
    var onOpenContext: (() -> Void)?
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
    private let defaults: UserDefaults
    private let currentModifierFlags: () -> NSEvent.ModifierFlags

    init(
        defaults: UserDefaults = .standard,
        currentModifierFlags: @escaping () -> NSEvent.ModifierFlags = { NSEvent.modifierFlags }
    ) {
        self.defaults = defaults
        self.currentModifierFlags = currentModifierFlags
        contextShortcut = defaults.string(forKey: "contextWindowShortcut")
            .flatMap(ContextWindowShortcut.init(rawValue:)) ?? .controlShiftK
        if let raw = defaults.string(forKey: "hotkeyChoice"),
           let key = KeyChoice(rawValue: raw) {
            selectedKey = key
        } else {
            selectedKey = AppIdentity.isDevBuild ? .rightOption : .fn
        }

        if let raw = defaults.string(forKey: "hotkeyMode"),
           let mode = HotkeyMode(rawValue: raw) {
            self.mode = mode
        } else {
            self.mode = .hold
        }
    }

    /// macOS Secure Event Input, which a focused password field turns on and some
    /// apps leave on. While it is active the system withholds key events from other
    /// processes, so the global monitors this class relies on stop firing and the
    /// hotkey goes completely dead with nothing to explain it.
    static var secureInputActive: Bool {
        IsSecureEventInputEnabled()
    }

    /// Is the hotkey's modifier group down *right now*?
    ///
    /// The state machine is edge-driven, so a `flagsChanged` it never receives
    /// leaves it stuck: `isHolding` stays true, the next press is swallowed by the
    /// `pressed && !isHolding` guard, and the app goes completely silent. A Space
    /// switch is one way to lose that edge. This is the ground truth to reconcile
    /// against, rather than trusting we saw every transition. Use modifier flags:
    /// polling CGEventSource.keyState for a modifier falsely reported key-up on
    /// this Mac and the watchdog ended held takes after three ticks (1.5 seconds).
    /// Polling is deliberately conservative if the opposite modifier is held;
    /// delivered events below still distinguish left from right.
    static func hotkeyModifierIsDown(_ key: KeyChoice, flags: NSEvent.ModifierFlags) -> Bool {
        switch key {
        case .rightOption, .leftOption: return flags.contains(.option)
        case .rightCommand: return flags.contains(.command)
        case .fn: return flags.contains(.function)
        }
    }

    /// Event flags retain which side changed. Aggregate Option/Command stays on
    /// after our key is released if its opposite is still held.
    static func hotkeyIsDown(_ key: KeyChoice, flags: NSEvent.ModifierFlags) -> Bool {
        switch key {
        case .rightOption: return flags.rawValue & UInt(NX_DEVICERALTKEYMASK) != 0
        case .leftOption: return flags.rawValue & UInt(NX_DEVICELALTKEYMASK) != 0
        case .rightCommand: return flags.rawValue & UInt(NX_DEVICERCMDKEYMASK) != 0
        case .fn: return flags.contains(.function)
        }
    }

    /// True when we believe a hold is running but the key is not actually held.
    var missedHotkeyRelease: Bool {
        guard mode == .hold, isHolding else { return false }
        return !Self.hotkeyModifierIsDown(selectedKey, flags: currentModifierFlags())
    }

    func markSessionActive(_ active: Bool) {
        isSessionActive = active
        if !active {
            isHolding = false
        }
    }

    func start() {
        stop()
        shiftWasDown = currentModifierFlags().contains(.shift)

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
                    _ = self?.handleKeyDown(event)
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
            var consumed = false
            MainActor.assumeIsolated {
                consumed = self?.handleKeyDown(event) ?? false
            }
            return consumed ? nil : event
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
        handleModifierChange(keyCode: event.keyCode, flags: event.modifierFlags)
    }

    /// Also exercises event delivery and watchdog sampling without installing a
    /// global event monitor in tests.
    func handleModifierChange(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        let shiftDown = flags.contains(.shift)
        let shiftPressed = shiftDown && !shiftWasDown
        shiftWasDown = shiftDown

        let isHotkeyEvent = keyCode == selectedKey.keyCode
        if isHotkeyEvent {
            handleHotkeyFlagsChanged(flags, shiftDown: shiftDown)
        }

        // Shift is a switch for this take: press to turn context on, press again to turn it off.
        // Skip the hotkey event so Shift+hotkey at start is counted once, and stop doesn't flip it.
        if isSessionActive, shiftPressed, !isHotkeyEvent {
            intentModifierHeld.toggle()
            onIntentModifierChanged?(intentModifierHeld)
        }
    }

    private func handleHotkeyFlagsChanged(_ flags: NSEvent.ModifierFlags, shiftDown: Bool) {
        let pressed = Self.hotkeyIsDown(selectedKey, flags: flags)

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

    @discardableResult
    private func handleKeyDown(_ event: NSEvent) -> Bool {
        handleKeyPress(keyCode: event.keyCode, flags: event.modifierFlags, isRepeat: event.isARepeat)
    }

    @discardableResult
    func handleKeyPress(keyCode: UInt16, flags: NSEvent.ModifierFlags, isRepeat: Bool = false) -> Bool {
        if contextShortcut.matches(keyCode: keyCode, flags: flags) {
            if !isRepeat { onOpenContext?() }
            return true
        }
        guard keyCode == UInt16(kVK_Escape) else { return false }
        // Not gated on isSessionActive any more: the session is already over while a
        // take is being transcribed, and that is exactly when Escape needs to reach
        // the controller. The controller decides whether there is anything to cancel.
        isHolding = false
        isSessionActive = false
        onCancel?()
        return false
    }
}
