import CoreAudio
import XCTest

final class AudioIdleHoldTests: XCTestCase {
    func testBluetoothInputHoldsLongEnoughToAvoidReconnect() {
        let route = AudioInputRoute(transport: .bluetooth, bluetoothInputIsAlsoOutput: false)
        XCTAssertEqual(AudioIdleHold.nanoseconds(for: route), 45_000_000_000)
        XCTAssertEqual(route.logReason, "bluetooth input")
    }

    func testBluetoothThatIsAlsoPlayingDropsQuickly() {
        let route = AudioInputRoute(transport: .bluetooth, bluetoothInputIsAlsoOutput: true)
        XCTAssertEqual(AudioIdleHold.nanoseconds(for: route), 2_000_000_000)
        XCTAssertEqual(route.logReason, "bluetooth also playing")
    }

    func testBuiltInAndUnknownUseTheShortHold() {
        let wired = AudioInputRoute(transport: .wired, bluetoothInputIsAlsoOutput: false)
        let unknown = AudioInputRoute(transport: .unknown, bluetoothInputIsAlsoOutput: false)
        XCTAssertEqual(AudioIdleHold.nanoseconds(for: wired), 2_000_000_000)
        XCTAssertEqual(AudioIdleHold.nanoseconds(for: unknown), 2_000_000_000)
        XCTAssertEqual(wired.logReason, "wired input")
        XCTAssertEqual(unknown.logReason, "unknown input")
    }

    func testAlsoPlayingDoesNotAffectWiredHold() {
        let route = AudioInputRoute(transport: .wired, bluetoothInputIsAlsoOutput: true)
        XCTAssertEqual(AudioIdleHold.nanoseconds(for: route), 2_000_000_000)
    }
}

final class AudioInputTransportTests: XCTestCase {
    func testClassifiesBluetoothAndBluetoothLE() {
        XCTAssertEqual(AudioInputTransport.classify(kAudioDeviceTransportTypeBluetooth), .bluetooth)
        XCTAssertEqual(AudioInputTransport.classify(kAudioDeviceTransportTypeBluetoothLE), .bluetooth)
    }

    func testClassifiesBuiltInAndWiredApart() {
        XCTAssertEqual(AudioInputTransport.classify(kAudioDeviceTransportTypeBuiltIn), .builtIn)
        XCTAssertEqual(AudioInputTransport.classify(kAudioDeviceTransportTypeUSB), .wired)
        XCTAssertEqual(AudioInputTransport.classify(kAudioDeviceTransportTypeThunderbolt), .wired)
    }

    /// Loopback and aggregate devices record whatever is routed into them, which
    /// can be nothing at all — so they must never be picked automatically.
    func testSoftwareDevicesAreVirtual() {
        XCTAssertEqual(AudioInputTransport.classify(kAudioDeviceTransportTypeVirtual), .virtual)
        XCTAssertEqual(AudioInputTransport.classify(kAudioDeviceTransportTypeAggregate), .virtual)
        XCTAssertFalse(AudioInputTransport.virtual.canProtectPlayback)
        XCTAssertFalse(AudioInputTransport.other.canProtectPlayback)
        XCTAssertFalse(AudioInputTransport.unknown.canProtectPlayback)
        XCTAssertTrue(AudioInputTransport.builtIn.canProtectPlayback)
        XCTAssertTrue(AudioInputTransport.wired.canProtectPlayback)
    }

    /// Continuity Capture is a real microphone, but reaching for the speaker's
    /// phone unasked is not this rule's business.
    func testUnmodelledTransportsAreOther() {
        XCTAssertEqual(AudioInputTransport.classify(kAudioDeviceTransportTypeContinuityCaptureWireless), .other)
        XCTAssertEqual(AudioInputTransport.classify(kAudioDeviceTransportTypeAirPlay), .other)
    }

    func testFailedQueryIsUnknown() {
        XCTAssertEqual(AudioInputTransport.classify(nil), .unknown)
    }
}

final class AudioInputRouteUIDTests: XCTestCase {
    func testMatchingUIDsAreTheSameHardware() {
        XCTAssertTrue(AudioInputRoute.devicesShareHardware(
            inputUID: "00-11-22-33-44-55",
            outputUID: "00-11-22-33-44-55"
        ))
    }

