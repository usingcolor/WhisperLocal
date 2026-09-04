import Foundation
import SwiftUI
import AppKit
import Combine
import os

enum DictationPhase: Equatable {
    case idle
    /// Engine is up; waiting for the first HAL buffer (Bluetooth profile switch).
    case waitingForMic
    case recording
    case processing
    /// Shift+hotkey: storing a spoken session context, not pasting.
    case settingContext
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
        case .settingContext: return "Transcribing context…"
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
    /// Spoken polish context for this launch. Never written to disk.
    @Published private(set) var sessionContext: SessionContext?
    /// Frontmost app when dictation started. Passed to polish LLMs as formatting context.
    private var dictationTargetApp: TargetAppContext?
    private var recordingBeganAt: Date?
    /// Watches the take against TakeLimits and auto-finishes at the ceiling.
    private var takeLimitTask: Task<Void, Never>?
    /// True when this take was stopped by the limit rather than by the user.
    private var hitTakeLimit = false
    /// Consecutive watch ticks that saw the hotkey up while we thought it was held.
    private var missedReleaseTicks = 0
    private let logger = Logger(subsystem: "com.usingcolor.WhisperLocal", category: "dictation")
    /// MenuBarExtra onAppear also calls start(); only load speech once.
    private var didBootstrapSpeech = false
    /// Bumped at the start of each take so a late success-sleeper cannot idle a newer session.
    private var sessionGeneration = 0
    /// Shift switch for this take (context vs paste). Never inferred from transcript content. Snapshot at finish.
    @Published private(set) var isIntentTake = false

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
        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
        GemmaMLXPolisher.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
        CloudModelCatalog.shared.objectWillChange
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
            guard let self else { return }
            let intent = self.hotKey.intentModifierHeld
            Task { @MainActor in self.handleHotkeyPress(intentModifierHeld: intent) }
        }
        hotKey.onRelease = { [weak self] in
            Task { @MainActor in self?.handleHotkeyRelease() }
        }
        hotKey.onCancel = { [weak self] in
            Task { @MainActor in self?.cancelRecording() }
        }
        hotKey.onIntentModifierChanged = { [weak self] intent in
            self?.setRecordingIntent(intent)
        }
        hotKey.start()

        permissions.refresh()
        if !settings.hasCompletedOnboarding || !permissions.allGranted {
            showOnboarding = true
        }

        NetworkReachability.shared.start()

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

    private func handleHotkeyPress(intentModifierHeld: Bool) {
        // Ignore while processing/inserting (OpenWhispr pattern).
        if phase == .processing || phase == .settingContext || phase == .polishing || phase == .inserting {
            return
        }

        switch hotKey.mode {
        case .hold:
            beginRecording(intentModifierHeld: intentModifierHeld)
        case .tap:
            if phase == .recording || phase == .waitingForMic {
                finishRecording()
            } else {
                beginRecording(intentModifierHeld: intentModifierHeld)
            }
        }
    }

    private func handleHotkeyRelease() {
        guard hotKey.mode == .hold else { return }
        finishRecording()
    }

    private func beginRecording(intentModifierHeld: Bool) {
        guard phase == .idle || phase == .success || isErrorPhase else { return }
        cancelRequested = false
        isIntentTake = settings.enableSessionContext && settings.enableTextCleanup && intentModifierHeld
        permissions.refresh()

        guard permissions.microphoneGranted else {
            isIntentTake = false
            hotKey.markSessionActive(false)
            phase = .error("Microphone permission required")
            showOnboarding = true
            return
        }
        guard permissions.accessibilityTrusted else {
            isIntentTake = false
            hotKey.markSessionActive(false)
            phase = .error("Accessibility permission required")
            showOnboarding = true
            return
        }
        guard transcription.isReady else {
            isIntentTake = false
            hotKey.markSessionActive(false)
            phase = .error(transcription.statusMessage)
            hud.flashError(transcription.statusMessage)
            return
        }

        do {
            sessionGeneration += 1
            dictationTargetApp = TargetAppContext.captureFrontmost()
            try recorder.start()
            recordingBeganAt = Date()
            hitTakeLimit = false
            hotKey.markSessionActive(true)
            startTakeLimitWatch()
            if recorder.isInputReady {
                phase = .recording
                hud.show(phase: .recording, levelPublisher: recorder, contextCapture: isIntentTake)
            } else {
                phase = .waitingForMic
                hud.show(phase: .waitingForMic, levelPublisher: recorder, contextCapture: isIntentTake)
            }
        } catch {
            isIntentTake = false
            phase = .error(error.localizedDescription)
            hotKey.markSessionActive(false)
            hud.flashError(error.localizedDescription)
        }
    }

    /// A take had no ceiling at all: the buffer grew until the key came up, and a
    /// failure anywhere downstream then cost every word of it. The limit stops the
    /// take and transcribes what it has — it never throws the audio away.
    private func startTakeLimitWatch() {
        takeLimitTask?.cancel()
        takeLimitTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled, let self else { return }
                guard self.phase == .recording || self.phase == .waitingForMic,
                      let began = self.recordingBeganAt else { return }

                // Recover from a key-up we never saw. Confirmed over consecutive
                // ticks so a momentary misread cannot truncate a live take; a
                // genuinely stuck session lasts forever, so the extra second costs
                // nothing.
                // The mic died mid-take (device unplugged, interface removed). Keep
                // what was captured rather than recording silence to the ceiling.
                if self.recorder.inputFailed {
                    self.logger.error("Input graph failed mid-take — finishing with what was captured")
                    self.finishRecording()
                    return
                }

                if self.hotKey.missedHotkeyRelease {
                    self.missedReleaseTicks += 1
                    if self.missedReleaseTicks >= 3 {
                        self.logger.error("Hotkey release was missed — finishing the stuck take")
                        self.missedReleaseTicks = 0
                        self.finishRecording()
                        return
                    }
                } else {
                    self.missedReleaseTicks = 0
                }

                let elapsed = Date().timeIntervalSince(began)
                if TakeLimits.shouldAutoStop(elapsed: elapsed) {
                    self.hitTakeLimit = true
                    self.finishRecording()
                    return
                }
                self.hud.setDetail(TakeLimits.countdownLabel(elapsed: elapsed), warning: true)
            }
        }
    }

    private func stopTakeLimitWatch() {
        takeLimitTask?.cancel()
        takeLimitTask = nil
        missedReleaseTicks = 0
        hud.setDetail(nil)
    }

    private func setRecordingIntent(_ intent: Bool) {
        guard phase == .recording || phase == .waitingForMic else { return }
        isIntentTake = settings.enableSessionContext && settings.enableTextCleanup && intent
        hud.setContextCapture(isIntentTake)
    }

    private func cancelRecording() {
        stopTakeLimitWatch()
        cancelRequested = true
        isIntentTake = false
        dictationTargetApp = nil
        recordingBeganAt = nil
        recorder.cancel()
        hotKey.markSessionActive(false)
        phase = .idle
        hud.hide()
    }

    private func finishRecording() {
        guard phase == .recording || phase == .waitingForMic else { return }
        stopTakeLimitWatch()
        // Paste vs context is the Shift switch at the end of the take, not the first press.
        setRecordingIntent(hotKey.intentModifierHeld)
        let samples = recorder.stop()
        hotKey.markSessionActive(false)

        if cancelRequested {
            dictationTargetApp = nil
            isIntentTake = false
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
            isIntentTake = false
            phase = .idle
            hud.hide()
            return
        }
        if Self.peakAbsolute(samples) < 0.003 {
            dictationTargetApp = nil
            isIntentTake = false
            phase = .error("No microphone input")
            hud.flashError("No microphone input")
            // Logged so this failure class stops being invisible: it was the one
            // path that ended a take with nothing written anywhere.
            log.append(DictationLogEntry(
                id: UUID(),
                date: Date(),
                raw: "",
                polished: "",
                stages: [],
                cleanupNote: nil,
                appName: NSWorkspace.shared.frontmostApplication?.localizedName,
                insertMethod: nil,
                outcome: .error,
                errorMessage: "No microphone input",
                audioSeconds: Double(samples.count) / TranscriptionService.sampleRate
            ))
            return
        }

        phase = isIntentTake ? .settingContext : .processing
        hud.update(phase: phase)
        if hitTakeLimit {
            // Said here rather than at the end: the take vanishing mid-sentence
            // needs explaining now, not after the paste lands.
            hud.setDetail(TakeLimits.limitNote(seconds: TakeLimits.maxSeconds), warning: true)
        }

        Task {
            await process(samples: samples)
        }
    }

    private func process(samples: [Float]) async {
        let audioSeconds = Double(samples.count) / 16_000
        let targetApp = dictationTargetApp?.promptLine
        // Kept whole, not just its prompt line: insertion needs the process.
        let insertTarget = dictationTargetApp
        let intentTake = isIntentTake
        // Snapshot: chunk progress overwrites the HUD detail within a second, so
        // the reason the take ended has to survive to the completion note.
        let limited = hitTakeLimit
        dictationTargetApp = nil
        isIntentTake = false
        hitTakeLimit = false
        lastTranscript = ""
        lastPolished = ""
        lastStages = []
        lastCleanupNote = nil
        do {
            let extraTerms = settings.matchingAppDictionaryTerms(targetApp: targetApp)
            let raw = try await transcription.transcribe(
                samples: samples,
                extraDictionary: extraTerms
            ) { [weak self] chunk, total in
                self?.hud.setDetail("part \(chunk) of \(total)")
            }
            hud.setDetail(nil)
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

            if intentTake {
                await storeSessionContext(from: raw)
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
            let result = await makePipeline().runChunked(raw, targetApp: targetApp) { [weak self] piece, total in
                self?.hud.setDetail("part \(piece) of \(total)")
            }
            hud.setDetail(nil)
            var output = result.text
            if settings.insertTrailingSpace, !output.hasSuffix(" ") {
                output += " "
            }
            lastPolished = output
            lastStages = result.stages
            lastCleanupNote = result.cleanupNote
            rememberSessionContextUse(relevant: result.contextRelevant)

            // Always paste when we have text — even if LLM cleanup failed.
            phase = .inserting
            hud.update(phase: .inserting)

            let insertion = await TextInserter.shared.insert(output, into: insertTarget)
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
                // An unconfirmed paste keeps the dictation on the clipboard rather
                // than restoring the old one. Say so — otherwise the user sees an
                // empty field and has no idea the text is one ⌘V away.
                if insertion.method == .clipboardUnverified {
                    hud.flashSuccess(note: "Couldn’t confirm the paste — press ⌘V to insert it")
                    try? await Task.sleep(nanoseconds: 1_600_000_000)
                } else if limited {
                    hud.flashSuccess(note: "Stopped at the \(Int(TakeLimits.maxSeconds / 60))-minute limit — this is everything up to there")
                    try? await Task.sleep(nanoseconds: 1_600_000_000)
                } else if let note = result.cleanupNote {
                    // Not gated on cleanupFailed: a successful on-device fallback
                    // sets a note *and* leaves cleanupFailed false, so the old
                    // condition hid "Offline — polished on this Mac" entirely.
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
                hud.flashError(
                    insertion.textOnClipboard
                        ? "Couldn’t insert text\(target) — press ⌘V to paste it"
                        : "Could not insert text\(target) — check Accessibility"
                )
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

    private func makePipeline(sessionIntentOverride: String? = nil, task: PolishTask = .dictation) -> PolishPipeline {
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
            localIsReady: localFallbackReady(),
            isOnline: { NetworkReachability.shared.isOnline },
            enableTextCleanup: settings.enableTextCleanup,
            dictionary: CleanupPrompt.mergedDictionary(settings.dictionaryWords),
            personalContext: settings.cleanupPersonalContext,
            recentDictations: recentDictationsForPolish(),
            sessionIntent: sessionIntentOverride ?? liveSessionIntent(),
            task: task
        )
    }

    /// Request-time only. Never written into Settings → System prompt.
    private func liveSessionIntent(now: Date = Date()) -> String {
        guard settings.enableSessionContext else { return "" }
        guard let context = sessionContext else { return "" }
        if context.isExpired(now: now) {
            sessionContext = nil
            return ""
        }
        return context.text
    }

    private func storeSessionContext(from raw: String) async {
        let generation = sessionGeneration
        phase = .settingContext
        hud.update(phase: .settingContext)
        if settings.enableTextCleanup && (
            settings.shouldRunOnDevicePolish
                || settings.hasUsableCloudPolish
        ) {
            phase = .polishing
            hud.update(phase: .polishing)
        }
        // Empty override so an older phrase is not sent while polishing its replacement.
        let result = await makePipeline(sessionIntentOverride: "", task: .sessionContext).run(raw, targetApp: nil)
        guard generation == sessionGeneration else { return }

        var text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            text = VocalFillerFilter.strip(raw)
        }
        guard let context = SessionContext.make(text: text) else {
            phase = .error("Heard nothing")
            hud.flashError("Heard nothing")
            return
        }
        sessionContext = context
        lastPolished = context.text
        lastStages = ["Session context"] + result.stages
        lastCleanupNote = result.cleanupNote
        hud.flashSuccess(note: context.text)
        try? await Task.sleep(nanoseconds: 1_600_000_000)
        guard generation == sessionGeneration else { return }
        phase = .idle
        hud.hide()
    }

    func replaceSessionContext(fromEditedText raw: String) {
        sessionContext = SessionContext.make(text: raw)
    }

    /// Live phrase for the editor. Empty when unset or expired.
    var sessionContextText: String {
        guard hasActiveSessionContext else { return "" }
        return sessionContext?.text ?? ""
    }

    private func rememberSessionContextUse(relevant: Bool?, now: Date = Date()) {
        guard settings.enableSessionContext, let context = sessionContext else { return }
        if context.isExpired(now: now) {
            sessionContext = nil
            return
        }
        let used = context.registerUse(now: now)
        if let relevant {
            sessionContext = used.registerJudgment(relevant: relevant)
        } else {
            sessionContext = used
        }
    }

    func clearSessionContext() {
        sessionContext = nil
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

    /// Can the on-device model take over *right now*, without a download or a load?
    /// Gemma is unloaded whenever cloud polish is selected, so falling back to it
    /// would mean a 2.7 GB cold start mid-dictation — worse than pasting the text
    /// uncleaned. Apple Intelligence is a system model with no such cost.
    private func localFallbackReady() -> Bool {
        switch settings.localPolishEngine {
        case .none:
            return false
        case .appleIntelligence:
            return LocalLLMPolisher.isAvailable
        case .gemma4_e2b:
            return GemmaMLXPolisher.shared.isReady
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

    /// Compact polish line for the menu bar: which model is in use, plus load/key state.
    var polishStatusLine: String {
        guard settings.enableTextCleanup else {
            return "Polish: Off"
        }
        if settings.isCloudPolishSelected {
            let provider = settings.cloudPolishProvider
            let modelName = cloudPolishModelName(provider)
            if !settings.hasUsableCloudPolish {
                return "Polish: \(provider.displayName) · add API key"
            }
            return "Polish: \(provider.displayName) · \(modelName)"
        }
        switch settings.localPolishEngine {
        case .none:
            return "Polish: fillers only"
        case .appleIntelligence:
            if LocalLLMPolisher.isAvailable {
                return "Polish: Apple Intelligence"
            }
            if LocalLLMPolisher.needsSystemSettings {
                return "Polish: Apple Intelligence · turn on in System Settings"
            }
            return "Polish: Apple Intelligence · unavailable"
        case .gemma4_e2b:
            switch GemmaMLXPolisher.shared.status {
            case .idle:
                return "Polish: Gemma 4 E2B · not loaded"
            case .downloading(let fraction):
                return "Polish: Gemma 4 E2B · \(Int(fraction * 100))%"
            case .loading:
                return "Polish: Gemma 4 E2B · loading"
            case .ready:
                return "Polish: Gemma 4 E2B"
            case .failed:
                return "Polish: Gemma 4 E2B · failed"
            }
        }
    }

    /// Active spoken context for the menu bar. Nil when the feature is off.
    /// Empty takes still return a "not set" line so you can see the build has the feature.
    var sessionContextLine: String? {
        guard settings.enableSessionContext else { return nil }
        if let context = sessionContext, !context.isExpired(now: Date()) {
            return context.menuLine()
        }
        return "Context: not set — press Shift during a take"
    }

    var hasActiveSessionContext: Bool {
        guard settings.enableSessionContext, let context = sessionContext else { return false }
        return !context.isExpired(now: Date())
    }

    private func cloudPolishModelName(_ provider: CloudPolishProvider) -> String {
        let catalog = CloudModelCatalog.shared
        switch provider {
        case .none:
            return provider.displayName
        case .openAI:
            return catalog.displayName(for: settings.openAIModel, in: catalog.openAIModels)
        case .anthropic:
            return catalog.displayName(for: settings.anthropicModel, in: catalog.anthropicModels)
        }
    }
}
