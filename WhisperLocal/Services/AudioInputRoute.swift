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
        case .builtIn, .wired, .virtual, .other, .unknown:
            return "\(transport.label) input"
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
            inputName: deviceName(of: inputID),
            outputName: deviceName(of: outputID),
            outputTransport: AudioInputTransport.classify(transportType(of: outputID))
        )
        return AudioInputRoute(transport: .bluetooth, bluetoothInputIsAlsoOutput: alsoOutput)
    }

    /// Whether the microphone about to open belongs to the headset that is playing.
    ///
    /// Only then does opening it cost anything: one radio cannot carry A2DP and a
    /// mic at once, so it drops to HFP and playback goes narrowband. A *different*
    /// Bluetooth device playing is not affected by this one's mic, so recording
    /// from a headset mic while other headphones play is left alone.
    ///
    /// The same headset can show up as two devices — AirPods expose HFP and A2DP
    /// halves — so identity is checked three ways: one device, one UID stem, or one
    /// name.
    static func bluetoothInputIsAlsoOutput(
        inputID: AudioDeviceID,
        outputID: AudioDeviceID,
        inputUID: String?,
        outputUID: String?,
        inputName: String?,
        outputName: String?,
        outputTransport: AudioInputTransport
    ) -> Bool {
        guard outputTransport == .bluetooth else { return false }
        if inputID == outputID { return true }
        if devicesShareHardware(inputUID: inputUID, outputUID: outputUID) { return true }
        return devicesShareName(inputName: inputName, outputName: outputName)
    }

    /// Both halves of a headset are named after the headset. Some adapters append
    /// the role — "Jabra Elite (Hands-Free)" against "Jabra Elite" — so the role
    /// comes off before comparing.
    static func devicesShareName(inputName: String?, outputName: String?) -> Bool {
        guard let input = nameStem(inputName), let output = nameStem(outputName) else { return false }
        return input == output
    }

    /// Words macOS and Bluetooth adapters tack on to say which end of a headset
    /// a device is. They never distinguish one headset from another.
    private static let roleWords: Set<String> = [
        "microphone", "mic", "input", "output", "speaker", "speakers",
        "headphones", "headset", "hands-free", "handsfree", "stereo"
    ]

    static func nameStem(_ name: String?) -> String? {
        guard let name else { return nil }
        var stem = name.lowercased()
        if stem.hasSuffix(")"), let open = stem.lastIndex(of: "(") {
            stem = String(stem[stem.startIndex..<open])
        }
        var words = stem.split(separator: " ", omittingEmptySubsequences: true)
        while let last = words.last, roleWords.contains(String(last)) {
            words.removeLast()
        }
        let trimmed = words.joined(separator: " ")
        return trimmed.isEmpty ? nil : trimmed
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
    case builtIn
    case wired
    case bluetooth
    /// Aggregate, loopback and other software devices — BlackHole, Loopback,
    /// Soundflower, a multi-output aggregate.
    case virtual
    /// A real transport this app does not model: AirPlay, Continuity Capture,
    /// network audio.
    case other
    case unknown

    var label: String {
        switch self {
        case .builtIn: return "built-in"
        case .wired: return "wired"
        case .bluetooth: return "bluetooth"
        case .virtual: return "virtual"
        case .other: return "other"
        case .unknown: return "unknown"
        }
    }

    /// Whether a take can be moved to this microphone to spare Bluetooth playback.
    ///
    /// It has to be off the radio *and* certain to carry sound: a loopback or
    /// aggregate device opens happily and records silence, which is a worse
    /// outcome than the volume jump this rule exists to prevent. Continuity
    /// Capture is ruled out for a different reason — it would reach for the
    /// speaker's phone unasked.
    var canProtectPlayback: Bool {
        switch self {
        case .builtIn, .wired: return true
        case .bluetooth, .virtual, .other, .unknown: return false
        }
    }

    static func classify(_ raw: UInt32?) -> AudioInputTransport {
        guard let raw else { return .unknown }
        switch raw {
        case kAudioDeviceTransportTypeBuiltIn:
            return .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return .bluetooth
        case kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeFireWire,
             kAudioDeviceTransportTypeThunderbolt, kAudioDeviceTransportTypePCI,
             kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            return .wired
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate,
             kAudioDeviceTransportTypeAutoAggregate:
            return .virtual
        default:
            return .other
        }
    }
}

/// Picking an input device rather than accepting the system default.
/// One microphone a take can be recorded from.
struct AudioInputDevice: Identifiable, Equatable, Sendable {
    let id: AudioDeviceID
    /// Stable across reboots and reconnects, unlike the numeric id — so this is
    /// what the preference stores.
    let uid: String
    let name: String
    let transport: AudioInputTransport
    /// True for whichever device System Settings currently points input at.
    var isSystemDefault: Bool