    func testInputOutputSuffixesAreTheSameRadio() {
        XCTAssertTrue(AudioInputRoute.devicesShareHardware(
            inputUID: "00-11-22-33-44-55:input",
            outputUID: "00-11-22-33-44-55:output"
        ))
        XCTAssertEqual(
            AudioInputRoute.hardwareStem("AA-BB:input"),
            AudioInputRoute.hardwareStem("AA-BB:output")
        )
    }

    func testDifferentDevicesDoNotMatch() {
        XCTAssertFalse(AudioInputRoute.devicesShareHardware(
            inputUID: "airpods-uid",
            outputUID: "macbook-speakers"
        ))
        XCTAssertFalse(AudioInputRoute.devicesShareHardware(inputUID: nil, outputUID: "x"))
        XCTAssertFalse(AudioInputRoute.devicesShareHardware(inputUID: "", outputUID: ""))
    }

    func testColonSeparatedMACAddressesAreDifferentDevices() {
        XCTAssertFalse(AudioInputRoute.devicesShareHardware(
            inputUID: "00:11:22:33:44:55",
            outputUID: "00:11:22:33:44:66"
        ))
        XCTAssertEqual(AudioInputRoute.hardwareStem("00:11:22:33:44:55"), "00:11:22:33:44:55")
    }

    func testDashSeparatedMACAddressesAreDifferentDevices() {
        XCTAssertFalse(AudioInputRoute.devicesShareHardware(
            inputUID: "00-11-22-33-44-55",
            outputUID: "00-11-22-33-44-66"
        ))
    }

    func testColonMACWithInputOutputSuffixesAreTheSameRadio() {
        XCTAssertTrue(AudioInputRoute.devicesShareHardware(
            inputUID: "00:11:22:33:44:55:input",
            outputUID: "00:11:22:33:44:55:output"
        ))
        XCTAssertEqual(
            AudioInputRoute.hardwareStem("00:11:22:33:44:55:input"),
            "00:11:22:33:44:55"
        )
    }

    func testSeparateHFPAndA2DPDevicesCountAsAlsoPlaying() {
        XCTAssertTrue(AudioInputRoute.bluetoothInputIsAlsoOutput(
            inputID: 12,
            outputID: 34,
            inputUID: "hfp-uid",
            outputUID: "a2dp-uid",
            inputName: "AirPods Pro",
            outputName: "AirPods Pro",
            outputTransport: .bluetooth
        ))
    }

    func testBluetoothMicWithBuiltInSpeakersIsNotAlsoPlaying() {
        XCTAssertFalse(AudioInputRoute.bluetoothInputIsAlsoOutput(
            inputID: 12,
            outputID: 1,
            inputUID: "hfp-uid",
            outputUID: "BuiltInSpeakerDevice",
            inputName: "AirPods Pro",
            outputName: "MacBook Air Speakers",
            outputTransport: .builtIn
        ))
    }
}

/// The two halves of one headset are named after the headset; some adapters add
/// the role to one end only.
final class AudioDeviceNameTests: XCTestCase {
    func testTheSameHeadsetOnBothEnds() {
        XCTAssertTrue(AudioInputRoute.devicesShareName(inputName: "AirPods Pro", outputName: "AirPods Pro"))
        XCTAssertTrue(AudioInputRoute.devicesShareName(inputName: "airpods pro", outputName: "AirPods Pro"))
    }

    func testRoleSuffixesComeOff() {
        XCTAssertTrue(AudioInputRoute.devicesShareName(
            inputName: "Jabra Elite (Hands-Free)", outputName: "Jabra Elite (Stereo)"
        ))
        XCTAssertTrue(AudioInputRoute.devicesShareName(
            inputName: "Bose QC Microphone", outputName: "Bose QC Headphones"
        ))
        XCTAssertEqual(AudioInputRoute.nameStem("Sony WH-1000XM5 Stereo Headset"), "sony wh-1000xm5")
    }

    func testDifferentHeadsetsDoNotMatch() {
        XCTAssertFalse(AudioInputRoute.devicesShareName(inputName: "AirPods Pro", outputName: "Bose QC"))
        XCTAssertFalse(AudioInputRoute.devicesShareName(inputName: "AirPods", outputName: "AirPods Max"))
    }

    /// A name that is nothing but a role word tells us nothing, so it must not
    /// match another such name.
    func testARoleOnlyNameMatchesNothing() {
        XCTAssertNil(AudioInputRoute.nameStem("Microphone"))
        XCTAssertNil(AudioInputRoute.nameStem(nil))
        XCTAssertFalse(AudioInputRoute.devicesShareName(inputName: "Microphone", outputName: "Speakers"))
    }
}

