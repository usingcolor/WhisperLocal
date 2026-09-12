import AVFoundation
import Foundation
import os
import Speech

private let appleSpeechLogger = Logger(subsystem: "com.usingcolor.WhisperLocal", category: "speech")
private let appleSpeechTempPrefix = "whisperlocal-apple-speech-"

/// On-device Apple Speech (`SpeechAnalyzer` + `SpeechTranscriber`, macOS 26+).
/// Audio stays on this Mac.
///
/// The locale is always stated, never inherited. Falling back to the system locale
/// would hand a Korean Mac a Korean transcriber for a user who dictates English,
/// so an unknown or unserviceable language resolves to English instead.
@MainActor
final class AppleSpeechASR {
    static let shared = AppleSpeechASR()

    private(set) var isReady = false
    private var reservedLocale: Locale?
    private var createdReservation = false
    /// Languages other than English whose assets are installed and reserved. Held
    /// *alongside* English, never instead of it: the system allows several
    /// reservations at once (5 on this hardware), and the first version released
    /// English to make room — after which an English take was transcribed with
    /// the Korean model, and English takes failed while Korean downloaded.
    private(set) var installedLanguages: [SpokenLanguage: Locale] = [:]
    private var extraReservations: Set<Locale> = []
    /// Launch, the English model finishing, and a keyboard change can all ask for
    /// the same language within a second of each other. One download is enough —
    /// and a second caller waits for it rather than returning at once, which made
    /// it report the language ready while the first was still downloading.
    private var installs: [SpokenLanguage: Task<Void, Error>] = [:]
    /// Holds the prewarm analyzer so `processLifetime` models stay resident.
    private var retainedWarmup: Any?