    var isBuiltIn: Bool { transport == .builtIn }

    /// Where it sits in the list: the microphones people dictate into first, the
    /// built-in array ahead of them all because it is always there. Loopback and
    /// aggregate devices sit at the bottom — they show up in the list because they
    /// can record, not because anyone speaks into them.
    var order: Int {
        switch transport {
        case .builtIn: return 0
        case .wired: return 1
        case .bluetooth: return 2
        case .other: return 3
        case .virtual: return 4
        case .unknown: return 5
        }
    }
}

enum AudioInputSelection {
    /// The microphone to move a take to when opening the default one would
    /// interrupt playback: the built-in array first, then any wired mic.
    ///
    /// Opening the mic on a Bluetooth headset that is also playing audio forces the
    /// radio from A2DP to HFP: music collapses to narrowband mono for the duration,
    /// with an audible break at each transition. The HFP mic is also a worse ASR
    /// input than a wired or built-in one — roughly 8-16 kHz against full band — so
    /// switching helps the transcript and the music at once.
    ///
    /// A Mac mini has no built-in array, but the USB mic plugged into it protects
    /// playback just as well; before this fell back to wired, such a Mac had no
    /// protection at all.
    static func playbackSafeInput(in devices: [AudioInputDevice]) -> AudioInputDevice? {
        sortedForMenu(devices.filter { $0.transport.canProtectPlayback }).first
    }

    /// True when using the current default input would interrupt playback.
    static func defaultInputWouldDisruptPlayback(_ route: AudioInputRoute) -> Bool {
        route.transport == .bluetooth && route.bluetoothInputIsAlsoOutput
    }

    /// Every device that can record, in the order the menu shows them.
    static func inputDevices() -> [AudioInputDevice] {
        let defaultID = defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
        let devices = allDevices().filter { hasInputStreams($0) }.compactMap { device -> AudioInputDevice? in
            guard let uid = uid(of: device) else { return nil }
            return AudioInputDevice(
                id: device,
                uid: uid,
                name: deviceName(of: device) ?? uid,
                transport: AudioInputTransport.classify(transportType(of: device)),
                isSystemDefault: device == defaultID
            )
        }
        return sortedForMenu(devices)
    }