final class AudioTapLivenessTests: XCTestCase {
    func testGatedSilenceIsNotLive() {
        XCTAssertFalse(AudioTapLiveness.bufferIsLive([0, 0, 0, -0.0]))
        XCTAssertFalse(AudioTapLiveness.bufferIsLive([]))
    }

    func testAnyNonzeroSampleIsLive() {
        XCTAssertTrue(AudioTapLiveness.bufferIsLive([0, 0, 1e-8, 0]))
        XCTAssertTrue(AudioTapLiveness.bufferIsLive([-0.0001]))
    }
}

/// The menu's order and what the HUD chip says, without needing real hardware.
final class AudioInputDeviceListTests: XCTestCase {
    private func device(
        _ name: String,
        uid: String? = nil,
        transport: AudioInputTransport = .wired,
        isDefault: Bool = false
    ) -> AudioInputDevice {
        AudioInputDevice(
            id: 0, uid: uid ?? name, name: name, transport: transport,
            isSystemDefault: isDefault
        )
    }

    /// Bluetooth sits below the wired mics but above the loopback devices: people
    /// dictate into headsets, not into BlackHole.
    func testBuiltInFirstThenWiredThenBluetoothThenVirtual() {
        let sorted = AudioInputSelection.sortedForMenu([
            device("AirPods Pro", transport: .bluetooth),
            device("Scarlett Solo"),
            device("MacBook Pro Microphone", transport: .builtIn),
            device("BlackHole 2ch", transport: .virtual),
            device("Apogee Duet")
        ])
        XCTAssertEqual(sorted.map(\.name), [
            "MacBook Pro Microphone", "Apogee Duet", "Scarlett Solo", "AirPods Pro", "BlackHole 2ch"
        ])
    }

    func testAnUnpluggedChoiceResolvesToNothing() {
        let connected = [device("MacBook Pro Microphone", transport: .builtIn, isDefault: true)]
        XCTAssertNil(AudioInputSelection.resolve(preferredUID: "gone-usb-mic", in: connected))
        XCTAssertNil(AudioInputSelection.resolve(preferredUID: nil, in: connected))
        XCTAssertNil(AudioInputSelection.resolve(preferredUID: "", in: connected))
    }

    func testChipNamesTheChoiceOrTheDefaultItFollows() {
        let devices = [
            device("MacBook Pro Microphone", transport: .builtIn, isDefault: true),
            device("Scarlett Solo", uid: "scarlett")
        ]
        XCTAssertEqual(AudioInputSelection.activeName(preferredUID: "scarlett", in: devices), "Scarlett Solo")
        // No choice: the chip has to name whatever System Settings points at.
        XCTAssertEqual(AudioInputSelection.activeName(preferredUID: nil, in: devices), "MacBook Pro Microphone")
        // Chosen device unplugged: fall back to the default, exactly as the take will.
        XCTAssertEqual(AudioInputSelection.activeName(preferredUID: "gone", in: devices), "MacBook Pro Microphone")
        XCTAssertNil(AudioInputSelection.activeName(preferredUID: nil, in: []))
    }
}

/// One list, three places it is shown — so it is built once and tested once.
final class InputMenuTests: XCTestCase {
    private let devices = [
        AudioInputDevice(id: 1, uid: "builtin", name: "MacBook Pro Microphone",
                         transport: .builtIn, isSystemDefault: true),
        AudioInputDevice(id: 2, uid: "scarlett", name: "Scarlett Solo",
                         transport: .wired, isSystemDefault: false)
    ]

    func testFollowingTheSystemIsTickedWhenNothingIsChosen() {
        let items = InputMenu.items(devices: devices, chosenUID: nil)
        XCTAssertEqual(items.first?.title, InputMenu.followTitle)
        XCTAssertTrue(items[0].isChecked)
        XCTAssertFalse(items.dropFirst().contains { $0.isChecked })
        XCTAssertTrue(items[1].title.contains("system default"))
    }

    func testTheChosenDeviceIsTheOnlyTick() {
        let items = InputMenu.items(devices: devices, chosenUID: "scarlett")
        XCTAssertEqual(items.filter(\.isChecked).map(\.uid), ["scarlett"])
        XCTAssertFalse(items[0].isChecked)
    }

    func testAnEmptyChoiceCountsAsFollowingTheSystem() {
        XCTAssertTrue(InputMenu.items(devices: devices, chosenUID: "").first?.isChecked == true)
    }

