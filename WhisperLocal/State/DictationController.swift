import Foundation
import SwiftUI
import AppKit
import Combine

enum DictationPhase: Equatable {
    case idle
    /// Engine is up; waiting for the first HAL buffer (Bluetooth profile switch).
    case waitingForMic
    case recording
    case processing
    case polishing
    case inserting
    case success
    /// Soft notice after a successful paste (e.g. cleanup failed but text was inserted).
    case successNote(String)
    case error(String)

    var label: String {
        switch self {
        case .idle: return "Ready"
        case .waitingForMic: return "Waiting for mic…"
        case .recording: return "Listening…"
        case .processing: return "Transcribing…"
        case .polishing: return "Polishing…"
        case .inserting: return "Inserting…"
        case .success: return "Done"
        case .successNote(let note): return note
        case .error(let message): return message
        }
    }
}

@MainActor
final class DictationController: ObservableObject {
    static let shared = DictationController()

    @Published var phase: DictationPhase = .idle
    @Published var lastTranscript: String = ""
    @Published var lastPolished: String = ""
    @Published var lastStages: [String] = []
    @Published var lastCleanupNote: String?
    @Published var showSettings = false
    @Published var showOnboarding = false

    let settings = SettingsStore.shared
    let permissions = PermissionManager.shared
    let hotKey = HotKeyManager.shared
    let recorder = AudioRecorder()
    let transcription = TranscriptionService()
    let hud = RecordingHUDController()
    let log = DictationLogStore.shared

    private var cancelRequested = false
    private var cancellables = Set<AnyCancellable>()
    /// Frontmost app when dictation started. Passed to polish LLMs as formatting context.
    private var dictationTargetApp: TargetAppContext?
    private var recordingBeganAt: Date?
    /// MenuBarExtra onAppear also calls start(); only load speech once.
    private var didBootstrapSpeech = false
    /// Bumped at the start of each take so a late success-sleeper cannot idle a newer session.
    private var sessionGeneration = 0

    private init() {
        transcription.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
        permissions.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
        hotKey.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
        recorder.$isInputReady
            .receive(on: RunLoop.main)
            .sink { [weak self] ready in
                guard let self else { return }
                if ready, self.phase == .waitingForMic {
                    self.phase = .recording
                    self.hud.update(phase: .recording)
                } else if !ready, self.phase == .recording {
                    // Route change (Bluetooth profile switch) — wait for the new stream.
                    self.phase = .waitingForMic
                    self.hud.update(phase: .waitingForMic)
                }
            }
            .store(in: &cancellables)
    }

    func start() {
        hotKey.onPress = { [weak self] in
            Task { @MainActor in self?.handleHotkeyPress() }
        }
        hotKey.onRelease = { [weak self] in
            Task { @MainActor in self?.handleHotkeyRelease() }
        }
        hotKey.onCancel = { [weak self] in
            Task { @MainActor in self?.cancelRecording() }
        }
        hotKey.start()

        permissions.refresh()
        if !settings.hasCompletedOnboarding || !permissions.allGranted {
            showOnboarding = true
        }

        guard !didBootstrapSpeech else { return }
        didBootstrapSpeech = true
        Task {
            await transcription.ensureModel(named: settings.asrModel)
            prewarmOnDevicePolish()
            if permissions.microphoneGranted {
                recorder.prewarm()
            }
        }
    }

    func stop() {
        hotKey.stop()
        recorder.cancel()
        hud.hide()
    }

    // MARK: - Hotkey routing (hold vs tap)

    private func handleHotkeyPress() {
        // Ignore while processing/inserting (OpenWhispr pattern).
        if phase == .processing || phase == .polishing || phase == .inserting { return }

        switch hotKey.mode {
        case .hold:
            beginRecording()
        case .tap:
            if phase == .recording || phase == .waitingForMic {
                finishRecording()
            } else {
                beginRecording()
            }
        }
    }

    private func handleHotkeyRelease() {
        guard hotKey.mode == .hold else { return }
        finishRecording()
    }