    nonisolated static var isAvailable: Bool {
        if #available(macOS 26.0, *) {
            return SpeechTranscriber.isAvailable
        }
        return false
    }

    nonisolated static var availabilityMessage: String {
        if #available(macOS 26.0, *) {
            if SpeechTranscriber.isAvailable {
                return "On-device Apple SpeechTranscriber. English. The system may download a shared transcription model on first use."
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

    /// True when this language's assets are installed and reserved, so a take can
    /// use it without stalling on a download after the speaker has already talked.
    func isPrepared(for language: SpokenLanguage) -> Bool {
        guard isReady else { return false }
        return language.isEnglish || installedLanguages[language] != nil
    }

    /// Install and reserve a second language next to English. Touches nothing an
    /// English take depends on — `isReady`, the English reservation, and the warm
    /// analyzer all stay as they are while this downloads.
    func installLanguage(
        _ language: SpokenLanguage,
        onStatus: @escaping (String) -> Void
    ) async throws {
        guard !language.isEnglish, installedLanguages[language] == nil else { return }
        if let running = installs[language] {
            try await running.value
            return
        }
        guard #available(macOS 26.0, *) else {
            throw TranscriptionError.appleSpeechUnavailable
        }
        let task = Task { @MainActor in
            try await self.installOnSupportedOS(language, onStatus: onStatus)
        }
        installs[language] = task
        defer { installs[language] = nil }
        try await task.value
    }

    /// Release every non-English reservation the app no longer needs.
    ///
    /// Reservations outlive the app — they are how the system knows not to purge a
    /// model — and nothing used to give one back. A language stopped being
    /// followed kept its slot, and the system allows only a handful (5 here), so
    /// the next new language would eventually fail. Covers reservations made on
    /// earlier launches too, which this session never recorded.
    func releaseLanguages(except keep: Set<String>) async {
        guard #available(macOS 26.0, *) else { return }
        for locale in await AssetInventory.reservedLocales {
            guard let base = locale.language.languageCode?.identifier.lowercased(),
                  base != "en", !keep.contains(base) else { continue }
            _ = await AssetInventory.release(reservedLocale: locale)
            extraReservations.remove(locale)
            installedLanguages = installedLanguages.filter { $0.value != locale }
            appleSpeechLogger.info("released \(locale.identifier, privacy: .public)")
        }
    }

    func transcribe(
        samples: [Float],
        dictionary: [String],
        language: SpokenLanguage = .english
    ) async throws -> String {
        guard #available(macOS 26.0, *) else {
            throw TranscriptionError.appleSpeechUnavailable
        }
        return try await transcribeOnSupportedOS(
            samples: samples, dictionary: dictionary, language: language
        )
    }

    func unload() async {
        isReady = false
        retainedWarmup = nil
        guard #available(macOS 26.0, *) else { return }
        if createdReservation, let reservedLocale {
            _ = await AssetInventory.release(reservedLocale: reservedLocale)
        }
        for locale in extraReservations {
            _ = await AssetInventory.release(reservedLocale: locale)
        }
        reservedLocale = nil
        createdReservation = false
        extraReservations = []
        installedLanguages = [:]
    }

    @available(macOS 26.0, *)
    private func prepareOnSupportedOS(onStatus: @escaping (String) -> Void) async throws {
        Self.sweepStaleTempAudio()
        isReady = false
        guard SpeechTranscriber.isAvailable else {
            throw TranscriptionError.appleSpeechUnavailable
        }

        let label = "English"
        onStatus("Apple Speech: finding English model…")
        guard let locale = await Self.locale(for: .english) else {
            throw TranscriptionError.appleSpeechLocaleUnsupported
        }

        let created = try await AssetInventory.reserve(locale: locale)
        reservedLocale = locale
        createdReservation = created

        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            onStatus("Apple Speech: downloading \(label) model…")
            let progress = request.progress
            let ticker = Task { @MainActor in
                while !Task.isCancelled {
                    let pct = Int((progress.fractionCompleted * 100).rounded())
                    onStatus("Apple Speech: downloading \(label) model (\(pct)%)…")
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            }
            do {
                try await Task.detached {
                    try await request.downloadAndInstall()
                }.value
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
    private func installOnSupportedOS(
        _ language: SpokenLanguage,
        onStatus: @escaping (String) -> Void
    ) async throws {
        let label = language.englishName
        guard let locale = await Self.locale(for: language) else {
            throw TranscriptionError.appleSpeechLocaleUnsupported
        }
        if !(await AssetInventory.reservedLocales.contains(locale)) {
            guard await AssetInventory.reservedLocales.count < AssetInventory.maximumReservedLocales else {
                appleSpeechLogger.error("no reservation slot left for \(locale.identifier, privacy: .public)")
                throw TranscriptionError.appleSpeechReservationsFull
            }
            if try await AssetInventory.reserve(locale: locale) {
                extraReservations.insert(locale)
            }
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            onStatus("Downloading the \(label) transcription model…")
            let progress = request.progress
            let ticker = Task { @MainActor in
                while !Task.isCancelled {
                    let pct = Int((progress.fractionCompleted * 100).rounded())
                    onStatus("Downloading the \(label) transcription model (\(pct)%)…")
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            }
            defer { ticker.cancel() }
            try await Task.detached { try await request.downloadAndInstall() }.value
        }
        installedLanguages[language] = locale
        appleSpeechLogger.info("installed \(locale.identifier, privacy: .public) alongside English")
    }

    @available(macOS 26.0, *)
    private func transcribeOnSupportedOS(
        samples: [Float],
        dictionary: [String],
        language: SpokenLanguage
    ) async throws -> String {
        guard isReady else { throw TranscriptionError.modelNotLoaded }
        retainedWarmup = nil
        guard SpeechTranscriber.isAvailable else {
            throw TranscriptionError.appleSpeechUnavailable
        }
        // Exactly the language asked for, or nothing. This used to fall back to
        // "whatever is reserved", which after a Korean warm-up meant an English
        // take ran through the Korean model. The caller checks `isPrepared` before
        // recording, so a miss here is a bug to surface, not a case to paper over.
        var english = reservedLocale
        if english == nil, language.isEnglish {
            english = await Self.locale(for: .english)
        }
        guard let locale = SpeechLocaleChoice.pick(
            for: language, english: english, installed: installedLanguages
        ) else {
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

        let url = try Self.writeTempAudio(samples: Self.padLeadingSilence(samples))
        defer { Self.removeTempAudio(url) }

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

    /// Resolve a stated language to a locale the transcriber supports. Never reads
    /// the system locale: the language always comes from the caller, so a Korean
    /// Mac cannot silently hand a Korean transcriber to an English dictation.
    @available(macOS 26.0, *)
    static func locale(for language: SpokenLanguage) async -> Locale? {
        if language.isEnglish { return await englishLocale() }
        if let exact = await SpeechTranscriber.supportedLocale(
            equivalentTo: Locale(identifier: language.code)
        ) {
            return exact
        }
        return await SpeechTranscriber.supportedLocale(
            equivalentTo: Locale(identifier: language.base)
        )
    }

    @available(macOS 26.0, *)
    private static func englishLocale() async -> Locale? {
        if let enUS = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) {
            return enUS
        }
        if let en = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en")) {
            return en
        }
        return nil
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

    /// Apple Speech often drops the first phonemes when a clip starts on speech.
    /// Keep existing quiet lead-in; otherwise prepend 200 ms of silence.
    private static func padLeadingSilence(_ samples: [Float]) -> [Float] {
        let padCount = 3_200
        let probeCount = min(samples.count, 1_600)
        guard probeCount > 0 else { return samples }
        var peak: Float = 0
        for index in 0..<probeCount {
            peak = max(peak, abs(samples[index]))
        }
        if peak < 0.008 { return samples }
        var padded = [Float](repeating: 0, count: padCount + samples.count)
        for index in 0..<samples.count {
            padded[padCount + index] = samples[index]
        }
        return padded
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
            .appendingPathComponent("\(appleSpeechTempPrefix)\(UUID().uuidString).caf")
        // A full or read-only disk surfaces here as a bare OSStatus, which tells the
        // user nothing they can act on. An hour of audio is ~220 MB of scratch file.
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forWriting: url, settings: format.settings)
        } catch {
            appleSpeechLogger.error("Temp audio write failed: \(error.localizedDescription, privacy: .public)")
            throw TranscriptionError.audioScratchFailed
        }
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
        do {
            try file.write(from: buffer)
        } catch {
            appleSpeechLogger.error("Temp audio write failed: \(error.localizedDescription, privacy: .public)")
            Self.removeTempAudio(url)
            throw TranscriptionError.audioScratchFailed
        }
        Self.protectTempAudio(url)
        return url
    }

    /// Crash leftovers from a previous take. Safe to call at launch.
    nonisolated static func sweepStaleTempAudio() {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
        guard let items = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        for url in items where url.lastPathComponent.hasPrefix(appleSpeechTempPrefix) {
            removeTempAudio(url)
        }
    }

    private static func protectTempAudio(_ url: URL) {
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        } catch {
            appleSpeechLogger.error("Could not restrict temp speech-file permissions: \(error.localizedDescription, privacy: .public)")
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do {
            var mutable = url
            try mutable.setResourceValues(values)
        } catch {
            appleSpeechLogger.error("Could not exclude temp speech file from backup: \(error.localizedDescription, privacy: .public)")
        }
    }

    private nonisolated static func removeTempAudio(_ url: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        do {
            try fm.removeItem(at: url)
        } catch {
            appleSpeechLogger.error("Could not delete temp speech audio: \(error.localizedDescription, privacy: .public)")
        }
    }
}