    func testAnUnpluggedChoiceSaysSoAndCannotBePicked() {
        let items = InputMenu.items(devices: devices, chosenUID: "gone")
        let last = try? XCTUnwrap(items.last)
        XCTAssertEqual(last?.title, InputMenu.missingTitle)
        XCTAssertEqual(last?.isEnabled, false)
        XCTAssertFalse(items.contains { $0.isChecked })
    }
}

/// Every pairing of input and output this app can meet, and the microphone each
/// one should open. The rule only exists to stop a take collapsing playback, so
/// the cases that matter are the ones where input and output are the same radio.
final class InputPlanTests: XCTestCase {
    private let airpods = AudioInputDevice(
        id: 2, uid: "airpods:input", name: "AirPods Pro",
        transport: .bluetooth, isSystemDefault: true
    )
    private let builtIn = AudioInputDevice(
        id: 1, uid: "builtin", name: "MacBook Air Microphone",
        transport: .builtIn, isSystemDefault: false
    )
    private let usb = AudioInputDevice(
        id: 3, uid: "scarlett", name: "Scarlett Solo",
        transport: .wired, isSystemDefault: false
    )
    private let loopback = AudioInputDevice(
        id: 4, uid: "blackhole", name: "BlackHole 2ch",
        transport: .virtual, isSystemDefault: false
    )

    private func plan(
        preferred: String? = nil,
        route: AudioInputRoute,
        connected: [AudioInputDevice]? = nil
    ) -> AudioInputSelection.InputChoice {
        AudioInputSelection.plan(
            preferredUID: preferred,
            connected: connected ?? [builtIn, airpods, usb],
            route: route
        )
    }

    private let both = AudioInputRoute(transport: .bluetooth, bluetoothInputIsAlsoOutput: true)

    /// The case that started this: AirPods on both ends. Opening their mic drags
    /// them out of A2DP, and macOS keeps a different volume for the other profile,
    /// so playback jumps at the moment a take begins.
    func testAirPodsOnBothEndsRecordsFromTheBuiltInMic() {
        XCTAssertEqual(plan(route: both), .protectPlayback(uid: "builtin"))
    }

    /// Picking the headset mic is how the rule is turned off, and it says which
    /// microphone to use instead of only saying "not that one". There is no
    /// separate switch.
    func testPickingTheHeadsetMicIsHowTheRuleIsTurnedOff() {
        XCTAssertEqual(plan(preferred: "airpods:input", route: both), .chosen("airpods:input"))
    }

    /// A Bluetooth mic while something else plays: nothing to protect, so the
    /// speaker's own default stands.
    func testBluetoothMicWithPlaybackElsewhereIsLeftAlone() {
        let micOnly = AudioInputRoute(transport: .bluetooth, bluetoothInputIsAlsoOutput: false)
        XCTAssertEqual(plan(route: micOnly), .systemDefault)
    }

    func testWiredAndBuiltInPairsAreLeftAlone() {
        XCTAssertEqual(plan(route: AudioInputRoute(transport: .wired, bluetoothInputIsAlsoOutput: false)), .systemDefault)
        XCTAssertEqual(plan(route: AudioInputRoute(transport: .unknown, bluetoothInputIsAlsoOutput: false)), .systemDefault)
    }

    /// An explicit choice outranks the rule — including the choice that costs
    /// playback quality, which is the speaker's to make.
    func testAChosenMicWinsOverTheProtection() {
        XCTAssertEqual(plan(preferred: "airpods:input", route: both), .chosen("airpods:input"))
        XCTAssertEqual(plan(preferred: "scarlett", route: both), .chosen("scarlett"))
    }

    /// Unplugged since it was chosen: fall back to the default, and the rule
    /// applies again from there rather than being skipped.
    func testAnUnpluggedChoiceStillGetsTheProtection() {
        XCTAssertEqual(plan(preferred: "gone", route: both), .protectPlayback(uid: "builtin"))
    }

    /// A Mac with no built-in microphone — a Mac mini, or a laptop with the mic
    /// disabled — still has the USB mic plugged into it, and that protects
    /// playback just as well.
    func testAMacWithNoBuiltInMicFallsBackToTheWiredOne() {
        XCTAssertEqual(plan(route: both, connected: [airpods, usb]), .protectPlayback(uid: "scarlett"))
    }

    /// Nothing off the radio at all: follow the default and let playback take the
    /// hit, because there is no microphone left to move to.
    func testAirPodsAloneLeaveNothingToSwitchTo() {
        XCTAssertEqual(plan(route: both, connected: [airpods]), .systemDefault)
    }