    /// Built-in, then wired, then unknown, then Bluetooth; alphabetical within each.
    /// Split out from `inputDevices()` so the ordering can be tested without hardware.
    static func sortedForMenu(_ devices: [AudioInputDevice]) -> [AudioInputDevice] {
        devices.sorted {
            $0.order != $1.order
                ? $0.order < $1.order
                : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// The device a stored preference refers to, or nil when it is unplugged or
    /// was never set — in which case the caller follows the system default, which
    /// is what the app did before any of this existed.
    static func resolve(preferredUID: String?, in devices: [AudioInputDevice]) -> AudioInputDevice? {
        guard let preferredUID, !preferredUID.isEmpty else { return nil }
        return devices.first { $0.uid == preferredUID }
    }

    /// What the HUD chip says: the chosen device, or the system default it is
    /// following, or nothing at all when Core Audio has no answer yet.
    static func activeName(preferredUID: String?, in devices: [AudioInputDevice]) -> String? {
        if let chosen = resolve(preferredUID: preferredUID, in: devices) { return chosen.name }
        return devices.first { $0.isSystemDefault }?.name
    }

    /// Which microphone a take should open.
    ///
    /// Pulled out of the recorder so every input/output pairing can be checked
    /// without the hardware to pair: the answer depends on what the speaker chose,
    /// what System Settings points at, and whether opening that microphone would
    /// drag playback down with it.
    enum InputChoice: Equatable {
        /// Whatever System Settings points input at.
        case systemDefault
        /// The device the speaker picked, by UID.
        case chosen(String)
        /// A microphone off the Bluetooth radio, because the default input is a
        /// headset that is also playing and opening its mic would collapse playback.
        case protectPlayback(uid: String)
    }

    static func plan(
        preferredUID: String?,
        connected: [AudioInputDevice],
        route: AudioInputRoute
    ) -> InputChoice {
        // An explicit choice wins outright, including over the Bluetooth rule:
        // someone who picks the headset mic means it, even at the cost of playback.
        // That choice is the whole escape hatch — there is no separate switch for
        // the rule, because picking the mic you want says the same thing and says
        // which one.
        if let chosen = resolve(preferredUID: preferredUID, in: connected) {
            return .chosen(chosen.uid)
        }
        // A choice that is no longer connected falls back to the system default,
        // and the Bluetooth rule applies again from there.
        guard defaultInputWouldDisruptPlayback(route) else { return .systemDefault }
        // Nothing off the radio to move to — a Mac mini wearing AirPods, say.
        // Follow the default and let playback take the hit; the alternative is a
        // take that records nothing.
        guard let safe = playbackSafeInput(in: connected) else { return .systemDefault }
        return .protectPlayback(uid: safe.uid)
    }

    /// Name and transport of one device, for the log. "Which microphone did that
    /// take actually use" is otherwise guesswork, and on a Bluetooth headset the
    /// answer decides whether playback switches profile mid-take.
    static func label(of device: AudioDeviceID) -> String {
        let transport = AudioInputTransport.classify(transportType(of: device))
        return "\(deviceName(of: device) ?? "unknown") [\(transport.label)]"
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

/// One row of the microphone list, wherever it is shown: the HUD chip's menu,
/// the menu bar, or Settings. Built once so the three cannot drift apart.
struct InputMenuItem: Identifiable, Equatable, Sendable {
    /// Empty string for "follow System Settings", which has no device of its own.
    var id: String { uid ?? "" }
    let title: String
    let uid: String?
    let isChecked: Bool
    let isEnabled: Bool
}

enum InputMenu {
    static let followTitle = "Follow System Settings"
    static let missingTitle = "Chosen microphone is not connected"

    static func items(devices: [AudioInputDevice], chosenUID: String?) -> [InputMenuItem] {
        let chosen = (chosenUID?.isEmpty == false) ? chosenUID : nil
        var items = [InputMenuItem(title: followTitle, uid: nil, isChecked: chosen == nil, isEnabled: true)]
        for device in devices {
            // Naming the system default matters most when nothing is chosen: it is
            // the device the take will actually use.
            let title = device.isSystemDefault ? "\(device.name)  ·  system default" : device.name
            items.append(InputMenuItem(
                title: title,
                uid: device.uid,
                isChecked: device.uid == chosen,
                isEnabled: true
            ))
        }
        // A device chosen while it was plugged in, gone since: say so rather than
        // silently showing nothing ticked.
        if let chosen, !devices.contains(where: { $0.uid == chosen }) {
            items.append(InputMenuItem(title: missingTitle, uid: nil, isChecked: false, isEnabled: false))
        }
        return items
    }
}

/// What playback is doing while the mic opens.
///
/// Opening an input can move the *output* underneath you: a Bluetooth headset
/// switches profile, and each profile carries its own volume, so music can jump
/// up or down at the moment a take starts without anything in this app touching
/// it. This snapshot is taken either side of the engine starting, so the log says
/// which of those happened rather than leaving it to guesswork.
struct AudioOutputSnapshot: Equatable {
    var name: String
    var transport: AudioInputTransport
    var volume: Float?
    var sampleRate: Double?

    var summary: String {
        let level = volume.map { String(format: "%.2f", $0) } ?? "n/a"
        let rate = sampleRate.map { String(format: "%.0f", $0) } ?? "n/a"
        return "\(name) [\(transport.label)] volume \(level) rate \(rate)"
    }

    static func current() -> AudioOutputSnapshot {
        guard let device = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) else {
            return AudioOutputSnapshot(name: "none", transport: .unknown, volume: nil, sampleRate: nil)
        }
        return AudioOutputSnapshot(
            name: deviceName(of: device) ?? "unknown",
            transport: AudioInputTransport.classify(transportType(of: device)),
            volume: outputVolume(of: device),
            sampleRate: deviceSampleRate(of: device)
        )
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
        case .builtIn, .wired, .virtual, .other, .unknown:
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

private func deviceName(of deviceID: AudioDeviceID) -> String? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var cfName: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &cfName)
    guard status == noErr, let cfName else { return nil }
    let name = cfName.takeRetainedValue() as String
    return name.isEmpty ? nil : name
}

/// Main output volume, 0–1. Some devices answer on the main element, some only on
/// their channels, and some (HDMI, many USB interfaces) not at all.
private func outputVolume(of deviceID: AudioDeviceID) -> Float? {
    for element: AudioObjectPropertyElement in [kAudioObjectPropertyElementMain, 1, 2] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
        guard AudioObjectHasProperty(deviceID, &address) else { continue }
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        if AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume) == noErr {
            return volume
        }
    }
    return nil
}

private func deviceSampleRate(of deviceID: AudioDeviceID) -> Double? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var rate: Float64 = 0
    var size = UInt32(MemoryLayout<Float64>.size)
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate) == noErr else { return nil }
    return rate
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
