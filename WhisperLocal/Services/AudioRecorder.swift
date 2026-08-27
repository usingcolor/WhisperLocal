import AVFoundation
import Foundation

@MainActor
final class AudioRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var audioLevel: Float = 0

    private let engine = AVAudioEngine()
    private var samples: [Float] = []
    private let targetSampleRate: Double = 16_000
    private var converter: AVAudioConverter?

    /// Start capturing mono PCM at 16 kHz.
    func start() throws {
        guard !isRecording else { return }

        samples.removeAll(keepingCapacity: true)
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

        converter = AVAudioConverter(from: inputFormat, to: outputFormat)

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.handleBuffer(buffer, outputFormat: outputFormat)
        }

        // Capture-only: never route mic to speakers (no click / feedback / effects).
        engine.mainMixerNode.outputVolume = 0

        engine.prepare()
        try engine.start()
        isRecording = true
    }

    /// Stop and return Float32 mono samples at 16 kHz.
    func stop() -> [Float] {
        guard isRecording else { return samples }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        audioLevel = 0
        return samples
    }

    func cancel() {
        _ = stop()
        samples.removeAll()
    }

    nonisolated private func handleBuffer(_ buffer: AVAudioPCMBuffer, outputFormat: AVAudioFormat) {
        Task { @MainActor in
            guard let converter else { return }

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
            let pointer = UnsafeBufferPointer(start: channel, count: frameCount)
            samples.append(contentsOf: pointer)

            // Rough RMS for HUD meter
            var sum: Float = 0
            for i in 0..<frameCount {
                let s = channel[i]
                sum += s * s
            }
            let rms = sqrt(sum / Float(max(frameCount, 1)))
            audioLevel = min(1, rms * 8)
        }
    }
}

enum AudioRecorderError: LocalizedError {
    case formatUnavailable

    var errorDescription: String? {
        switch self {
        case .formatUnavailable:
            return "Could not create 16 kHz mono audio format."
        }
    }
}