    /// A loopback device records whatever is routed into it — which is often
    /// silence. Never pick one automatically; a quiet take is worse than a loud
    /// one.
    func testALoopbackDeviceIsNotAFallback() {
        XCTAssertEqual(plan(route: both, connected: [airpods, loopback]), .systemDefault)
        // With a real mic present it is simply skipped over.
        XCTAssertEqual(plan(route: both, connected: [airpods, loopback, usb]), .protectPlayback(uid: "scarlett"))
    }

    /// The built-in array is the better microphone of the two, and it is always
    /// there — so it wins even when a USB mic is plugged in.
    func testTheBuiltInArrayIsPreferredOverWired() {
        XCTAssertEqual(AudioInputSelection.playbackSafeInput(in: [usb, builtIn])?.uid, "builtin")
        XCTAssertNil(AudioInputSelection.playbackSafeInput(in: [airpods, loopback]))
    }
}

/// The pairings that decide whether opening a mic costs playback.
final class BluetoothPairingTests: XCTestCase {
    func testOneDeviceForBothEndsCounts() {
        XCTAssertTrue(AudioInputRoute.bluetoothInputIsAlsoOutput(
            inputID: 7, outputID: 7, inputUID: "airpods", outputUID: "airpods",
            inputName: "AirPods Pro", outputName: "AirPods Pro", outputTransport: .bluetooth
        ))
    }

    /// AirPods expose the two halves under separate ids and UIDs.
    func testTheTwoHalvesOfOneHeadsetCount() {
        XCTAssertTrue(AudioInputRoute.bluetoothInputIsAlsoOutput(
            inputID: 7, outputID: 8,
            inputUID: "00:11:22:33:44:55:input", outputUID: "00:11:22:33:44:55:output",
            inputName: "AirPods Pro", outputName: "AirPods Pro",
            outputTransport: .bluetooth
        ))
    }

    /// A headset whose halves share neither id nor UID stem is still one headset
    /// if it is named once. This is the net under the UID check.
    func testHalvesThatOnlyShareANameCount() {
        XCTAssertTrue(AudioInputRoute.bluetoothInputIsAlsoOutput(
            inputID: 7, outputID: 8, inputUID: "hfp-uid", outputUID: "a2dp-uid",
            inputName: "Jabra Elite (Hands-Free)", outputName: "Jabra Elite (Stereo)",
            outputTransport: .bluetooth
        ))
    }

    /// Two different Bluetooth devices — a headset mic while other headphones
    /// play. Opening this mic pulls *this* radio into HFP; the headphones on the
    /// other radio keep their A2DP and their volume, so there is nothing to
    /// protect and the speaker keeps the mic they chose.
    func testADifferentBluetoothDevicePlayingIsNoClash() {
        XCTAssertFalse(AudioInputRoute.bluetoothInputIsAlsoOutput(
            inputID: 7, outputID: 9,
            inputUID: "00:11:22:33:44:55:input", outputUID: "AA:BB:CC:DD:EE:FF:output",
            inputName: "Shure MV7 Bluetooth", outputName: "AirPods Max",
            outputTransport: .bluetooth
        ))
    }

    /// Bluetooth mic, playback through the Mac's own speakers: nothing to protect.
    func testBluetoothMicWithBuiltInOutputIsNoClash() {
        XCTAssertFalse(AudioInputRoute.bluetoothInputIsAlsoOutput(
            inputID: 7, outputID: 1,
            inputUID: "00:11:22:33:44:55:input", outputUID: "BuiltInSpeakerDevice",
            inputName: "AirPods Pro", outputName: "MacBook Air Speakers",
            outputTransport: .builtIn
        ))
    }

    /// Names are the last resort, so an unreadable one must not be read as a
    /// match — two unnamed Bluetooth devices are two devices.
    func testMissingNamesDoNotPairDevices() {
        XCTAssertFalse(AudioInputRoute.bluetoothInputIsAlsoOutput(
            inputID: 7, outputID: 9, inputUID: "hfp-uid", outputUID: "a2dp-uid",
            inputName: nil, outputName: nil, outputTransport: .bluetooth
        ))
    }

    /// Addresses that differ only in the last pair must not be read as one device.
    func testSimilarBluetoothAddressesAreNotTheSameDevice() {
        XCTAssertFalse(AudioInputRoute.devicesShareHardware(
            inputUID: "00:11:22:33:44:55", outputUID: "00:11:22:33:44:66"
        ))
    }
}
