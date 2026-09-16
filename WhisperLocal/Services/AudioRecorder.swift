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

    /// The microphone the live graph is open on, by name, and every one this take
    /// has used. The trail is what the dictation log records: a mid-take switch is
    /// exactly the thing worth knowing when a transcript reads oddly halfway
    /// through, and a single name would hide it.
    @Published private(set) var currentInputName: String?
    private(set) var inputTrail: [String] = []

    private var inputUnit: AudioInputUnit?
    private var outputFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var sleepObserver: NSObjectProtocol?
    private var idleStopTask: Task<Void, Never>?
    /// Device notifications arrive in bursts — format, rate and liveness all at
    /// once — so the rebuild is coalesced instead of running three times.
    private var configChangeTask: Task<Void, Never>?
    private var engineStartedAt: Date?
    /// Snapshot for idle-hold length. Refreshed when the engine starts or the
    /// graph reconfigures — not on every take, so `stop()` stays off coreaudiod.
    private var cachedInputRoute: AudioInputRoute?

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
                guard let self else { return }
                // Sleeping mid-take used to end capture and say nothing: you woke to
                // a transcript that stopped where the lid closed. Treat it like any
                // other dead input so the take completes with what it caught.
                let wasRecording = self.isRecording
                self.teardown()
                if wasRecording { self.inputFailed = true }
            }
        }
    }

    deinit {
        if let sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver)
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

        inputTrail = []

        if isEngineLive {
            inputTrail = currentInputName.map { [$0] } ?? []
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

    /// Hand off the first complete chunk of a take in progress, so it can be
    /// transcribed while recording continues. Nil until there is enough audio to
    /// place a cut — which for a short take is never, so those behave exactly as
    /// they did before streaming existed.
    ///
    /// Removing the prefix here is what bounds memory: the buffer holds the
    /// untranscribed tail rather than the whole recording.
    func drainCompletedChunk() -> [Float]? {
        lock.lock()
        defer { lock.unlock() }
        guard isCapturing else { return nil }
        guard let cut = AudioChunker.streamingCut(in: captured, sampleRate: targetSampleRate),
              cut > 0, cut <= captured.count else { return nil }
        let chunk = Array(captured[0..<cut])
        captured.removeFirst(cut)
        return chunk
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
        inputUnit?.isRunning == true
    }

    private func startEngine() throws {
        stopEngineHardware()

        guard let target = deviceForThisTake() else { throw AudioRecorderError.noInputDevice }
        currentInputName = target.name
        // Only while a take is running: a prewarm or an idle rebuild is not part of
        // anyone's recording. `isCapturing` is already true by the time `start()`
        // reaches here, so the device a cold take opens lands in the trail.
        if isCapturing, inputTrail.last != target.name {
            inputTrail.append(target.name)
        }

        // A new graph has to prove its own liveness: silence carried over from the
        // last one would announce a microphone that is not passing audio yet.
        lock.lock()
        didAnnounceInputReady = false
        samplesSinceEngineStart = 0
        didLogFirstBuffer = false
        lock.unlock()
        isInputReady = false

        // Playback either side of the mic opening. A take used to change the
        // headset's Bluetooth profile, and with it the volume, without this app
        // touching output at all — so the log says whether the system moved the
        // output device, its volume, or its sample rate underneath us.
        let outputBefore = AudioOutputSnapshot.current()
        engineStartedAt = Date()

        try startInputUnit(on: target)

        refreshCachedInputRoute()
        logOutputChange(from: outputBefore)
    }

    /// The ordinary path: our own unit, on the device we picked.
    private func startInputUnit(on target: InputTarget) throws {
        let unit: AudioInputUnit
        do {
            unit = try AudioInputUnit(deviceID: target.id)
        } catch {
            throw AudioRecorderError.engineStartFailed(error as NSError)
        }
        let hardwareFormat = unit.format
        logger.info(
            "Mic format \(hardwareFormat.sampleRate, privacy: .public) Hz, \(hardwareFormat.channelCount, privacy: .public) ch on \(target.name, privacy: .public)"
        )
        let (outputFormat, converter) = try makeConversion(from: hardwareFormat)
        self.inputUnit = unit

        unit.onBuffer = { [weak self] buffer in
            self?.ingest(
                buffer,
                outputFormat: outputFormat,
                converter: converter,
                converterSourceFormat: hardwareFormat
            )
        }
        unit.onConfigurationChange = { [weak self] in
            Task { @MainActor in self?.scheduleConfigurationRebuild() }
        }

        do {
            try unit.start()
        } catch {
            stopEngineHardware()
            throw AudioRecorderError.engineStartFailed(error as NSError)
        }
        unit.watchForChanges(followingSystemDefault: target.followsSystemDefault)
    }

    private func makeConversion(from hardwareFormat: AVAudioFormat) throws -> (AVAudioFormat, AVAudioConverter?) {
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
        return (outputFormat, converter)
    }

    /// One microphone, named before anything is opened.
    struct InputTarget {
        let id: AudioDeviceID
        let name: String
        /// True when nothing in particular was asked for, so the take should move
        /// if System Settings points input somewhere else.
        let followsSystemDefault: Bool
    }

    /// Which device this take opens.
    ///
    /// An explicit choice wins outright: someone who picked a mic means it, even
    /// if it is the headset that will drop playback to narrowband. With no choice
    /// made, the rule stands — swap a Bluetooth device that is also playing for a
    /// microphone off the radio, so music stays in A2DP and ASR gets full band.
    ///
    /// This resolves to a concrete device rather than "whatever the default is",
    /// because the unit has to be told before it is initialised. Following the
    /// default then means watching for it to change, not leaving the choice open.
    private func deviceForThisTake() -> InputTarget? {
        let connected = AudioInputSelection.inputDevices()
        let plan = AudioInputSelection.plan(
            preferredUID: SettingsStore.shared.preferredInputDeviceUID,
            connected: connected,
            route: AudioInputRoute.current()
        )
        switch plan {
        case .systemDefault:
            guard let device = connected.first(where: { $0.isSystemDefault }) ?? connected.first else {
                return nil
            }
            return InputTarget(id: device.id, name: device.name, followsSystemDefault: true)
        case .chosen(let uid):
            guard let device = connected.first(where: { $0.uid == uid }) else { return nil }
            logger.info("Recording from the chosen mic \(device.name, privacy: .public)")
            return InputTarget(id: device.id, name: device.name, followsSystemDefault: false)
        case .protectPlayback(let uid):
            guard let device = connected.first(where: { $0.uid == uid }) else { return nil }
            logger.info("Using \(device.name, privacy: .public) so Bluetooth playback stays in A2DP")
            return InputTarget(id: device.id, name: device.name, followsSystemDefault: false)
        }
    }

    /// Move a take in progress onto another microphone without ending it.
    ///
    /// The graph has to be rebuilt — the device belongs to the input unit, and its
    /// format may differ — so there is a gap of a few hundred milliseconds where
    /// nothing is captured. What was already said is untouched: the sample buffer
    /// is not cleared here, only in `start()`, so the take continues into the same
    /// recording and the words either side of the gap end up in one transcript.
    func useInput(uid: String?) {
        let wasRecording = isRecording
        SettingsStore.shared.preferredInputDeviceUID = uid
        guard isEngineLive || wasRecording else { return }
        logger.info("Switching microphone mid-take: \(uid ?? "system default", privacy: .public)")
        do {
            try startEngine()
            isRecording = wasRecording
        } catch {
            logger.error("Could not switch microphone: \(error.localizedDescription, privacy: .public)")
            inputFailed = true
        }
    }

    /// Logs the output device before the mic opened, and again once the system has
    /// had a moment to react to it.
    private func logOutputChange(from before: AudioOutputSnapshot) {
        logger.info("Output before mic: \(before.summary, privacy: .public)")
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let self else { return }
            let after = AudioOutputSnapshot.current()
            if after == before {
                self.logger.info("Output after mic: unchanged")
            } else {
                self.logger.info("Output after mic: \(after.summary, privacy: .public) — CHANGED")
            }
        }
    }

    /// The device changed its format, went away, or — when no microphone was asked
    /// for — was replaced as the system default. Rebuild on the device that is
    /// there now.
    /// No second filter here: `AudioInputUnit` only reports a change when the
    /// hardware rate or channel count really differs from the format it was built
    /// with, the device can no longer be read, or the default it follows moved.
    /// One briefly sat on top of that, written for the voice-processing path's
    /// rebuild loop. With that path gone it only swallowed real changes — it
    /// compared the unit's fixed `format` with a copy of itself, so a rate change
    /// mid-take never rebuilt.
    private func scheduleConfigurationRebuild() {
        configChangeTask?.cancel()
        configChangeTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, self.isEngineLive || self.inputUnit != nil else { return }
            self.rebuildAfterConfigurationChange()
        }
    }

    private func rebuildAfterConfigurationChange() {
        logger.info("Input device changed under the take; rebuilding")
        let wasRecording = isRecording
        lock.lock()
        preroll.removeAll(keepingCapacity: true)
        lock.unlock()
        do {
            try startEngine()
            isRecording = wasRecording
            if !wasRecording { scheduleIdleStop() }
        } catch {
            logger.error("Mic restart after reconfigure failed: \(error.localizedDescription, privacy: .public)")
            // Unplugging an interface mid-take used to leave the take running
            // against a dead graph: no audio arrived, nothing said so, and the
            // transcript simply stopped where the device did.
            if wasRecording { inputFailed = true }
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
        configChangeTask?.cancel()
        configChangeTask = nil
        inputUnit?.dispose()
        inputUnit = nil
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
        // layout — a MacBook's mic array reports seven such channels — and rather
        // than failing it returns frames of zeros, which `appended > 0` then treats
        // as real audio and hides the manual path that would have worked. Anything
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