    private func beginRecording() {
        guard phase == .idle || phase == .success || isErrorPhase else { return }
        cancelRequested = false
        permissions.refresh()

        guard permissions.microphoneGranted else {
            phase = .error("Microphone permission required")
            showOnboarding = true
            return
        }
        guard permissions.accessibilityTrusted else {
            phase = .error("Accessibility permission required")
            showOnboarding = true
            return
        }
        guard transcription.isReady else {
            phase = .error(transcription.statusMessage)
            hud.flashError(transcription.statusMessage)
            return
        }

        do {
            sessionGeneration += 1
            dictationTargetApp = TargetAppContext.captureFrontmost()
            try recorder.start()
            recordingBeganAt = Date()
            hotKey.markSessionActive(true)
            if recorder.isInputReady {
                phase = .recording
                hud.show(phase: .recording, levelPublisher: recorder)
            } else {
                phase = .waitingForMic
                hud.show(phase: .waitingForMic, levelPublisher: recorder)
            }
        } catch {
            phase = .error(error.localizedDescription)
            hotKey.markSessionActive(false)
            hud.flashError(error.localizedDescription)
        }
    }

    private func cancelRecording() {
        cancelRequested = true
        dictationTargetApp = nil
        recordingBeganAt = nil
        recorder.cancel()
        hotKey.markSessionActive(false)
        phase = .idle
        hud.hide()
    }

    private func finishRecording() {
        guard phase == .recording || phase == .waitingForMic else { return }
        let samples = recorder.stop()
        hotKey.markSessionActive(false)

        if cancelRequested {
            dictationTargetApp = nil
            recordingBeganAt = nil
            phase = .idle
            hud.hide()
            return
        }

        // Hold duration, not sample count — a cold mic can prepend preroll.
        let held = recordingBeganAt.map { Date().timeIntervalSince($0) } ?? 0
        recordingBeganAt = nil
        if held < 0.28 {
            dictationTargetApp = nil
            phase = .idle
            hud.hide()
            return
        }
        if Self.peakAbsolute(samples) < 0.003 {
            dictationTargetApp = nil
            phase = .error("No microphone input")
            hud.flashError("No microphone input")
            return
        }

        phase = .processing
        hud.update(phase: .processing)

        Task {
            await process(samples: samples)
        }
    }

    private func process(samples: [Float]) async {
        let audioSeconds = Double(samples.count) / 16_000
        let targetApp = dictationTargetApp?.promptLine
        dictationTargetApp = nil
        lastTranscript = ""
        lastPolished = ""
        lastStages = []
        lastCleanupNote = nil
        do {
            let extraTerms = settings.matchingAppDictionaryTerms(targetApp: targetApp)
            let raw = try await transcription.transcribe(samples: samples, extraDictionary: extraTerms)
            lastTranscript = raw

            guard !raw.isEmpty else {
                phase = .error("Heard nothing")
                hud.flashError("Heard nothing")
                log.append(DictationLogEntry(
                    id: UUID(),
                    date: Date(),
                    raw: "",
                    polished: "",
                    stages: [],
                    cleanupNote: nil,
                    appName: NSWorkspace.shared.frontmostApplication?.localizedName,
                    insertMethod: nil,
                    outcome: .heardNothing,
                    errorMessage: "Heard nothing",
                    audioSeconds: audioSeconds
                ))
                return
            }

            hud.update(phase: .processing)
            if settings.enableTextCleanup && (
                settings.shouldRunOnDevicePolish
                    || settings.hasUsableCloudPolish
            ) {
                phase = .polishing
                hud.update(phase: .polishing)
            }
            let result = await makePipeline().run(raw, targetApp: targetApp)
            var output = result.text
            if settings.insertTrailingSpace, !output.hasSuffix(" ") {
                output += " "
            }
            lastPolished = output
            lastStages = result.stages
            lastCleanupNote = result.cleanupNote

            // Always paste when we have text — even if LLM cleanup failed.
            phase = .inserting
            hud.update(phase: .inserting)

            let insertion = await TextInserter.shared.insert(output)
            if insertion.success {
                phase = .success
                if let app = insertion.appName {
                    lastStages.append("insert:\(insertion.method.rawValue)→\(app)")
                } else {
                    lastStages.append("insert:\(insertion.method.rawValue)")
                }
                log.append(DictationLogEntry(
                    id: UUID(),
                    date: Date(),
                    raw: raw,
                    polished: output,
                    stages: lastStages,
                    cleanupNote: result.cleanupNote,
                    appName: insertion.appName,
                    insertMethod: insertion.method.rawValue,
                    outcome: .success,
                    errorMessage: nil,
                    audioSeconds: audioSeconds
                ))
                let generation = sessionGeneration
                if result.cleanupFailed, let note = result.cleanupNote {
                    hud.flashSuccess(note: note)
                    try? await Task.sleep(nanoseconds: 1_600_000_000)
                } else {
                    hud.flashSuccess()
                    try? await Task.sleep(nanoseconds: 800_000_000)
                }
                guard generation == sessionGeneration else { return }
                phase = .idle
                hud.hide()
            } else {
                phase = .error("Could not insert text")
                let target = insertion.appName.map { " into \($0)" } ?? ""
                hud.flashError("Could not insert text\(target) — check Accessibility")
                log.append(DictationLogEntry(
                    id: UUID(),
                    date: Date(),
                    raw: raw,
                    polished: output,
                    stages: result.stages,
                    cleanupNote: result.cleanupNote,
                    appName: insertion.appName,
                    insertMethod: insertion.method.rawValue,
                    outcome: .insertFailed,
                    errorMessage: "Could not insert text\(target)",
                    audioSeconds: audioSeconds
                ))
            }
        } catch {
            phase = .error(error.localizedDescription)
            hud.flashError(error.localizedDescription)
            log.append(DictationLogEntry(
                id: UUID(),
                date: Date(),
                raw: lastTranscript,
                polished: lastPolished,
                stages: lastStages,
                cleanupNote: lastCleanupNote,
                appName: NSWorkspace.shared.frontmostApplication?.localizedName,
                insertMethod: nil,
                outcome: .error,
                errorMessage: error.localizedDescription,
                audioSeconds: audioSeconds
            ))
        }
    }

