import AVFoundation
import AppKit
import Foundation
import os

@MainActor
final class AudioRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    /// Hardware is actually passing audio — not just the first (often silent) Bluetooth buffer.
    @Published private(set) var isInputReady = false
    /// The input graph died mid-take and could not be restarted. Capture is over;
    /// whatever was recorded up to that point is still in the buffer. Watched by the
    /// controller so the take ends there instead of silently recording nothing.
    @Published private(set) var inputFailed = false

    private var engine: AVAudioEngine?
    private var tapInstalled = false
    private var outputFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var configObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var idleStopTask: Task<Void, Never>?
    private var engineStartedAt: Date?
    /// Snapshot for idle-hold length. Refreshed when the engine starts or the
    /// graph reconfigures — not on every take, so `stop()` stays off coreaudiod.
    private var cachedInputRoute: AudioInputRoute?
    /// What the live engine was actually built with, so a settings change forces a
    /// rebuild instead of appearing to do nothing until the idle hold expires.
    private var engineUsesVoiceProcessing = false

    private let lock = NSLock()
    /// Filled on the audio tap thread; `stop()` reads it after capturing ends.
    nonisolated(unsafe) private var captured: [Float] = []
    /// Last ~600 ms while the engine is warm but we are not in a take.
    nonisolated(unsafe) private var preroll: [Float] = []
    nonisolated(unsafe) private var isCapturing = false
    nonisolated(unsafe) private var didAnnounceInputReady = false
    nonisolated(unsafe) private var samplesSinceEngineStart = 0
    nonisolated(unsafe) private var latestLevel: Float = 0
    nonisolated(unsafe) private var didLogFirstBuffer = false

    private let targetSampleRate: Double = 16_000
    private let prerollCapacity = Int(16_000 * 0.6)
    /// If the mic stays gated-silent, still flip ready after this much HAL audio.
    private let readyFallbackSamples = Int(16_000 * 1.2)
    private let logger = Logger(subsystem: "com.usingcolor.WhisperLocal", category: "audio")

    init() {
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.teardown()
            }
        }
    }

    deinit {
        if let sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver)
        }
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
        }
    }

    /// Open the input graph without starting a take (first launch / after model load).
    func prewarm() {
        guard !isEngineLive else {
            scheduleIdleStop()
            return
        }
        do {
            try startEngine()
            scheduleIdleStop()
        } catch {
            logger.error("Mic prewarm failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Start capturing mono PCM at 16 kHz.
    /// Always resets the sample buffer. A missed `stop()` must not prepend the previous take.
    func start() throws {
        idleStopTask?.cancel()
        idleStopTask = nil

        // Preroll covers *engine-start* latency (Bluetooth profile switch). A warm,
        // already-live mic is not dropping words — prepending would capture whatever
        // you were saying before the key, and lengthen every ASR call.
        let inputWasReady = isInputReady
        lock.lock()
        let alreadyCapturing = isCapturing
        captured.removeAll(keepingCapacity: true)
        captured.reserveCapacity(16_000 * 60)
        let prepended: Int
        if !alreadyCapturing, !inputWasReady, !preroll.isEmpty {
            captured.append(contentsOf: preroll)
            prepended = preroll.count
        } else {
            prepended = 0
        }
        preroll.removeAll(keepingCapacity: true)
        preroll.reserveCapacity(prerollCapacity)
        isCapturing = true
        latestLevel = 0
        lock.unlock()
        if prepended > 0 {
            logger.info("Prepended \(prepended, privacy: .public) preroll frames")
        }

        let wantsVoiceProcessing = SettingsStore.shared.enableEchoCancellation
        if isEngineLive, engineUsesVoiceProcessing != wantsVoiceProcessing {
            logger.info("Rebuilding the input graph for a voice-processing change")
            stopEngineHardware()
        }

        if isEngineLive {
            isRecording = true
            return
        }

        lock.lock()
        didAnnounceInputReady = false
        samplesSinceEngineStart = 0
        didLogFirstBuffer = false
        lock.unlock()
        isInputReady = false
        inputFailed = false

        try startEngine()
        isRecording = true
    }

    /// Stop this take and return Float32 mono samples at 16 kHz. Leaves the engine warm.
    func stop() -> [Float] {
        lock.lock()
        isCapturing = false
        let samples = captured
        captured.removeAll(keepingCapacity: true)
        preroll.removeAll(keepingCapacity: true)
        latestLevel = 0
        lock.unlock()
        isRecording = false
        scheduleIdleStop()
        return samples
    }

    nonisolated func snapshotLevel() -> Float {
        lock.lock()
        defer { lock.unlock() }
        return latestLevel
    }

    func cancel() {
        _ = stop()
    }

    private var isEngineLive: Bool {
        tapInstalled && engine?.isRunning == true
    }

    private func startEngine() throws {
        stopEngineHardware()

        let engine = AVAudioEngine()
        let input = engine.inputNode
        // Voice processing first: turning it on rebuilds the underlying audio unit,
        // which would discard a device selection made before it. Both must happen
        // before the format is read, since the format belongs to the unit and the
        // device it points at.
        applyVoiceProcessing(to: input)
        applyPreferredInputDevice(to: input)
        // A `format: nil` tap delivers the node's *output* format, so read that.
        // (Under voice processing both sides report the same 7-channel discrete
        // layout; the downmix that handles it lives in `ingest`.)
        var hardwareFormat = input.outputFormat(forBus: 0)
        if hardwareFormat.sampleRate <= 0 || hardwareFormat.channelCount == 0 {
            hardwareFormat = input.inputFormat(forBus: 0)
        }
        if hardwareFormat.sampleRate > 0 {
            let raw = input.inputFormat(forBus: 0)
            logger.info(
                "Mic format \(hardwareFormat.sampleRate, privacy: .public) Hz, \(hardwareFormat.channelCount, privacy: .public) ch (device \(raw.sampleRate, privacy: .public) Hz, \(raw.channelCount, privacy: .public) ch)"
            )
        }

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioRecorderError.formatUnavailable
        }

        let converter: AVAudioConverter? = {
            guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else { return nil }
            return AVAudioConverter(from: hardwareFormat, to: outputFormat)
        }()

        self.outputFormat = outputFormat
        self.converter = converter
        self.engine = engine
        engineStartedAt = Date()

        installTap(
            on: engine,
            outputFormat: outputFormat,
            converter: converter,
            converterSourceFormat: hardwareFormat
        )

        do {
            try engine.start()
        } catch {
            stopEngineHardware()
            throw AudioRecorderError.engineStartFailed(error as NSError)
        }
        refreshCachedInputRoute()

        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reinstallTapAfterConfigurationChange()
            }
        }
    }

    /// macOS voice processing: acoustic echo cancellation, so the mic stops hearing
    /// this Mac's own speakers. Dev-only for now — it brings noise suppression and
    /// gain control along with it, and their effect on transcript quality has not
    /// been measured. Failure is non-fatal: dictation continues on the raw input.
    private func applyVoiceProcessing(to input: AVAudioInputNode) {
        let wanted = SettingsStore.shared.enableEchoCancellation
        // Records what this engine was *asked* for, not what succeeded. Storing the
        // outcome meant a failure left the flag disagreeing with the setting
        // forever, and start() then tore the graph down and rebuilt it on every
        // single take — a mic restart each time, and a Bluetooth profile switch
        // with it.
        engineUsesVoiceProcessing = wanted
        guard wanted else { return }
        do {
            try input.setVoiceProcessingEnabled(true)
            // Duck other audio while you speak. Cancellation alone cannot cope with
            // double-talk — two voices at once is where the adaptive filter stops
            // adapting and residual speech leaks into the transcript. Dipping the
            // far end is the direct remedy: less echo to cancel in the moment that
            // cancellation is worst at.
            var ducking = AVAudioVoiceProcessingOtherAudioDuckingConfiguration()
            ducking.enableAdvancedDucking = true
            ducking.duckingLevel = .default
            input.voiceProcessingOtherAudioDuckingConfiguration = ducking
            // AGC rides gain up through quiet passages, which pumps whatever residual
            // survived cancellation. Steady levels suit the speech model better.
            input.isVoiceProcessingAGCEnabled = false
            logger.info("Voice processing ON (echo cancellation, ducking, AGC off)")
        } catch {
            logger.error("Voice processing failed, using raw input: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Point the input unit at the built-in mic when the default input is a
    /// Bluetooth device that is also playing. Otherwise leave the user's choice
    /// alone — someone across the room needs the headset mic, and that is their
    /// call to make in Settings.
    private func applyPreferredInputDevice(to input: AVAudioInputNode) {
        guard SettingsStore.shared.preferBuiltInMicOverBluetooth else { return }
        let route = AudioInputRoute.current()
        guard AudioInputSelection.defaultInputWouldDisruptPlayback(route),
              let builtIn = AudioInputSelection.builtInInputDevice(),
              let unit = input.audioUnit else { return }

        var deviceID = builtIn
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status == noErr {
            logger.info("Using built-in mic so Bluetooth playback stays in A2DP")
        } else {
            logger.error("Could not select the built-in mic (\(status, privacy: .public))")
        }
    }

    private func installTap(
        on engine: AVAudioEngine,
        outputFormat: AVAudioFormat,
        converter: AVAudioConverter?,
        converterSourceFormat: AVAudioFormat
    ) {
        let input = engine.inputNode
        // nil format = hardware bus format. Passing a guessed format after prepare() is what
        // produced silence or -10867.
        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            self?.ingest(
                buffer,
                outputFormat: outputFormat,
                converter: converter,
                converterSourceFormat: converterSourceFormat
            )
        }
        tapInstalled = true
    }

    private func reinstallTapAfterConfigurationChange() {
        guard let engine else { return }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }

        var hardwareFormat = engine.inputNode.inputFormat(forBus: 0)
        if hardwareFormat.sampleRate <= 0 || hardwareFormat.channelCount == 0 {
            hardwareFormat = engine.inputNode.outputFormat(forBus: 0)
        }
        guard let outputFormat else { return }
        let converter: AVAudioConverter? = {
            guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else { return nil }
            return AVAudioConverter(from: hardwareFormat, to: outputFormat)
        }()
        self.converter = converter
        if hardwareFormat.sampleRate > 0 {
            logger.info(
                "Mic reconfigured \(hardwareFormat.sampleRate, privacy: .public) Hz, \(hardwareFormat.channelCount, privacy: .public) ch"
            )
        }
        // A profile switch is the moment the stream becomes live. Re-arm the
        // liveness latch so we do not keep "ready" from pre-switch silence.
        lock.lock()
        didAnnounceInputReady = false
        samplesSinceEngineStart = 0
        preroll.removeAll(keepingCapacity: true)
        lock.unlock()
        isInputReady = false
        engineStartedAt = Date()
        refreshCachedInputRoute()

        installTap(
            on: engine,
            outputFormat: outputFormat,
            converter: converter,
            converterSourceFormat: hardwareFormat
        )
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                logger.error("Mic restart after reconfigure failed: \(error.localizedDescription, privacy: .public)")
                // Unplugging an interface mid-take used to leave the take running
                // against a dead graph: no audio arrived, nothing said so, and the
                // transcript simply stopped where the device did.
                if isRecording { inputFailed = true }
            }
        }
        if !isRecording {
            scheduleIdleStop()
        }
    }

    private func inputRouteForIdleHold() -> AudioInputRoute {
        if let cachedInputRoute { return cachedInputRoute }
        let route = AudioInputRoute.current()
        cachedInputRoute = route
        return route
    }

    private func refreshCachedInputRoute() {
        cachedInputRoute = AudioInputRoute.current()
    }

    private func scheduleIdleStop() {
        idleStopTask?.cancel()
        let route = inputRouteForIdleHold()
        let hold = AudioIdleHold.nanoseconds(for: route)
        logger.info(
            "Mic idle hold \(hold / 1_000_000_000, privacy: .public)s (\(route.logReason, privacy: .public))"
        )
        idleStopTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: hold)
            guard !Task.isCancelled, !isRecording else { return }
            teardown()
        }
    }

    private func stopEngineHardware() {
        idleStopTask?.cancel()
        idleStopTask = nil
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        if let engine {
            if tapInstalled {
                engine.inputNode.removeTap(onBus: 0)
                tapInstalled = false
            }
            if engine.isRunning {
                engine.stop()
            }
        }
        tapInstalled = false
        engine = nil
        converter = nil
        outputFormat = nil
        engineStartedAt = nil
        cachedInputRoute = nil
    }

    private func teardown() {
        stopEngineHardware()
        isRecording = false
        isInputReady = false
        inputFailed = false
        lock.lock()
        isCapturing = false
        didAnnounceInputReady = false
        samplesSinceEngineStart = 0
        latestLevel = 0
        preroll.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    nonisolated private func announceInputReadyIfNeeded(live: Bool, peak: Float, appended: Int) {
        lock.lock()
        samplesSinceEngineStart += appended
        let already = didAnnounceInputReady
        let fallback = samplesSinceEngineStart >= readyFallbackSamples
        let shouldAnnounce = !already && (live || fallback)
        if shouldAnnounce {
            didAnnounceInputReady = true
        }
        lock.unlock()
        guard shouldAnnounce else { return }
        Task { @MainActor in
            self.isInputReady = true
            let ms = self.engineStartedAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? 0
            self.logger.info("Mic live after \(ms, privacy: .public) ms (peak \(peak, privacy: .public))")
        }
    }

    nonisolated private func ingest(
        _ buffer: AVAudioPCMBuffer,
        outputFormat: AVAudioFormat,
        converter: AVAudioConverter?,
        converterSourceFormat: AVAudioFormat
    ) {
        guard buffer.frameLength > 0 else { return }

        // Diagnostic: separates "the unit hands us silence" from "our conversion
        // produces silence". Logged once per engine start.
        if !didLogFirstBuffer {
            didLogFirstBuffer = true
            let rawPeak = Self.peakAndLive(Self.monoFloats(from: buffer)).0
            logger.info(
                "First tap buffer: \(buffer.format.channelCount, privacy: .public) ch, layoutTag \(buffer.format.channelLayout?.layoutTag ?? 0, privacy: .public), raw peak \(rawPeak, privacy: .public)"
            )
        }

        var appended = 0
        var peak: Float = 0
        var live = false
        // Mono only. AVAudioConverter has no mixing rules for a DiscreteInOrder
        // layout — voice processing hands us 7 such channels — and rather than
        // failing it returns frames of zeros, which `appended > 0` then treats as
        // real audio and hides the manual path that would have worked. Anything
        // multi-channel is downmixed explicitly below instead.
        let converterUsable = converter != nil
            && abs(buffer.format.sampleRate - converterSourceFormat.sampleRate) < 1
            && buffer.format.channelCount == 1
            && converterSourceFormat.channelCount == 1
        if converterUsable, let converter {
            (appended, peak, live) = convertAndAppend(buffer, outputFormat: outputFormat, converter: converter)
        }
        if appended == 0 {
            let mono = Self.monoFloats(from: buffer)
            let resampled = Self.resample(mono, from: buffer.format.sampleRate, to: outputFormat.sampleRate)
            guard !resampled.isEmpty else { return }
            (peak, live) = Self.peakAndLive(resampled)
            store(resampled)
            appended = resampled.count
            publishLevelIfCapturing(resampled)
        }
        announceInputReadyIfNeeded(live: live, peak: peak, appended: appended)
    }

    /// Returns (16 kHz frames appended, peak amplitude, any sample ≠ 0).
    nonisolated private func convertAndAppend(
        _ buffer: AVAudioPCMBuffer,
        outputFormat: AVAudioFormat,
        converter: AVAudioConverter
    ) -> (Int, Float, Bool) {
        let ratio = outputFormat.sampleRate / max(buffer.format.sampleRate, 1)
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return (0, 0, false)
        }

        var error: NSError?
        var consumed = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        converter.convert(to: converted, error: &error, withInputFrom: inputBlock)
        guard error == nil, converted.frameLength > 0, let channel = converted.floatChannelData?[0] else {
            return (0, 0, false)
        }

        let count = Int(converted.frameLength)
        let pointer = UnsafeBufferPointer(start: channel, count: count)
        let (peak, live) = Self.peakAndLive(pointer)
        store(pointer)
        publishLevelIfCapturing(pointer)
        return (count, peak, live)
    }

    nonisolated private func store(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { store($0) }
    }

    nonisolated private func store(_ samples: UnsafeBufferPointer<Float>) {
        lock.lock()
        defer { lock.unlock() }
        if isCapturing {
            captured.append(contentsOf: samples)
        } else {
            preroll.append(contentsOf: samples)
            if preroll.count > prerollCapacity {
                preroll.removeFirst(preroll.count - prerollCapacity)
            }
        }
    }

    nonisolated private func publishLevelIfCapturing(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { publishLevelIfCapturing($0) }
    }

    nonisolated private func publishLevelIfCapturing(_ samples: UnsafeBufferPointer<Float>) {
        lock.lock()
        let capturing = isCapturing
        lock.unlock()
        guard capturing else { return }
        publishLevel(samples)
    }

    nonisolated private func publishLevel(_ samples: UnsafeBufferPointer<Float>) {
        let count = samples.count
        guard count > 0 else { return }
        var sum: Float = 0
        for s in samples {
            sum += s * s
        }
        let rms = min(1, sqrt(sum / Float(count)) * 8)
        lock.lock()
        latestLevel = rms
        lock.unlock()
    }

    nonisolated private static func peakAndLive(_ samples: [Float]) -> (Float, Bool) {
        samples.withUnsafeBufferPointer { peakAndLive($0) }
    }

    nonisolated private static func peakAndLive(_ samples: UnsafeBufferPointer<Float>) -> (Float, Bool) {
        var peak: Float = 0
        var live = false
        for s in samples {
            if s != 0 { live = true }
            let a = abs(s)
            if a > peak { peak = a }
        }
        return (peak, live)
    }

    nonisolated private static func monoFloats(from buffer: AVAudioPCMBuffer) -> [Float] {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return [] }
        let channels = Int(max(buffer.format.channelCount, 1))

        if let data = buffer.floatChannelData {
            var out = [Float](repeating: 0, count: frames)
            let inv = 1 / Float(channels)
            for i in 0..<frames {
                var sum: Float = 0
                for ch in 0..<channels { sum += data[ch][i] }
                out[i] = sum * inv
            }
            return out
        }
        if let data = buffer.int16ChannelData {
            var out = [Float](repeating: 0, count: frames)
            let inv = 1 / (Float(channels) * 32768)
            for i in 0..<frames {
                var sum: Float = 0
                for ch in 0..<channels { sum += Float(data[ch][i]) }
                out[i] = sum * inv
            }
            return out
        }
        if let data = buffer.int32ChannelData {
            var out = [Float](repeating: 0, count: frames)
            let inv = 1 / (Float(channels) * Float(Int32.max))
            for i in 0..<frames {
                var sum: Float = 0
                for ch in 0..<channels { sum += Float(data[ch][i]) }
                out[i] = sum * inv
            }
            return out
        }
        return []
    }

    nonisolated private static func resample(_ input: [Float], from sourceRate: Double, to targetRate: Double) -> [Float] {
        guard !input.isEmpty, sourceRate > 0, targetRate > 0 else { return [] }
        if abs(sourceRate - targetRate) < 0.5 {
            return input
        }
        let ratio = targetRate / sourceRate
        let outCount = max(1, Int((Double(input.count) * ratio).rounded(.down)))
        var out = [Float](repeating: 0, count: outCount)
        let last = input.count - 1
        for i in 0..<outCount {
            let src = Double(i) / ratio
            let i0 = min(Int(src), last)
            let i1 = min(i0 + 1, last)
            let frac = Float(src - Double(i0))
            out[i] = input[i0] + (input[i1] - input[i0]) * frac
        }
        return out
    }
}

enum AudioRecorderError: LocalizedError {
    case formatUnavailable
    case converterUnavailable
    case noInputDevice
    case engineStartFailed(NSError)

    var errorDescription: String? {
        switch self {
        case .formatUnavailable:
            return "Could not create 16 kHz mono audio format."
        case .converterUnavailable:
            return "Could not create the 16 kHz audio converter."
        case .noInputDevice:
            return "No microphone input. Check the input device in System Settings → Sound."
        case .engineStartFailed(let error):
            switch error.code {
            case -10867, 10867:
                return "Microphone isn’t ready. Check System Settings → Sound → Input, then try again."
            case -10868, 10868:
                return "This microphone’s format isn’t supported. Try a different input in System Settings → Sound."
            default:
                return "Couldn’t start the microphone."
            }
        }
    }
}
