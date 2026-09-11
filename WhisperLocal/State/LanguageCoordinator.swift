import Combine
import Foundation
import os

/// Decides what language a take runs in, and warms the speech model ahead of it.
///
/// Every path out of here that is not certain returns English. The setting is off
/// by default, the keyboard has to declare exactly one language, and both the
/// speech model and the polish model have to be able to serve it *right now*.
/// Anything less and the take behaves exactly as it does today.
@MainActor
final class LanguageCoordinator: ObservableObject {
    static let shared = LanguageCoordinator()

    /// What the next take would use. Drives the HUD badge and the Settings line.
    @Published private(set) var resolved: SpokenLanguage = .english
    /// Set when the keyboard asks for a language the pipeline cannot serve, so the
    /// reason a take stayed English is visible rather than mysterious.
    @Published private(set) var unavailable: String?

    private let settings = SettingsStore.shared
    private let logger = Logger(subsystem: "com.usingcolor.WhisperLocal", category: "language")
    private var observer: NSObjectProtocol?
    private var warmTask: Task<Void, Never>?
    private var subscriptions: Set<AnyCancellable> = []

    private init() {}

    func start() {
        guard observer == nil else { return }
        // Input-source changes come over the distributed centre, not the local one.
        observer = DistributedNotificationCenter.default().addObserver(
            forName: KeyboardLanguage.changedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.warmIfNeeded() }
        }
        // Warming used to happen only on a keyboard *change*. Turning the switch on
        // while already on the Korean keyboard, or launching that way, never
        // warmed anything — every take stayed English until you switched away and
        // back. The switch and launch are both moments to warm.
        settings.$followKeyboardLanguage
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.warmIfNeeded() }
            .store(in: &subscriptions)
        // Keep the Settings readout honest while a download runs.
        let transcription = DictationController.shared.transcription
        transcription.$languageDownloadStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &subscriptions)
        // Warm — not just refresh — when a speech model finishes loading. This
        // runs before the launch-time English load completes, so the warm below
        // finds no model yet and returns; without this nothing ever retried, and
        // launching on the Korean keyboard stayed English for good.
        transcription.$loadedModel
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.warmIfNeeded() }
            .store(in: &subscriptions)
        warmIfNeeded()
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
        guard let wanted = requestedLanguage() else { return .english }
        guard polishCanServe(wanted) else {
            note("\(wanted.englishName) needs a polish model that reads it")
            return .english
        }
        guard transcription.isReadyForLanguage(wanted) else {
            note("\(wanted.englishName) speech model is not ready")
            return .english
        }
        unavailable = nil
        return wanted
    }

    /// What the keyboard asks for, before asking whether it can be served.
    /// Nil when the feature is off, the keyboard says nothing, or it says English.
    func requestedLanguage() -> SpokenLanguage? {
        guard settings.followKeyboardLanguage else { return nil }
        guard let keyboard = KeyboardLanguage.current() else { return nil }
        return keyboard.isEnglish ? nil : keyboard
    }

    private func warmIfNeeded() {
        refresh()
        guard let wanted = requestedLanguage() else { return }
        // Warm here rather than at take time. Downloading a speech model with the
        // speaker mid-sentence is the failure this whole path exists to avoid.
        warmTask?.cancel()
        warmTask = Task { [weak self] in
            await DictationController.shared.transcription.prepareLanguage(wanted)
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    private func refresh() {
        guard let wanted = requestedLanguage() else {
            resolved = .english
            unavailable = nil
            return
        }
        let transcription = DictationController.shared.transcription
        if !polishCanServe(wanted) {
            resolved = .english
            unavailable = "\(wanted.englishName) needs a polish model that reads it — takes stay in English"
        } else if transcription.isReadyForLanguage(wanted) {
            resolved = wanted
            unavailable = nil
        } else if let download = transcription.languageDownloadStatus {
            resolved = .english
            unavailable = "\(download) Takes stay in English until it finishes."
        } else if let model = transcription.loadedModel,
                  !LanguageSupport.speechModelCanServe(wanted, model: model) {
            resolved = .english
            unavailable = "\(model.shortName) is English-only — pick Apple Speech or Whisper Large v3 Turbo for \(wanted.englishName)"
        } else {
            resolved = .english
            unavailable = "\(wanted.englishName) speech model is not ready — takes stay in English"
        }
    }

    private func polishCanServe(_ language: SpokenLanguage) -> Bool {
        LanguageSupport.polishCanServe(
            language,
            cloud: settings.cloudPolishProvider,
            local: settings.localPolishEngine
        )
    }

    private func note(_ message: String) {
        unavailable = message
        logger.info("staying in English: \(message, privacy: .public)")
    }
}
