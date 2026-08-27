import Foundation
import SwiftUI
import AppKit
import Combine

enum DictationPhase: Equatable {
    case idle
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

    private init() {
        transcription.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
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

        Task {
            await transcription.ensureModel(named: settings.asrModel)
            prewarmOnDevicePolish()
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
            if phase == .recording {
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
            try recorder.start()
            phase = .recording
            hotKey.markSessionActive(true)
            hud.show(phase: .recording, levelPublisher: recorder)
        } catch {
            phase = .error(error.localizedDescription)
            hotKey.markSessionActive(false)
            hud.flashError(error.localizedDescription)
        }
    }

    private func cancelRecording() {
        cancelRequested = true
        recorder.cancel()
        hotKey.markSessionActive(false)
        phase = .idle
        hud.hide()
    }

    private func finishRecording() {
        guard phase == .recording else { return }
        let samples = recorder.stop()
        hotKey.markSessionActive(false)

        if cancelRequested {
            phase = .idle
            hud.hide()
            return
        }

        // Ignore accidental taps / empty holds
        if samples.count < Int(16_000 * 0.25) {
            phase = .idle
            hud.hide()
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
        do {
            let raw = try await transcription.transcribe(samples: samples)
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
            let result = await makePipeline().run(raw)
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
                if result.cleanupFailed, let note = result.cleanupNote {
                    hud.flashSuccess(note: note)
                    try? await Task.sleep(nanoseconds: 1_600_000_000)
                } else {
                    hud.flashSuccess()
                    try? await Task.sleep(nanoseconds: 800_000_000)
                }
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
            heuristic: HeuristicPolisher(),
            localLLM: onDevicePolisher(),
            cloud: cloud,
            useLocalLLM: settings.shouldRunOnDevicePolish,
            enableTextCleanup: settings.enableTextCleanup,
            enableHeuristicCleanup: settings.enableHeuristicCleanup,
            dictionary: CleanupPrompt.mergedDictionary(settings.dictionaryWords),
            personalContext: settings.cleanupPersonalContext
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

    var readyStatusLine: String {
        let hotkey: String
        switch hotKey.mode {
        case .hold:
            hotkey = "hold \(hotKey.selectedKey.displayName)"
        case .tap:
            hotkey = "tap \(hotKey.selectedKey.displayName)"
        }
        if transcription.isReady {
            return "\(transcription.statusMessage) · \(hotkey)"
        }
        return transcription.statusMessage
    }
}
