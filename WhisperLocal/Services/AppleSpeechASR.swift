import AVFoundation
import Foundation
import Speech

/// On-device Apple Speech (`SpeechAnalyzer` + `SpeechTranscriber`, macOS 26+).
/// Audio stays on this Mac. Locale is English even if the system language is not.
@MainActor
final class AppleSpeechASR {
    static let shared = AppleSpeechASR()

    private(set) var isReady = false
    private var reservedLocale: Locale?
    private var createdReservation = false
    /// Holds the prewarm analyzer so `processLifetime` models stay resident.
    private var retainedWarmup: Any?

    static var isAvailable: Bool {
        if #available(macOS 26.0, *) {
            return SpeechTranscriber.isAvailable
        }
        return false
    }

    static var availabilityMessage: String {
        if #available(macOS 26.0, *) {
            if SpeechTranscriber.isAvailable {
                return "On-device Apple SpeechTranscriber. English. The system may download a shared speech model on first use."
            }
            return "Apple Speech is not available on this Mac’s hardware."
        }
        return "Apple Speech requires macOS 26 or later."
    }

    func prepare(onStatus: @escaping (String) -> Void) async throws {
        guard #available(macOS 26.0, *) else {
            throw TranscriptionError.appleSpeechUnavailable
        }
        try await prepareOnSupportedOS(onStatus: onStatus)
    }

    func transcribe(samples: [Float], dictionary: [String]) async throws -> String {
        guard #available(macOS 26.0, *) else {
            throw TranscriptionError.appleSpeechUnavailable
        }
        return try await transcribeOnSupportedOS(samples: samples, dictionary: dictionary)
    }

    func unload() async {
        isReady = false
        retainedWarmup = nil
        guard #available(macOS 26.0, *) else { return }
        if createdReservation, let reservedLocale {
            _ = await AssetInventory.release(reservedLocale: reservedLocale)
        }
        reservedLocale = nil
        createdReservation = false
    }

    @available(macOS 26.0, *)
    private func prepareOnSupportedOS(onStatus: @escaping (String) -> Void) async throws {
        isReady = false
        guard SpeechTranscriber.isAvailable else {
            throw TranscriptionError.appleSpeechUnavailable
        }

        onStatus("Apple Speech: finding English model…")
        guard let locale = await Self.englishLocale() else {
            throw TranscriptionError.appleSpeechLocaleUnsupported
        }

        let created = try await AssetInventory.reserve(locale: locale)
        reservedLocale = locale
        createdReservation = created

        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            onStatus("Apple Speech: downloading English model…")
            let progress = request.progress
            let ticker = Task { @MainActor in
                while !Task.isCancelled {
                    let pct = Int((progress.fractionCompleted * 100).rounded())
                    onStatus("Apple Speech: downloading English model (\(pct)%)…")
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            }
            do {
                try await request.downloadAndInstall()
            } catch {
                ticker.cancel()
                throw error
            }
            ticker.cancel()
        }

        onStatus("Apple Speech: preparing…")
        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: SpeechAnalyzer.Options(
                priority: .userInitiated,
                modelRetention: .processLifetime
            )
        )
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        try await analyzer.prepareToAnalyze(in: format)
        retainedWarmup = analyzer
        isReady = true
    }

    @available(macOS 26.0, *)
    private func transcribeOnSupportedOS(samples: [Float], dictionary: [String]) async throws -> String {
        guard isReady else { throw TranscriptionError.modelNotLoaded }
        retainedWarmup = nil
        guard SpeechTranscriber.isAvailable else {
            throw TranscriptionError.appleSpeechUnavailable
        }
        let locale: Locale
        if let reservedLocale {
            locale = reservedLocale
        } else if let resolved = await Self.englishLocale() {
            locale = resolved
        } else {
            throw TranscriptionError.appleSpeechLocaleUnsupported
        }

        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: SpeechAnalyzer.Options(
                priority: .userInitiated,
                modelRetention: .processLifetime
            )
        )

        if !dictionary.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings = [
                .general: Array(dictionary.prefix(100))
            ]
            try? await analyzer.setContext(context)
        }

        let url = try Self.writeTempAudio(samples: samples)
        defer { try? FileManager.default.removeItem(at: url) }

        let file = try AVAudioFile(forReading: url)
        async let collected = Self.collectTranscript(from: transcriber)
        do {
            let lastSampleTime = try await analyzer.analyzeSequence(from: file)
            if let lastSampleTime {
                try await analyzer.finalizeAndFinish(through: lastSampleTime)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            await analyzer.cancelAndFinishNow()
            throw error
        }
        return try await collected
    }

    @available(macOS 26.0, *)
    private static func englishLocale() async -> Locale? {
        if let enUS = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) {
            return enUS
        }
        if let en = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en")) {
            return en
        }
        return await SpeechTranscriber.supportedLocale(equivalentTo: .current)
    }

    @available(macOS 26.0, *)
    private static func collectTranscript(from transcriber: SpeechTranscriber) async throws -> String {
        var finals: [String] = []
        var all: [String] = []
        for try await result in transcriber.results {
            let text = String(result.text.characters)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            all.append(text)
            if result.isFinal {
                finals.append(text)
            }
        }
        return (finals.isEmpty ? all : finals).joined(separator: " ")
    }

    private static func writeTempAudio(samples: [Float]) throws -> URL {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            throw TranscriptionError.emptyAudio
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisperlocal-apple-speech-\(UUID().uuidString).caf")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else {
            throw TranscriptionError.emptyAudio
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            guard let base = src.baseAddress, let dest = buffer.floatChannelData?[0] else { return }
            dest.update(from: base, count: samples.count)
        }
        try file.write(from: buffer)
        return url
    }
}
