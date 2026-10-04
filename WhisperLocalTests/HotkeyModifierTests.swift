import AppKit
import Carbon.HIToolbox
import XCTest

@MainActor
final class HotkeyModifierTests: XCTestCase {
    func testContextShortcutDoesNotStartOrEndADictation() {
        withManager(flags: { [] }) { manager in
            var opened = 0
            var presses = 0
            var releases = 0
            manager.onOpenContext = { opened += 1 }
            manager.onPress = { presses += 1 }
            manager.onRelease = { releases += 1 }
            manager.handleModifierChange(keyCode: UInt16(kVK_Control), flags: .control)
            manager.handleModifierChange(keyCode: UInt16(kVK_Shift), flags: [.control, .shift])
            XCTAssertTrue(manager.handleKeyPress(keyCode: UInt16(kVK_ANSI_K), flags: [.control, .shift]))
            XCTAssertEqual(opened, 1)
            XCTAssertEqual(presses, 0)
            XCTAssertEqual(releases, 0)
            XCTAssertFalse(manager.isSessionActive)
            manager.handleKeyPress(keyCode: UInt16(kVK_ANSI_K), flags: [.control, .shift], isRepeat: true)
            XCTAssertEqual(opened, 1)
        }
    }

    func testContextShortcutRequiresTheChosenChordAndCanBeDisabled() {
        XCTAssertTrue(ContextWindowShortcut.controlShiftK.matches(keyCode: UInt16(kVK_ANSI_K), flags: [.control, .shift, .capsLock]))
        XCTAssertFalse(ContextWindowShortcut.controlShiftK.matches(keyCode: UInt16(kVK_ANSI_K), flags: [.command, .shift]))
        XCTAssertFalse(ContextWindowShortcut.controlShiftK.matches(keyCode: UInt16(kVK_ANSI_K), flags: [.control, .shift, .option]))
        XCTAssertTrue(ContextWindowShortcut.controlShiftJ.matches(keyCode: UInt16(kVK_ANSI_J), flags: [.control, .shift]))
        XCTAssertFalse(ContextWindowShortcut.none.matches(keyCode: UInt16(kVK_ANSI_K), flags: [.control, .shift]))
    }

    private func withManager(
        key: HotKeyManager.KeyChoice = .rightOption,
        mode: HotkeyMode = .hold,
        flags: @escaping () -> NSEvent.ModifierFlags,
        test: (HotKeyManager) -> Void
    ) {
        let suite = "HotkeyModifierTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(key.rawValue, forKey: "hotkeyChoice")
        defaults.set(mode.rawValue, forKey: "hotkeyMode")
        test(HotKeyManager(defaults: defaults, currentModifierFlags: flags))
    }

    func testHeldOptionDoesNotTriggerWatchdogEvenWithoutPolledSideBits() {
        for key in [HotKeyManager.KeyChoice.rightOption, .leftOption] {
            // NSEvent's current modifier state can be aggregate-only. The event
            // tells us the side; the watchdog must still trust that Option is held.
            var polled: NSEvent.ModifierFlags = .option
            let side = key == .rightOption ? NX_DEVICERALTKEYMASK : NX_DEVICELALTKEYMASK
            let down = NSEvent.ModifierFlags(rawValue: polled.rawValue | UInt(side))
            withManager(key: key, flags: { polled }) { manager in
                var presses = 0
                var releases = 0
                manager.onPress = { presses += 1 }
                manager.onRelease = { releases += 1 }
                manager.handleModifierChange(keyCode: key.keyCode, flags: down)
                XCTAssertEqual(presses, 1)
                // More samples than the three that previously ended the take.
                for _ in 0..<10 {
                    XCTAssertFalse(manager.missedHotkeyRelease)
                    XCTAssertTrue(manager.isSessionActive)
                }
                XCTAssertEqual(releases, 0)
                polled = []
                XCTAssertTrue(manager.missedHotkeyRelease, "a lost release must still be recoverable")
                manager.handleModifierChange(keyCode: key.keyCode, flags: [])
                XCTAssertEqual(releases, 1)
                XCTAssertFalse(manager.isSessionActive)
                XCTAssertFalse(manager.missedHotkeyRelease)
            }
        }
    }

