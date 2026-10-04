import AVFoundation
import CoreAudio
import Foundation
import os

/// The microphone, opened directly instead of through `AVAudioEngine`.
///
/// AVAudioEngine picks the device for you. Touching `inputNode` binds the unit to
/// the system default input and opens it, and only afterwards will it accept a
/// different device. On a Bluetooth headset that is not a private detail: opening
/// the AirPods microphone pulls them out of A2DP into the call profile, which
/// restarts whatever is playing on a narrowband link and swaps in that profile's
/// own volume. Traced on this app, the device change we wanted landed 230 ms
/// after the headset had already been opened — so every take dipped the music for
/// about a second even though the take itself ran on the built-in microphone.
///
/// An AUHAL of our own takes the device before `AudioUnitInitialize`, which is
/// the only moment at which that can be said. The headset is never opened.
///
/// Not used for echo cancellation: the voice-processing unit refuses any device
/// chosen this way, which is why AVAudioEngine builds an aggregate for it. That
/// path stays on the engine — see `AudioRecorder.startVoiceProcessingEngine`.
final class AudioInputUnit {
    /// Carries the Core Audio status through as the error code, so the recorder's
    /// existing advice for -10867 and friends still reaches the speaker.
    enum Failure: Error, CustomNSError {
        case componentUnavailable
        case deviceUnavailable(OSStatus)
        case formatUnavailable
        case configurationFailed(String, OSStatus)
        case initializationFailed(OSStatus)
        case startFailed(OSStatus)

        static var errorDomain: String { NSOSStatusErrorDomain }

        var errorUserInfo: [String: Any] {
            guard case .configurationFailed(let step, let status) = self else { return [:] }
            return [NSLocalizedDescriptionKey: "\(step) failed (\(status))"]
        }

        var errorCode: Int {
            switch self {
            case .componentUnavailable, .formatUnavailable: return Int(kAudio_ParamError)
            case .deviceUnavailable(let status), .initializationFailed(let status),
                 .startFailed(let status):
                return Int(status)
            case .configurationFailed(_, let status):
                return Int(status)
            }
        }
    }

    let deviceID: AudioDeviceID
    /// What `onBuffer` delivers: Float32, deinterleaved, at the device's own rate
    /// and channel count. The downmix to 16 kHz mono stays where it always was.
    let format: AVAudioFormat

    /// Called on the render thread, once per block of input.
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    /// Called on the main queue when the device this unit opened, or the system
    /// default it was following, has actually moved. Quiet for notifications that
    /// change nothing, so opening a device cannot set off a rebuild loop.
    var onConfigurationChange: (() -> Void)?

    private(set) var isRunning = false

    private let unit: AudioUnit
    private let renderBuffer: AVAudioPCMBuffer
    private var listeners: [(object: AudioObjectID, address: AudioObjectPropertyAddress)] = []
    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private let logger = Logger(subsystem: "com.usingcolor.WhisperLocal", category: "audio")

    /// Big enough that the HAL never asks for more, small enough to allocate once.
    private static let maximumFramesPerSlice: UInt32 = 4096

    init(deviceID: AudioDeviceID) throws {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw Failure.componentUnavailable
        }
        var instance: AudioUnit?
        let created = AudioComponentInstanceNew(component, &instance)
        guard created == noErr, let unit = instance else {
            throw Failure.configurationFailed("instantiate", created)
        }

