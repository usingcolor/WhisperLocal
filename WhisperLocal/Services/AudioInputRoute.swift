import CoreAudio
import Foundation

/// Default input transport, plus whether that Bluetooth device is also playing audio.
struct AudioInputRoute: Equatable {
    var transport: AudioInputTransport
    var bluetoothInputIsAlsoOutput: Bool

    var logReason: String {
        switch transport {
        case .bluetooth where bluetoothInputIsAlsoOutput:
            return "bluetooth also playing"
        case .bluetooth:
            return "bluetooth input"
        case .other:
            return "wired or built-in"
        case .unknown:
            return "unknown input"
        }
    }

    /// Snapshot of the current default input / output pair. Fails open to `.unknown`.
    static func current() -> AudioInputRoute {
        guard let inputID = defaultDevice(kAudioHardwarePropertyDefaultInputDevice) else {
            return AudioInputRoute(transport: .unknown, bluetoothInputIsAlsoOutput: false)
        }
        let transport = AudioInputTransport.classify(transportType(of: inputID))
        guard transport == .bluetooth,
              let outputID = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) else {
            return AudioInputRoute(transport: transport, bluetoothInputIsAlsoOutput: false)
        }
        let alsoOutput = bluetoothInputIsAlsoOutput(
            inputID: inputID,
            outputID: outputID,
            inputUID: uid(of: inputID),
            outputUID: uid(of: outputID),
            outputTransport: AudioInputTransport.classify(transportType(of: outputID))
        )
        return AudioInputRoute(transport: .bluetooth, bluetoothInputIsAlsoOutput: alsoOutput)
    }

    /// AirPods often expose separate HFP (input) and A2DP (output) devices.
    /// If the default output is also Bluetooth, holding the input graph pins HFP
    /// and collapses playback to narrowband — treat that as "also playing."
    static func bluetoothInputIsAlsoOutput(
        inputID: AudioDeviceID,
        outputID: AudioDeviceID,
        inputUID: String?,
        outputUID: String?,
        outputTransport: AudioInputTransport
    ) -> Bool {
        if inputID == outputID { return true }
        if devicesShareHardware(inputUID: inputUID, outputUID: outputUID) { return true }
        return outputTransport == .bluetooth
    }

    /// AirPods often expose `…:input` and `…:output` UIDs on the same radio.
    static func devicesShareHardware(inputUID: String?, outputUID: String?) -> Bool {
        guard let inputUID, let outputUID, !inputUID.isEmpty, !outputUID.isEmpty else { return false }
        if inputUID == outputUID { return true }
        return hardwareStem(inputUID) == hardwareStem(outputUID)
    }

    /// Strip a known I/O role suffix only. A generic "last colon" cut collides
    /// colon-separated Bluetooth addresses (`00:11:…:55` vs `00:11:…:66`).
    static func hardwareStem(_ uid: String) -> String {
        let lower = uid.lowercased()
        for suffix in [":input", ":output", ":in", ":out"] {
            if lower.hasSuffix(suffix) {
                return String(lower.dropLast(suffix.count))
            }
        }
        return lower
    }
}

enum AudioInputTransport: Equatable {
    case bluetooth
    case other
    case unknown

    static func classify(_ raw: UInt32?) -> AudioInputTransport {
        guard let raw else { return .unknown }
        switch raw {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return .bluetooth
        default:
            return .other
        }
    }
}

/// Picking an input device rather than accepting the system default.
enum AudioInputSelection {
    /// The built-in microphone, if this Mac has one with input channels.
    ///
    /// Opening the mic on a Bluetooth headset that is also playing audio forces the
    /// radio from A2DP to HFP: music collapses to narrowband mono for the duration,
    /// with an audible break at each transition. The HFP mic is also a worse ASR
    /// input than the built-in array — roughly 8-16 kHz against full band — so
    /// preferring built-in helps the transcript and the music at once.
    static func builtInInputDevice() -> AudioDeviceID? {
        for device in allDevices() where hasInputStreams(device) {
            if transportType(of: device) == kAudioDeviceTransportTypeBuiltIn {
                return device
            }
        }
        return nil
    }

    /// True when using the current default input would interrupt playback.
    static func defaultInputWouldDisruptPlayback(_ route: AudioInputRoute) -> Bool {
        route.transport == .bluetooth && route.bluetoothInputIsAlsoOutput
    }

    private static func allDevices() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr, size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices
        ) == noErr else { return [] }
        return devices
    }

    private static func hasInputStreams(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else {
            return false
        }
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, buffer) == noErr else {
            return false
        }
        let list = UnsafeMutableAudioBufferListPointer(
            buffer.assumingMemoryBound(to: AudioBufferList.self)
        )
        return list.contains { $0.mNumberChannels > 0 }
    }
}

/// How long to keep the input graph open after a take or prewarm.
enum AudioIdleHold {
    /// Covers the Bluetooth HFP reconnect so the next take does not drop the first words.
    static let bluetoothNanoseconds: UInt64 = 45_000_000_000
    /// Built-in / wired, or AirPods that are also the output (holding them in HFP wrecks music).
    static let shortNanoseconds: UInt64 = 2_000_000_000

    static func nanoseconds(for route: AudioInputRoute) -> UInt64 {
        switch route.transport {
        case .bluetooth where route.bluetoothInputIsAlsoOutput:
            return shortNanoseconds
        case .bluetooth:
            return bluetoothNanoseconds
        case .other, .unknown:
            return shortNanoseconds
        }
    }
}

/// Gated Bluetooth streams deliver exact zeros; a live mic always has a noise floor.
enum AudioTapLiveness {
    static func bufferIsLive(_ samples: UnsafeBufferPointer<Float>) -> Bool {
        for s in samples where s != 0 { return true }
        return false
    }

    static func bufferIsLive(_ samples: [Float]) -> Bool {
        samples.withUnsafeBufferPointer { bufferIsLive($0) }
    }
}

// MARK: - Core Audio

private func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
    var deviceID = AudioDeviceID()
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        0,
        nil,
        &size,
        &deviceID
    )
    guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
    return deviceID
}

private func transportType(of deviceID: AudioDeviceID) -> UInt32? {
    var transport: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyTransportType,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transport)
    guard status == noErr else { return nil }
    return transport
}

private func uid(of deviceID: AudioDeviceID) -> String? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceUID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var cfUID: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &cfUID)
    guard status == noErr, let cfUID else { return nil }
    // kAudioDevicePropertyDeviceUID returns a +1 CFString.
    return cfUID.takeRetainedValue() as String
}
