import Foundation
import WhisperKit
import FluidAudio
import os

@MainActor
final class TranscriptionService: ObservableObject {
    @Published private(set) var isReady = false
    @Published private(set) var isLoadingModel = false
    /// Same string shown in the menu bar and Settings.
    @Published private(set) var statusMessage = "Speech: not loaded"
    @Published private(set) var lastError: String?
    /// Model the user asked for (picker / settings).
    @Published private(set) var requestedModel: ASRModelOption?
    /// Model actually in memory, if any.
    @Published private(set) var loadedModel: ASRModelOption?

    private var whisperKit: WhisperKit?
    private var parakeet: AsrManager?
    private var loadGeneration = 0
    private let logger = Logger(subsystem: "com.usingcolor.WhisperLocal", category: "speech")

    /// Load `model`. Pass `force: true` to download/reload even if that model is already in memory.
    func ensureModel(named model: ASRModelOption, force: Bool = false) async {
        if !force, loadedModel == model, backendIsReady(for: model) {
            requestedModel = model
            applyReady(model)
            return
        }
        if !force, isLoadingModel, requestedModel == model {
            logger.info("Speech load already in progress for \(model.shortName, privacy: .public)")
            return
        }

        requestedModel = model

        loadGeneration += 1
        let generation = loadGeneration
        isLoadingModel = true
        isReady = false
        lastError = nil
        statusMessage = "Loading \(model.shortName)…"
        logger.info("Loading speech model \(model.shortName, privacy: .public)")

        do {
            switch model.engine {
            case .whisper:
                try await loadWhisper(model, generation: generation)
            case .parakeet:
                try await loadParakeet(model, generation: generation)
            case .appleSpeech:
                try await loadAppleSpeech(model, generation: generation)
            }
            guard generation == loadGeneration else { return }
            loadedModel = model
            applyReady(model)
            logger.info("Speech model ready \(model.shortName, privacy: .public)")
        } catch {
            guard generation == loadGeneration else { return }
            unloadAll()
            loadedModel = nil
            isReady = false
            lastError = error.localizedDescription
            statusMessage = "\(model.shortName) failed — \(error.localizedDescription)"
            isLoadingModel = false
            logger.error("Speech model failed \(model.shortName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            await AppleSpeechASR.shared.unload()
        }
    }

    static let sampleRate: Double = 16_000

    /// Transcribe 16 kHz mono Float32 samples.
    /// `onProgress` reports (chunk, total) for long takes, which otherwise sit on a
    /// bare spinner for minutes.
    func transcribe(
        samples: [Float],
        extraDictionary: [String] = [],
        onProgress: ((Int, Int) -> Void)? = nil
    ) async throws -> String {
        guard isReady, loadedModel == requestedModel, let model = loadedModel else {
            throw TranscriptionError.modelNotLoaded
        }
        guard !samples.isEmpty else {
            throw TranscriptionError.emptyAudio
        }

        let dictionary = CleanupPrompt.mergedDictionary(
            SettingsStore.shared.dictionaryWords + extraDictionary
        )

        let seconds = Double(samples.count) / Self.sampleRate
        guard TakeLimits.shouldChunk(seconds: seconds) else {
            return try await transcribeOnce(samples, model: model, dictionary: dictionary)
        }
        return try await transcribeChunked(
            samples, model: model, dictionary: dictionary, onProgress: onProgress
        )
    }

    private func transcribeOnce(
        _ samples: [Float],
        model: ASRModelOption,
        dictionary: [String]
    ) async throws -> String {
        switch model.engine {
        case .whisper:
            return try await transcribeWhisper(samples)
        case .parakeet:
            return try await transcribeParakeet(samples)
        case .appleSpeech:
            return try await AppleSpeechASR.shared.transcribe(
                samples: samples,
                dictionary: dictionary
            )
        }
    }

    /// Divide and conquer. A long take used to go in as one piece, so any failure
    /// lost every word of it; here a failed chunk costs its own span and the rest
    /// still comes back. It also keeps peak memory on the chunk rather than the
    /// whole recording, which for an hour was ~3x 220 MB.
    private func transcribeChunked(
        _ samples: [Float],
        model: ASRModelOption,
        dictionary: [String],
        onProgress: ((Int, Int) -> Void)?
    ) async throws -> String {
        let planned = AudioChunker.plan(sampleCount: samples.count, sampleRate: Self.sampleRate)
        let ranges = AudioChunker.refine(planned, in: samples, sampleRate: Self.sampleRate)
        guard ranges.count > 1 else {
            return try await transcribeOnce(samples, model: model, dictionary: dictionary)
        }

        logger.info("Chunked transcribe: \(ranges.count, privacy: .public) pieces")
        var parts: [String] = []
        var failed = 0

        for (index, range) in ranges.enumerated() {
            onProgress?(index + 1, ranges.count)
            let chunk = Array(samples[range])
            do {
                parts.append(try await transcribeOnce(chunk, model: model, dictionary: dictionary))
            } catch {
                logger.error("Chunk \(index + 1, privacy: .public) failed, retrying: \(error.localizedDescription, privacy: .public)")
                do {
                    // One retry. Most failures at this layer are transient — a model
                    // hiccup or a temp-file write — not a property of the audio.
                    parts.append(try await transcribeOnce(chunk, model: model, dictionary: dictionary))
                } catch {
                    logger.error("Chunk \(index + 1, privacy: .public) failed twice: \(error.localizedDescription, privacy: .public)")
                    failed += 1
                    parts.append(TranscriptJoiner.gapMarker)
                }
            }
        }

        // Only give up when nothing at all came back. One bad chunk must never
        // blank a take the user spent minutes on.
        if failed == ranges.count {
            throw TranscriptionError.emptyAudio
        }
        if failed > 0 {
            logger.error("Chunked transcribe finished with \(failed, privacy: .public) gap(s)")
        }
        return TranscriptJoiner.join(parts)
    }

    private func backendIsReady(for model: ASRModelOption) -> Bool {
        switch model.engine {
        case .whisper: return whisperKit != nil
        case .parakeet: return parakeet != nil
        case .appleSpeech: return AppleSpeechASR.shared.isReady
        }
    }

    private func loadWhisper(_ model: ASRModelOption, generation: Int) async throws {
        guard let name = model.whisperKitName else {
            throw TranscriptionError.modelNotLoaded
        }
        let config = WhisperKitConfig(
            model: name,
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: true
        )
        let kit = try await WhisperKit(config)
        guard generation == loadGeneration else { return }
        whisperKit = kit
        parakeet = nil
        await AppleSpeechASR.shared.unload()
    }

    private func loadParakeet(_ model: ASRModelOption, generation: Int) async throws {
        let version = AsrModelVersion.v2
        let models = try await AsrModels.downloadAndLoad(
            version: version,
            progressHandler: { [weak self] progress in
                Task { @MainActor in
                    guard let self, generation == self.loadGeneration else { return }
                    self.statusMessage = Self.parakeetProgressMessage(progress, model: model)
                }
            }
        )
        guard generation == loadGeneration else { return }

        let asrConfig = ASRConfig(
            tdtConfig: TdtConfig(blankId: version.blankId),
            encoderHiddenSize: version.encoderHiddenSize
        )
        let manager = AsrManager(config: asrConfig)
        try await manager.loadModels(models)
        guard generation == loadGeneration else { return }
        parakeet = manager
        whisperKit = nil
        await AppleSpeechASR.shared.unload()
    }

    private func loadAppleSpeech(_: ASRModelOption, generation: Int) async throws {
        try await AppleSpeechASR.shared.prepare { [weak self] message in
            guard let self, generation == self.loadGeneration else { return }
            self.statusMessage = message
        }
        guard generation == loadGeneration else { return }
        whisperKit = nil
        parakeet = nil
    }

    private func transcribeWhisper(_ samples: [Float]) async throws -> String {
        guard let whisperKit else { throw TranscriptionError.modelNotLoaded }
        let options = DecodingOptions(
            task: .transcribe,
            language: "en",
            temperature: 0,
            temperatureFallbackCount: 2,
            sampleLength: 224,
            usePrefillPrompt: true,
            usePrefillCache: true,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            wordTimestamps: false,
            suppressBlank: true
        )
        let results = try await whisperKit.transcribe(
            audioArray: samples,
            decodeOptions: options
        )
        return results.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func transcribeParakeet(_ samples: [Float]) async throws -> String {
        guard let parakeet else { throw TranscriptionError.modelNotLoaded }
        let padded = Self.padForParakeet(samples)
        var decoderState = TdtDecoderState.make(decoderLayers: await parakeet.decoderLayerCount)
        let result = try await parakeet.transcribe(padded, decoderState: &decoderState)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func unloadAll() {
        whisperKit = nil
        parakeet = nil
    }

    private func applyReady(_ model: ASRModelOption) {
        isLoadingModel = false
        isReady = true
        lastError = nil
        statusMessage = "\(model.shortName) — ready"
    }

    /// Parakeet rejects clips shorter than 0.3s.
    private static func padForParakeet(_ samples: [Float]) -> [Float] {
        let minimum = ASRConstants.minimumRequiredSamples(forSampleRate: 16_000)
        guard samples.count < minimum else { return samples }
        return samples + Array(repeating: 0, count: minimum - samples.count)
    }

    private static func parakeetProgressMessage(_ progress: DownloadProgress, model: ASRModelOption) -> String {
        let pct = Int((progress.fractionCompleted * 100).rounded())
        switch progress.phase {
        case .listing:
            return "Parakeet: finding \(model.shortName)…"
        case .downloading(let completed, let total):
            if total > 0 {
                return "Parakeet: downloading \(completed)/\(total) files (\(pct)%)…"
            }
            return "Parakeet: downloading \(pct)%…"
        case .compiling(let name):
            return "Parakeet: compiling \(name)…"
        }
    }
}

enum TranscriptionError: LocalizedError {
    case modelNotLoaded
    case emptyAudio
    case appleSpeechUnavailable
    case appleSpeechLocaleUnsupported

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "Speech model is not loaded yet."
        case .emptyAudio:
            return "No audio was recorded."
        case .appleSpeechUnavailable:
            return "Apple Speech needs macOS 26 and a supported Apple Silicon Mac."
        case .appleSpeechLocaleUnsupported:
            return "Apple Speech has no English model on this Mac."
        }
    }
}
