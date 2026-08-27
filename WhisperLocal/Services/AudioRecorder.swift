import AVFoundation
import Foundation

@MainActor
final class AudioRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var audioLevel: Float = 0

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    /// Filled on the audio tap thread; `stop()` reads it after `removeTap`.
    nonisolated(unsafe) private var captured: [Float] = []

    private let targetSampleRate: Double = 16_000

    /// Start capturing mono PCM at 16 kHz.
    func start() throws {
        guard !isRecording else { return }

        lock.lock()
        captured.removeAll(keepingCapacity: true)
        lock.unlock()
        audioLevel = 0

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioRecorderError.formatUnavailable
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw AudioRecorderError.converterUnavailable
        }

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.ingest(buffer, outputFormat: outputFormat, converter: converter)
        }

        // Capture-only: never route mic to speakers (no click / feedback / effects).
        engine.mainMixerNode.outputVolume = 0

        engine.prepare()
        try engine.start()
        isRecording = true
    }

    /// Stop and return Float32 mono samples at 16 kHz.
    func stop() -> [Float] {
        guard isRecording else { return snapshot() }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        audioLevel = 0
        return snapshot()
    }

    func cancel() {
        _ = stop()
        lock.lock()
        captured.removeAll()
        lock.unlock()
    }

    /// Convert inside the tap so AVAudioEngine's buffer is still valid, and so `stop()`
    /// cannot return before the last buffers are appended. The converter lives in the
    /// tap closure — it is not shared with a later `start()`.
    nonisolated private func ingest(
        _ buffer: AVAudioPCMBuffer,
        outputFormat: AVAudioFormat,
        converter: AVAudioConverter
    ) {
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }

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
        guard error == nil, let channel = converted.floatChannelData?[0] else { return }

        let frameCount = Int(converted.frameLength)
        lock.lock()
        captured.append(contentsOf: UnsafeBufferPointer(start: channel, count: frameCount))
        lock.unlock()

        var sum: Float = 0
        for i in 0..<frameCount {
            let s = channel[i]
            sum += s * s
        }
        let rms = min(1, sqrt(sum / Float(max(frameCount, 1))) * 8)
        Task { @MainActor in
            self.audioLevel = rms
        }
    }

    nonisolated private func snapshot() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }
}

enum AudioRecorderError: LocalizedError {
    case formatUnavailable
    case converterUnavailable

    var errorDescription: String? {
        switch self {
        case .formatUnavailable:
            return "Could not create 16 kHz mono audio format."
        case .converterUnavailable:
            return "Could not create the 16 kHz audio converter."
        }
    }
}
