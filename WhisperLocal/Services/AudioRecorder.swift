import AVFoundation
import Foundation
import os

@MainActor
final class AudioRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var audioLevel: Float = 0

    private var engine: AVAudioEngine?
    private var tapInstalled = false
    private let lock = NSLock()
    /// Filled on the audio tap thread; `stop()` reads it after `removeTap`.
    nonisolated(unsafe) private var captured: [Float] = []

    private let targetSampleRate: Double = 16_000
    private let logger = Logger(subsystem: "com.usingcolor.WhisperLocal", category: "audio")

    /// Start capturing mono PCM at 16 kHz.
    func start() throws {
        guard !isRecording else { return }

        teardown()
        lock.lock()
        captured.removeAll(keepingCapacity: true)
        lock.unlock()
        audioLevel = 0

        let engine = AVAudioEngine()
        let input = engine.inputNode
        // Do not prepare() or connect the input node to the mixer before start().
        // That graph (prepare → tap → connect) throws kAudioUnitErr_Uninitialized (-10867).
        var hardwareFormat = input.inputFormat(forBus: 0)
        if hardwareFormat.sampleRate <= 0 || hardwareFormat.channelCount == 0 {
            hardwareFormat = input.outputFormat(forBus: 0)
        }
        if hardwareFormat.sampleRate > 0 {
            logger.info(
                "Mic format \(hardwareFormat.sampleRate, privacy: .public) Hz, \(hardwareFormat.channelCount, privacy: .public) ch"
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

        // nil format = hardware bus format. Passing a guessed format after prepare() is what
        // produced silence or -10867.
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            self?.ingest(buffer, outputFormat: outputFormat, converter: converter)
        }
        tapInstalled = true

        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            tapInstalled = false
            throw AudioRecorderError.engineStartFailed(error as NSError)
        }
        self.engine = engine
        isRecording = true
    }

    /// Stop and return Float32 mono samples at 16 kHz.
    func stop() -> [Float] {
        // removeTap waits for in-flight callbacks, so snapshot after teardown.
        teardown()
        return snapshot()
    }

    func cancel() {
        _ = stop()
        lock.lock()
        captured.removeAll()
        lock.unlock()
    }

    private func teardown() {
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
        isRecording = false
        audioLevel = 0
    }

    nonisolated private func ingest(
        _ buffer: AVAudioPCMBuffer,
        outputFormat: AVAudioFormat,
        converter: AVAudioConverter?
    ) {
        guard buffer.frameLength > 0 else { return }

        var appended = 0
        if let converter {
            appended = convertAndAppend(buffer, outputFormat: outputFormat, converter: converter)
        }
        if appended == 0 {
            let mono = Self.monoFloats(from: buffer)
            let resampled = Self.resample(mono, from: buffer.format.sampleRate, to: outputFormat.sampleRate)
            guard !resampled.isEmpty else { return }
            lock.lock()
            captured.append(contentsOf: resampled)
            lock.unlock()
            publishLevel(resampled)
            return
        }
    }

    /// Returns the number of 16 kHz frames appended.
    nonisolated private func convertAndAppend(
        _ buffer: AVAudioPCMBuffer,
        outputFormat: AVAudioFormat,
        converter: AVAudioConverter
    ) -> Int {
        let ratio = outputFormat.sampleRate / max(buffer.format.sampleRate, 1)
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return 0
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
            return 0
        }

        let count = Int(converted.frameLength)
        lock.lock()
        captured.append(contentsOf: UnsafeBufferPointer(start: channel, count: count))
        lock.unlock()
        publishLevel(UnsafeBufferPointer(start: channel, count: count))
        return count
    }

    nonisolated private func publishLevel(_ samples: [Float]) {
        publishLevel(UnsafeBufferPointer(start: samples, count: samples.count))
    }

    nonisolated private func publishLevel(_ samples: UnsafeBufferPointer<Float>) {
        let count = samples.count
        guard count > 0 else { return }
        var sum: Float = 0
        for s in samples {
            sum += s * s
        }
        let rms = min(1, sqrt(sum / Float(count)) * 8)
        Task { @MainActor in
            self.audioLevel = rms
        }
    }

    nonisolated private func snapshot() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return captured
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