        // Everything that does not need `self`, so a failure here disposes the unit
        // rather than leaving a half-built object behind.
        let client: AVAudioFormat
        let buffer: AVAudioPCMBuffer
        do {
            try Self.enableInputOnly(unit)
            // The line this whole class exists for: the device is chosen while the
            // unit is still uninitialised, so no other device is ever opened.
            try Self.setDevice(deviceID, on: unit)
            let hardware = try Self.hardwareFormat(of: unit)
            guard let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: hardware.mSampleRate,
                channels: AVAudioChannelCount(max(hardware.mChannelsPerFrame, 1)),
                interleaved: false
            ) else { throw Failure.formatUnavailable }
            client = format
            try Self.setClientFormat(client, on: unit)
            try Self.setMaximumFrames(Self.maximumFramesPerSlice, on: unit)
            guard let allocated = AVAudioPCMBuffer(
                pcmFormat: client,
                frameCapacity: AVAudioFrameCount(Self.maximumFramesPerSlice)
            ) else { throw Failure.formatUnavailable }
            buffer = allocated
        } catch {
            AudioComponentInstanceDispose(unit)
            throw error
        }

        self.unit = unit
        self.deviceID = deviceID
        self.format = client
        self.renderBuffer = buffer

        do {
            try Self.setInputCallback(on: unit, refCon: Unmanaged.passUnretained(self).toOpaque())
            let initialized = AudioUnitInitialize(unit)
            guard initialized == noErr else { throw Failure.initializationFailed(initialized) }
        } catch {
            AudioComponentInstanceDispose(unit)
            throw error
        }
    }

    deinit {
        removeListeners()
        if isRunning { AudioOutputUnitStop(unit) }
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
    }

    func start() throws {
        guard !isRunning else { return }
        let status = AudioOutputUnitStart(unit)
        guard status == noErr else { throw Failure.startFailed(status) }
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        AudioOutputUnitStop(unit)
        isRunning = false
    }

    /// Release the hardware now rather than whenever the last reference goes.
    ///
    /// Stop first. `AudioOutputUnitStop` waits for the render thread, so after it
    /// returns nothing can be inside `render()` any more; dropping the callbacks
    /// before it would release a closure the HAL could still be calling.
    func dispose() {
        stop()
        removeListeners()
        onBuffer = nil
        onConfigurationChange = nil
    }

    // MARK: - Watching for the ground moving

    /// AVAudioEngine posted one notification for all of this. Owning the unit means
    /// owning the listeners too: the device can change its format, go away, or —
    /// when no particular microphone was asked for — be replaced by a new system
    /// default.
    func watchForChanges(followingSystemDefault: Bool) {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            DispatchQueue.main.async { self.reportIfSomethingActuallyChanged() }
        }
        listenerBlock = block

        if followingSystemDefault {
            addListener(
                block,
                on: AudioObjectID(kAudioObjectSystemObject),
                selector: kAudioHardwarePropertyDefaultInputDevice,
                scope: kAudioObjectPropertyScopeGlobal
            )
        }
        addListener(block, on: deviceID, selector: kAudioDevicePropertyStreamFormat, scope: kAudioDevicePropertyScopeInput)
        addListener(block, on: deviceID, selector: kAudioDevicePropertyNominalSampleRate, scope: kAudioObjectPropertyScopeGlobal)
        addListener(block, on: deviceID, selector: kAudioDevicePropertyDeviceIsAlive, scope: kAudioObjectPropertyScopeGlobal)
        self.followsSystemDefault = followingSystemDefault
    }

    private var followsSystemDefault = false

    /// Opening a device can itself change its nominal rate, which notifies us
    /// straight back. Rebuilding on that would loop, so the graph is only torn
    /// down when the format or the device is genuinely not what we opened.
    private func reportIfSomethingActuallyChanged() {
        var changed = false
        if let hardware = try? Self.hardwareFormat(of: unit) {
            let sameRate = abs(hardware.mSampleRate - format.sampleRate) < 1
            let sameChannels = hardware.mChannelsPerFrame == format.channelCount
            if !sameRate || !sameChannels { changed = true }
        } else {
            changed = true
        }
        if followsSystemDefault, Self.defaultInputDevice() != deviceID { changed = true }
        guard changed else { return }
        onConfigurationChange?()
    }

    private func addListener(
        _ block: @escaping AudioObjectPropertyListenerBlock,
        on object: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectAddPropertyListenerBlock(object, &address, DispatchQueue.main, block)
        guard status == noErr else { return }
        listeners.append((object, address))
    }

    private func removeListeners() {
        guard let block = listenerBlock else { return }
        for listener in listeners {
            var address = listener.address
            AudioObjectRemovePropertyListenerBlock(listener.object, &address, DispatchQueue.main, block)
        }
        listeners.removeAll()
        listenerBlock = nil
    }

    // MARK: - Render

    fileprivate func render(
        actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timestamp: UnsafePointer<AudioTimeStamp>,
        bus: UInt32,
        frames: UInt32
    ) -> OSStatus {
        guard frames > 0, frames <= renderBuffer.frameCapacity else { return noErr }
        // One pointer, used for both the sizing and the render. Reading
        // `mutableAudioBufferList` again would hand back a list re-derived from
        // `frameLength`, undoing the sizes and rendering into a list that claims
        // to hold no bytes — which the unit rejects with paramErr.
        renderBuffer.frameLength = frames
        let bufferList = renderBuffer.mutableAudioBufferList
        let list = UnsafeMutableAudioBufferListPointer(bufferList)
        let bytesPerFrame = format.streamDescription.pointee.mBytesPerFrame
        for index in 0..<list.count {
            list[index].mDataByteSize = frames * bytesPerFrame
        }
        let status = AudioUnitRender(unit, actionFlags, timestamp, bus, frames, bufferList)
        guard status == noErr else {
            if !didLogRenderFailure {
                didLogRenderFailure = true
                logger.error("Input render failed (\(status, privacy: .public))")
            }
            return status
        }
        onBuffer?(renderBuffer)
        return noErr
    }

    /// Said once, not per block: a graph that renders nothing is a failure this app
    /// has been bitten by before, and it must not be silent.
    nonisolated(unsafe) private var didLogRenderFailure = false

    // MARK: - Unit configuration

    private static func enableInputOnly(_ unit: AudioUnit) throws {
        var enable: UInt32 = 1
        var status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1,
            &enable, UInt32(MemoryLayout<UInt32>.size)
        )
        guard status == noErr else { throw Failure.configurationFailed("enable input", status) }

        var disable: UInt32 = 0
        status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0,
            &disable, UInt32(MemoryLayout<UInt32>.size)
        )
        guard status == noErr else { throw Failure.configurationFailed("disable output", status) }
    }

    private static func setDevice(_ device: AudioDeviceID, on unit: AudioUnit) throws {
        var id = device
        let status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &id, UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else { throw Failure.deviceUnavailable(status) }
    }

    /// The device's own format, read off the input scope of the input bus.
    private static func hardwareFormat(of unit: AudioUnit) throws -> AudioStreamBasicDescription {
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioUnitGetProperty(
            unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &asbd, &size
        )
        guard status == noErr, asbd.mSampleRate > 0 else { throw Failure.formatUnavailable }
        return asbd
    }

    /// What we want handed back, set on the output scope of the same bus. Same rate
    /// and channel count as the hardware: the AUHAL's own converter is asked for
    /// nothing but the float layout, and the resampling stays in code that is
    /// tested.
    private static func setClientFormat(_ format: AVAudioFormat, on unit: AudioUnit) throws {
        var asbd = format.streamDescription.pointee
        let status = AudioUnitSetProperty(
            unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
            &asbd, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        guard status == noErr else { throw Failure.configurationFailed("client format", status) }
    }

    private static func setMaximumFrames(_ frames: UInt32, on unit: AudioUnit) throws {
        var value = frames
        let status = AudioUnitSetProperty(
            unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
            &value, UInt32(MemoryLayout<UInt32>.size)
        )
        guard status == noErr else { throw Failure.configurationFailed("max frames", status) }
    }

    private static func setInputCallback(on unit: AudioUnit, refCon: UnsafeMutableRawPointer) throws {
        var callback = AURenderCallbackStruct(
            inputProc: audioInputUnitRenderCallback,
            inputProcRefCon: refCon
        )
        let status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
            &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
        guard status == noErr else { throw Failure.configurationFailed("input callback", status) }
    }

    static func defaultInputDevice() -> AudioDeviceID? {
        var deviceID = AudioDeviceID()
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }
}

/// The HAL calls a C function, so the instance arrives as a pointer.
private func audioInputUnitRenderCallback(
    _ refCon: UnsafeMutableRawPointer,
    _ actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    _ timestamp: UnsafePointer<AudioTimeStamp>,
    _ bus: UInt32,
    _ frames: UInt32,
    _ data: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    Unmanaged<AudioInputUnit>.fromOpaque(refCon)
        .takeUnretainedValue()
        .render(actionFlags: actionFlags, timestamp: timestamp, bus: bus, frames: frames)
}