    func testHeldCommandAndFnDoNotTriggerWatchdog() {
        let commandDown = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.rawValue | UInt(NX_DEVICERCMDKEYMASK))
        for (key, polled, event) in [
            (HotKeyManager.KeyChoice.rightCommand, NSEvent.ModifierFlags.command, commandDown),
            (.fn, .function, .function)
        ] {
            withManager(key: key, flags: { polled }) { manager in
                manager.handleModifierChange(keyCode: key.keyCode, flags: event)
                for _ in 0..<10 { XCTAssertFalse(manager.missedHotkeyRelease) }
                XCTAssertTrue(manager.isSessionActive)
            }
        }
    }

    func testARealRightOptionReleaseStillEndsTheTakeWhileLeftIsHeld() {
        let both = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue
                                        | UInt(NX_DEVICELALTKEYMASK | NX_DEVICERALTKEYMASK))
        let leftOnly = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue | UInt(NX_DEVICELALTKEYMASK))
        withManager(flags: { .option }) { manager in
            var releases = 0
            manager.onRelease = { releases += 1 }
            manager.handleModifierChange(keyCode: HotKeyManager.KeyChoice.rightOption.keyCode, flags: both)
            XCTAssertFalse(manager.missedHotkeyRelease)
            manager.handleModifierChange(keyCode: HotKeyManager.KeyChoice.rightOption.keyCode, flags: leftOnly)
            XCTAssertEqual(releases, 1)
            XCTAssertFalse(manager.isSessionActive)
        }
    }

    func testTapModeDoesNotFinishARecordingWhenTheKeyIsUp() {
        let down = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue | UInt(NX_DEVICERALTKEYMASK))
        withManager(mode: .tap, flags: { [] }) { manager in
            manager.handleModifierChange(keyCode: HotKeyManager.KeyChoice.rightOption.keyCode, flags: down)
            manager.handleModifierChange(keyCode: HotKeyManager.KeyChoice.rightOption.keyCode, flags: [])
            XCTAssertTrue(manager.isSessionActive)
            XCTAssertFalse(manager.missedHotkeyRelease)
        }
    }

    func testReleasingRightOptionWhileLeftIsHeldEndsTheRightHotkey() {
        let both = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue
                                        | UInt(NX_DEVICELALTKEYMASK | NX_DEVICERALTKEYMASK))
        XCTAssertTrue(HotKeyManager.hotkeyIsDown(.rightOption, flags: both))
        let leftOnly = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue
                                            | UInt(NX_DEVICELALTKEYMASK))
        XCTAssertFalse(HotKeyManager.hotkeyIsDown(.rightOption, flags: leftOnly))
        XCTAssertTrue(HotKeyManager.hotkeyIsDown(.leftOption, flags: leftOnly))
    }

    func testReleasingLeftOptionWhileRightIsHeldEndsTheLeftHotkey() {
        let rightOnly = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue
                                             | UInt(NX_DEVICERALTKEYMASK))
        XCTAssertFalse(HotKeyManager.hotkeyIsDown(.leftOption, flags: rightOnly))
        XCTAssertTrue(HotKeyManager.hotkeyIsDown(.rightOption, flags: rightOnly))
    }

    func testRightCommandDoesNotFollowTheLeftCommandFlag() {
        let leftOnly = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.rawValue
                                            | UInt(NX_DEVICELCMDKEYMASK))
        XCTAssertFalse(HotKeyManager.hotkeyIsDown(.rightCommand, flags: leftOnly))
        let rightOnly = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.rawValue
                                             | UInt(NX_DEVICERCMDKEYMASK))
        XCTAssertTrue(HotKeyManager.hotkeyIsDown(.rightCommand, flags: rightOnly))
    }

    func testFnStillFollowsTheFunctionFlag() {
        XCTAssertTrue(HotKeyManager.hotkeyIsDown(.fn, flags: .function))
        XCTAssertFalse(HotKeyManager.hotkeyIsDown(.fn, flags: .option))
    }
}
