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
        let wired = AudioInputRoute(transport: .other, bluetoothInputIsAlsoOutput: false)
        let unknown = AudioInputRoute(transport: .unknown, bluetoothInputIsAlsoOutput: false)
        XCTAssertEqual(AudioIdleHold.nanoseconds(for: wired), 2_000_000_000)
        XCTAssertEqual(AudioIdleHold.nanoseconds(for: unknown), 2_000_000_000)
        XCTAssertEqual(wired.logReason, "wired or built-in")
        XCTAssertEqual(unknown.logReason, "unknown input")
    }

    func testAlsoPlayingDoesNotAffectWiredHold() {
        let route = AudioInputRoute(transport: .other, bluetoothInputIsAlsoOutput: true)
        XCTAssertEqual(AudioIdleHold.nanoseconds(for: route), 2_000_000_000)
    }
}

final class AudioInputTransportTests: XCTestCase {
    func testClassifiesBluetoothAndBluetoothLE() {
        XCTAssertEqual(AudioInputTransport.classify(kAudioDeviceTransportTypeBluetooth), .bluetooth)
        XCTAssertEqual(AudioInputTransport.classify(kAudioDeviceTransportTypeBluetoothLE), .bluetooth)
    }

    func testClassifiesBuiltInAndUSBAsOther() {
        XCTAssertEqual(AudioInputTransport.classify(kAudioDeviceTransportTypeBuiltIn), .other)
        XCTAssertEqual(AudioInputTransport.classify(kAudioDeviceTransportTypeUSB), .other)
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

    func testSeparateHFPAndA2DPDevicesCountAsAlsoPlaying() {
        XCTAssertTrue(AudioInputRoute.bluetoothInputIsAlsoOutput(
            inputID: 12,
            outputID: 34,
            inputUID: "hfp-uid",
            outputUID: "a2dp-uid",
            outputTransport: .bluetooth
        ))
    }

    func testBluetoothMicWithBuiltInSpeakersIsNotAlsoPlaying() {
        XCTAssertFalse(AudioInputRoute.bluetoothInputIsAlsoOutput(
            inputID: 12,
            outputID: 1,
            inputUID: "hfp-uid",
            outputUID: "BuiltInSpeakerDevice",
            outputTransport: .other
        ))
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