    private func makePipeline() -> PolishPipeline {
        var cloud: (any TextPolisher)?
        switch settings.cloudPolishProvider {
        case .none:
            cloud = nil
        case .openAI:
            // Only attach when a key exists — missing key would otherwise flag cleanupFailed every time.
            if !settings.openAIAPIKey.isEmpty {
                cloud = OpenAIPolisher(apiKey: settings.openAIAPIKey, model: settings.openAIModel)
            }
        case .anthropic:
            if !settings.anthropicAPIKey.isEmpty {
                cloud = AnthropicPolisher(apiKey: settings.anthropicAPIKey, model: settings.anthropicModel)
            }
        }

        return PolishPipeline(
            localLLM: onDevicePolisher(),
            cloud: cloud,
            useLocalLLM: settings.shouldRunOnDevicePolish,
            enableTextCleanup: settings.enableTextCleanup,
            dictionary: CleanupPrompt.mergedDictionary(settings.dictionaryWords),
            personalContext: settings.cleanupPersonalContext,
            recentDictations: recentDictationsForPolish()
        )
    }

    /// Request-time only. Never written into Settings → System prompt.
    private func recentDictationsForPolish() -> String {
        guard settings.shouldIncludeRecentPolishLogs else { return "" }
        let examples = log.recentPolishExamples(limit: settings.recentPolishLogCount)
        if settings.hasUsableCloudPolish {
            return CleanupPrompt.formatRecentDictations(
                examples,
                maxCharsPerSide: CleanupPrompt.cloudRecentMaxCharsPerSide
            )
        }
        return CleanupPrompt.formatRecentDictations(
            Array(examples.prefix(CleanupPrompt.onDeviceRecentExampleLimit)),
            maxCharsPerSide: CleanupPrompt.onDeviceRecentMaxCharsPerSide
        )
    }

    func prewarmOnDevicePolish() {
        guard settings.shouldUseLocalLLMPolish else { return }
        switch settings.localPolishEngine {
        case .none:
            break
        case .appleIntelligence:
            LocalLLMPolisher.shared.prewarm(
                personalContext: settings.cleanupPersonalContext,
                dictionary: settings.dictionaryWords
            )
        case .gemma4_e2b:
            GemmaMLXPolisher.shared.prewarm()
        }
    }

    private func onDevicePolisher() -> (any TextPolisher)? {
        switch settings.localPolishEngine {
        case .none:
            return nil
        case .appleIntelligence:
            return LocalLLMPolisher.shared
        case .gemma4_e2b:
            return GemmaMLXPolisher.shared
        }
    }

    private var isErrorPhase: Bool {
        if case .error = phase { return true }
        return false
    }

    private static func peakAbsolute(_ samples: [Float]) -> Float {
        var peak: Float = 0
        for sample in samples {
            let magnitude = abs(sample)
            if magnitude > peak { peak = magnitude }
        }
        return peak
    }

    var readyStatusLine: String {
        let hotkey: String
        switch hotKey.mode {
        case .hold:
            hotkey = "hold \(hotKey.selectedKey.displayName)"
        case .tap:
            hotkey = "tap \(hotKey.selectedKey.displayName)"
        }
        if transcription.isReady, let model = transcription.loadedModel {
            return "\(model.shortName) · \(hotkey)"
        }
        return transcription.statusMessage
    }
}
