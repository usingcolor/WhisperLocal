import Combine
import Foundation
import os
#if canImport(Speech)
import Speech
#endif

/// Decides what language a take runs in, and warms speech models ahead of it.
///
/// Dev-only, enforced here and not just by hiding the Settings section: a Release
/// build returns English whatever the stored preferences say, so a hand-written
/// `defaults write` cannot turn this on where it has not been tried.
///
/// The rule itself lives in `LanguageResolution`: a followed keyboard's language,
/// else the preferred language, else English — each only if it can be served
/// right now.
@MainActor
final class LanguageCoordinator: ObservableObject {
    static let shared = LanguageCoordinator()

    /// What the next take would use. Drives the HUD badge and the Settings line.
    @Published private(set) var resolved: SpokenLanguage = .english
    /// Why the next take is not in the language that was asked for, when it isn't.
    @Published private(set) var unavailable: String?
    /// Enabled keyboards that name one language — the only ones that can be followed.
    @Published private(set) var keyboards: [SpokenLanguage] = []
    /// Languages the dictation-language picker offers.
    @Published private(set) var availableLanguages: [SpokenLanguage] = LanguageCoordinator.fallbackLanguages

    private let settings = SettingsStore.shared
    private let logger = Logger(subsystem: "com.usingcolor.WhisperLocal", category: "language")
    private var observer: NSObjectProtocol?
    private var warmTask: Task<Void, Never>?
    private var subscriptions: Set<AnyCancellable> = []

    private init() {}

    static var isEnabled: Bool { AppIdentity.isDevBuild }

    func start() {
        guard Self.isEnabled, observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: KeyboardLanguage.changedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.keyboards = KeyboardLanguage.enabledSingleLanguageKeyboards()
                self?.refresh()
            }
        }
        // Either setting changing can add a language to warm. @Published emits
        // before the value lands; receiving on the next main-queue turn reads the
        // new one.
        settings.$preferredLanguageCode.dropFirst().map { _ in () }
            .merge(with: settings.$followedKeyboardLanguages.dropFirst().map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.warm() }
            .store(in: &subscriptions)
        let transcription = DictationController.shared.transcription
        transcription.$languageDownloadStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &subscriptions)
        // The launch-time warm below runs before the English model has loaded and
        // finds nothing to warm against; this is the retry.
        transcription.$loadedModel
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.warm() }
            .store(in: &subscriptions)
        keyboards = KeyboardLanguage.enabledSingleLanguageKeyboards()
        Task { await loadAvailableLanguages() }
        warm()
    }

    func stop() {
        if let observer {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        observer = nil
        warmTask?.cancel()
        warmTask = nil
    }

    /// The language for a take about to start. Called at the same moment as
    /// `TargetAppContext.captureFrontmost()` — both describe the world when the
    /// speaker pressed the key, not when they let go.
    func languageForTake(transcription: TranscriptionService) -> SpokenLanguage {
        guard Self.isEnabled else { return .english }
        let (language, reason) = evaluate(transcription: transcription)
        unavailable = reason
        if let reason {
            logger.info("take falls back to \(language.code, privacy: .public): \(reason, privacy: .public)")
        }
        return language
    }

    // MARK: - Resolution

    private func wanted() -> SpokenLanguage {
        LanguageResolution.wanted(
            preferred: settings.preferredLanguage,
            keyboard: KeyboardLanguage.current(),
            followed: Set(settings.followedKeyboardLanguages)
        )
    }

    private func evaluate(transcription: TranscriptionService) -> (SpokenLanguage, String?) {
        let wanted = wanted()
        let preferred = settings.preferredLanguage
        let language = LanguageResolution.resolve(
            wanted: wanted,
            preferred: preferred,
            canServe: { self.canServe($0, transcription: transcription) }
        )
        guard language != wanted else { return (language, nil) }
        return (language, reason(wanted, transcription: transcription))
    }

    private func canServe(_ language: SpokenLanguage, transcription: TranscriptionService) -> Bool {
        polishCanServe(language) && transcription.isReadyForLanguage(language)
    }

    private func reason(_ language: SpokenLanguage, transcription: TranscriptionService) -> String {
        let name = language.englishName
        if !polishCanServe(language) {
            return "\(name) needs a polish model that reads it"
        }
        if let download = transcription.languageDownloadStatus {
            return download
        }
        if let model = transcription.loadedModel,
           !LanguageSupport.speechModelCanServe(language, model: model) {
            return "\(model.shortName) is English-only — pick Apple Speech or Whisper Large v3 Turbo for \(name)"
        }
        return "\(name) speech model is not ready yet"
    }

    private func refresh() {
        guard Self.isEnabled else { return }
        let (language, reason) = evaluate(transcription: DictationController.shared.transcription)
        resolved = language
        unavailable = reason
    }

    // MARK: - Warming

    /// Every language the user could be about to dictate in: the preferred one
    /// and each followed keyboard's. Warming all of them — not only the keyboard
    /// that is active — is what keeps the first take after a switch from landing
    /// before the model is ready. That gap cost a "Heard nothing" in testing.
    private func languagesToWarm() -> [SpokenLanguage] {
        var codes = [settings.preferredLanguageCode] + settings.followedKeyboardLanguages
        var seen = Set<String>()
        codes = codes.filter { seen.insert(SpokenLanguage(code: $0).base).inserted }
        return codes.map(SpokenLanguage.init(code:)).filter { !$0.isEnglish }
    }

    private func warm() {
        refresh()
        let languages = languagesToWarm()
        guard !languages.isEmpty else { return }
        warmTask?.cancel()
        warmTask = Task { [weak self] in
            for language in languages {
                guard !Task.isCancelled else { return }
                await DictationController.shared.transcription.prepareLanguage(language)
                self?.refresh()
            }
        }
    }

    private func polishCanServe(_ language: SpokenLanguage) -> Bool {
        LanguageSupport.polishCanServe(
            language,
            cloud: settings.cloudPolishProvider,
            local: settings.localPolishEngine
        )
    }

    // MARK: - Picker contents

    /// Used until Apple Speech answers, and on Macs without it.
    static let fallbackLanguages: [SpokenLanguage] =
        ["en", "ko", "ja", "zh", "de", "es", "fr", "it", "pt"].map(SpokenLanguage.init(code:))

    /// What Apple Speech can transcribe here, one entry per language, English
    /// first. Whisper Large v3 Turbo covers more, but Apple Speech is the default
    /// engine and the list should not offer what the default cannot do.
    private func loadAvailableLanguages() async {
        #if canImport(Speech)
        guard #available(macOS 26.0, *) else { return }
        let locales = await SpeechTranscriber.supportedLocales
        var seen = Set<String>()
        var languages: [SpokenLanguage] = []
        for locale in locales {
            guard let code = locale.language.languageCode?.identifier,
                  seen.insert(code).inserted else { continue }
            languages.append(SpokenLanguage(code: code))
        }
        guard !languages.isEmpty else { return }
        availableLanguages = languages.sorted {
            if $0.isEnglish != $1.isEnglish { return $0.isEnglish }
            return $0.englishName < $1.englishName
        }
        #endif
    }
}
