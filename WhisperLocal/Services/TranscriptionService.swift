import Foundation
import WhisperKit
import FluidAudio

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

    /// Load `model`. Pass `force: true` to download/reload even if that model is already in memory.
    func ensureModel(named model: ASRModelOption, force: Bool = false) async {
        requestedModel = model

        if !force, loadedModel == model, backendIsReady(for: model) {
            applyReady(model)
            return
        }

        loadGeneration += 1
        let generation = loadGeneration
        isLoadingModel = true
        isReady = false
        lastError = nil
        statusMessage = "Loading \(model.shortName)…"

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
        } catch {
            guard generation == loadGeneration else { return }
            unloadAll()
            loadedModel = nil
            isReady = false
            lastError = error.localizedDescription
            statusMessage = "\(model.shortName) failed — \(error.localizedDescription)"
            isLoadingModel = false
            await AppleSpeechASR.shared.unload()
        }
    }

    /// Transcribe 16 kHz mono Float32 samples.
    func transcribe(samples: [Float]) async throws -> String {
        guard isReady, loadedModel == requestedModel, let model = loadedModel else {
            throw TranscriptionError.modelNotLoaded
        }
        guard !samples.isEmpty else {
            throw TranscriptionError.emptyAudio
        }

        switch model.engine {
        case .whisper:
            return try await transcribeWhisper(samples)
        case .parakeet:
            return try await transcribeParakeet(samples)
        case .appleSpeech:
            return try await AppleSpeechASR.shared.transcribe(
                samples: samples,
                dictionary: SettingsStore.shared.dictionaryWords
            )
        }
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
