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
    /// Topics the polish model keeps up to date as takes come in — the cloud
    /// model, or Apple Intelligence on this Mac, alongside protected user notes.
    /// Context is kept only for this launch.
    @Published private(set) var autoContext = AutoContext()
    private let autoContextUpdates = AutoContextUpdateQueue()
    private struct ContextUpdateResult: Sendable {
        let change: AutoContext.Change?
        let shown: [AutoContext.Topic]
    }
    /// Frontmost app when dictation started. Passed to polish LLMs as formatting context.
    private var dictationTargetApp: TargetAppContext?
    /// Title of the window the take was aimed at, read in the background as the
    /// take starts. Dev only; logged, never sent.
    private var dictationWindowTitle: String?
    /// Language for the take in flight. Decided when the key goes down and
    /// re-decided by a keyboard switch while it is held — Caps Lock mid-take is
    /// a correction, the same way Shift flips context mid-take. Fixed once the
    /// recording stops, or once a long take has started turning audio into text.
    private(set) var takeLanguage: SpokenLanguage = .english
    private var recordingBeganAt: Date?
    /// Watches a running take for conditions that must end it early.
    private var takeWatchTask: Task<Void, Never>?
    /// Consecutive watch ticks that saw the hotkey up while we thought it was held.
    private var missedReleaseTicks = 0
    /// Transcribes completed chunks while the take is still running. Nil between takes.
    private var streamer: StreamingTranscriber?
    /// The transcribe → polish → insert run. Held so it can be abandoned: without a
    /// way out, a long take committed you to the whole wait.
    private var processingTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.usingcolor.WhisperLocal", category: "dictation")
    /// MenuBarExtra onAppear also calls start(); only load speech once.
    private var didBootstrapSpeech = false
    /// Bumped at the start of each take so a late success-sleeper cannot idle a newer session.
    private var sessionGeneration = 0
    /// Shift switch for this take (context vs paste). Never inferred from transcript content. Snapshot at finish.
    @Published private(set) var isIntentTake = false

    private init() {
        autoContextUpdates.invalidateWhenChanged(settings.$useAutoContext) { [weak self] enabled in
            if !enabled { self?.autoContext.clearAutomatic() }
        }
        autoContextUpdates.invalidateWhenChanged(settings.$enableTextCleanup) { [weak self] enabled in
            if !enabled { self?.autoContext.clearAutomatic() }
        }
        autoContextUpdates.invalidateWhenChanged(settings.$cloudPolishProviderRaw)
        autoContextUpdates.invalidateWhenChanged(settings.$localPolishEngineRaw)
        autoContextUpdates.invalidateWhenChanged(settings.$openAIModel)
        autoContextUpdates.invalidateWhenChanged(settings.$anthropicModel)
        autoContextUpdates.invalidateWhenChanged(settings.$hasOpenAIKey)
        autoContextUpdates.invalidateWhenChanged(settings.$hasAnthropicKey)
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
                self?.refreshHUDContext()
            }
            .store(in: &cancellables)
        $autoContext.combineLatest($sessionContext)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshHUDContext() }
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
        if RelatedTakeIndex.isEnabled {
            // Fires once now with the log as loaded, which builds the index, and
            // again for every take added or the log cleared.
            log.$entries
                .sink { _ in Task { await RelatedTakeIndex.shared.refresh() } }
                .store(in: &cancellables)
        }
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
        hotKey.onOpenContext = { [weak self] in
            guard let self, !self.isBusyProcessing, self.phase != .recording, self.phase != .waitingForMic else { return }
            WindowOpener.shared.open(title: "Context", id: "context")
        }
        hud.onOpenContext = {
            WindowOpener.shared.open(title: "Context", id: "context")
        }
        hud.onCancel = { [weak self] in
            // The same path Escape takes. `abandonProcessing` was wrong for a take
            // still recording: it cancels the work but never stops the recorder or
            // clears the hotkey session, so the HUD would have said "Cancelled"
            // with the microphone still open. `cancelRecording` routes to it when
            // there is no recording left to stop.
            self?.cancelRecording()
        }
        hud.onSelectInput = { [weak self] uid in
            // Mid-take this rebuilds the input graph and keeps recording into the
            // same buffer: a gap of a few hundred milliseconds, then the rest of
            // the sentence on the new microphone, all in one transcript.
            self?.recorder.useInput(uid: uid)
        }
        hotKey.onIntentModifierChanged = { [weak self] intent in
            self?.setRecordingIntent(intent)
        }
        hotKey.start()

        permissions.refresh()
        // A temporary copy joins the list of reasons to open this window on
        // launch. Left to a Settings row it would never be read, and the symptom
        // — permissions and the login item quietly not sticking — looks like
        // something else entirely.
        if !settings.hasCompletedOnboarding || !permissions.allGranted || AppInstallLocation.current != nil {
            showOnboarding = true
        }

        NetworkReachability.shared.start()
        LanguageCoordinator.shared.onKeyboardChange = { [weak self] in
            self?.keyboardChangedDuringTake()
        }
        LanguageCoordinator.shared.start()

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

    /// A keyboard switch while the key is held re-decides the take's language, and
    /// the badge follows. Only while recording: once the key is up the audio is
    /// final, and once a long take has streamed a chunk that text is already in
    /// one language — the switch is refused and the badge keeps telling the truth.
    private func keyboardChangedDuringTake() {
        guard LanguageCoordinator.isEnabled else { return }
        guard phase == .recording || phase == .waitingForMic else { return }
        let next = LanguageCoordinator.shared.languageForTake(transcription: transcription)
        guard next != takeLanguage else { return }
        if let streamer, !streamer.setLanguage(next) {
            logger.info("keyboard switched to \(next.code, privacy: .public) mid-take, but a chunk is already transcribed; keeping \(self.takeLanguage.code, privacy: .public)")
            return
        }
        logger.info("keyboard switched mid-take: \(self.takeLanguage.code, privacy: .public) -> \(next.code, privacy: .public)")
        takeLanguage = next
        hud.setLanguage(next)
    }


    /// What the log should say this take ran in, and came from.
    ///
    /// The language is recorded even when it is English: a log states what
    /// happened, and "nothing here" is not the same fact as "English". The
    /// microphone is joined the way stages are, so a mid-take switch reads as one
    /// field rather than hiding behind whichever device happened to be last.
    private var loggedLanguage: String {
        takeLanguage.englishName
    }

    private var loggedMicrophone: String? {
        let trail = recorder.inputTrail
        guard !trail.isEmpty else { return recorder.currentInputName }
        return trail.joined(separator: " → ")
    }

    /// What would be lost by quitting right now, phrased to finish "WhisperLocal is
    /// still …". Nil when there is nothing in flight.
    var workInProgressDescription: String? {
        switch phase {
        case .recording, .waitingForMic:
            return "recording"
        case .processing, .settingContext:
            return "transcribing a dictation"
        case .polishing:
            return "polishing a dictation"
        case .inserting:
            return "inserting a dictation"
        case .idle, .success, .successNote, .error:
            return nil
        }
    }

    func stop() {
        processingTask?.cancel()
        autoContextUpdates.invalidate()
        streamer?.cancel()
        sessionGeneration += 1
        hotKey.stop()
        recorder.cancel()
        hud.hide()
    }

    // MARK: - Hotkey routing (hold vs tap)

    private func handleHotkeyPress(intentModifierHeld: Bool) {
        // Ignored while the take is being worked on. Cancelling from the hotkey read
        // well until you consider the reflex it collides with: finishing a take and
        // pressing again to start the next one would have killed the first. Cancel
        // is a button on the HUD and the Escape key, both of which are deliberate.
        if isBusyProcessing { return }

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
            phase = .error("Needs Microphone access")
            showOnboarding = true
            return
        }
        guard permissions.accessibilityTrusted else {
            isIntentTake = false
            hotKey.markSessionActive(false)
            phase = .error("Needs Accessibility access")
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
            // Before the HUD: reading the frontmost app is cheap, and it has to be
            // the app the user was in rather than anything a panel appearing might
            // disturb.
            dictationTargetApp = TargetAppContext.captureFrontmost()
            takeLanguage = LanguageCoordinator.shared.languageForTake(transcription: transcription)
            readWindowTitle(of: dictationTargetApp)

            // The HUD goes up before the microphone is opened, not after it.
            // Opening the graph is about 40ms today, which is why the old ordering
            // went unnoticed for so long — but a take that waits on the hardware
            // before it shows anything looks like a missed keypress, and a slow
            // device is not a reason to leave the screen blank. `waitingForMic` is
            // exactly this state, and the `isInputReady` subscription promotes it
            // to `.recording` on its own the moment audio arrives.
            phase = .waitingForMic
            refreshHUDContext()
            hud.show(
                phase: .waitingForMic,
                levelPublisher: recorder,
                contextCapture: isIntentTake,
                language: LanguageCoordinator.isEnabled ? takeLanguage : nil
            )

            // A Chromium app has to be asked to build its accessibility tree, and
            // it builds it asynchronously. Asking now, rather than when the text
            // goes in, is the difference between it being ready and the first take
            // into a freshly launched app coming back unconfirmed.
            TextInserter.shared.prepareForInsertion(into: dictationTargetApp)
            try recorder.start()
            recordingBeganAt = Date()
            hotKey.markSessionActive(true)
            startTakeWatch()
            startStreaming()
            if recorder.isInputReady {
                phase = .recording
                hud.update(phase: .recording)
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
    /// Transcription runs alongside the recording, so letting go of a long take only
    /// costs the final partial chunk instead of the whole thing. Nothing is emitted
    /// until there is enough audio to place a cut, so short takes never stream and
    /// behave exactly as they did before.
    private func startStreaming() {
        let extraTerms = settings.matchingAppDictionaryTerms(targetApp: dictationTargetApp?.promptLine)
        let streamer = StreamingTranscriber(
            drainChunk: { [recorder] in recorder.drainCompletedChunk() },
            transcribe: { [transcription] samples, dictionary, language in
                try await transcription.transcribe(samples: samples, extraDictionary: dictionary, language: language)
            },
            dictionary: extraTerms,
            language: takeLanguage
        )
        self.streamer = streamer
        // No progress reporting by design. How a take is cut up is our problem, not
        // something to narrate at someone who is mid-sentence — and streaming made
        // the end-of-take wait short enough that progress no longer earns its place.
        streamer.start()
    }

    /// Watches a running take for the two conditions it cannot survive: an input
    /// graph that died, and a key-up we never received. Both end the take with
    /// whatever was captured. There is no time ceiling — see `TakeLimits`.
    private func startTakeWatch() {
        takeWatchTask?.cancel()
        takeWatchTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled, let self else { return }
                guard self.phase == .recording || self.phase == .waitingForMic else { return }

                // The mic died mid-take (device unplugged, interface removed). Keep
                // what was captured rather than recording silence indefinitely.
                if self.recorder.inputFailed {
                    self.logger.error("Input graph failed mid-take — finishing with what was captured")
                    self.finishRecording()
                    return
                }

                // Recover from a key-up we never saw. Confirmed over consecutive
                // ticks so a momentary misread cannot truncate a live take; a stuck
                // session lasts forever, so the extra second costs nothing. With no
                // time ceiling this is the only thing that ends a runaway take.
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
            }
        }
    }

    private func stopTakeWatch() {
        takeWatchTask?.cancel()
        takeWatchTask = nil
        missedReleaseTicks = 0
        hud.setDetail(nil)
    }

    private func setRecordingIntent(_ intent: Bool) {
        guard phase == .recording || phase == .waitingForMic else { return }
        isIntentTake = settings.enableSessionContext && settings.enableTextCleanup && intent
        hud.setContextCapture(isIntentTake)
    }

    var isBusyProcessing: Bool {
        phase == .processing || phase == .settingContext || phase == .polishing || phase == .inserting
    }

    /// Drop everything for this take: no transcript, no polish, no paste.
    private func abandonProcessing() {
        logger.info("Take abandoned by the user")
        processingTask?.cancel()
        processingTask = nil
        streamer?.cancel()
        streamer = nil
        dictationTargetApp = nil
        isIntentTake = false
        sessionGeneration += 1
        phase = .idle
        hud.setDetail(nil)
        hud.flashError("Cancelled")
    }

    private func cancelRecording() {
        // Escape reaches here during processing too, where there is no recording to
        // stop but plenty of work to abandon.
        if isBusyProcessing {
            abandonProcessing()
            return
        }
        stopTakeWatch()
        streamer?.cancel()
        streamer = nil
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
        stopTakeWatch()
        // Paste vs context is the Shift switch at the end of the take, not the first press.
        setRecordingIntent(hotKey.intentModifierHeld)
        let samples = recorder.stop()
        hotKey.markSessionActive(false)

        if cancelRequested {
            dictationTargetApp = nil
            isIntentTake = false
            recordingBeganAt = nil
            streamer?.cancel()
            streamer = nil
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
            streamer?.cancel()
            streamer = nil
            phase = .idle
            hud.hide()
            return
        }
        if Self.peakAbsolute(samples) < 0.003, streamer?.didStream != true {
            dictationTargetApp = nil
            isIntentTake = false
            streamer?.cancel()
            streamer = nil
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
                audioSeconds: Double(samples.count) / TranscriptionService.sampleRate,
                language: loggedLanguage,
                microphone: loggedMicrophone
            ))
            return
        }

        phase = isIntentTake ? .settingContext : .processing
        hud.update(phase: phase)

        let generation = sessionGeneration
        processingTask = Task {
            await process(samples: samples, generation: generation)
            if generation == self.sessionGeneration { self.processingTask = nil }
        }
    }

    private func process(samples: [Float], generation: Int) async {
        guard canContinue(generation) else { return }
        // Filled in after the streamer settles: most of a long take has already been
        // drained out of `samples` by then, so its length is not the take's length.
        var audioSeconds = Double(samples.count) / TranscriptionService.sampleRate
        let targetApp = dictationTargetApp?.promptLine
        let targetAppName = dictationTargetApp?.name
        let windowTitle = dictationWindowTitle
        dictationWindowTitle = nil
        // Kept whole, not just its prompt line: insertion needs the process.
        let insertTarget = dictationTargetApp
        let intentTake = isIntentTake
        dictationTargetApp = nil
        isIntentTake = false
        lastTranscript = ""
        lastPolished = ""
        lastStages = []
        lastCleanupNote = nil
        do {
            let extraTerms = settings.matchingAppDictionaryTerms(targetApp: targetApp)
            let raw: String
            if let streamer, streamer.didStream {
                // Most of this take is already transcribed; only the tail is left.
                raw = await streamer.finish(tail: samples)
                guard canContinue(generation) else { return }
                audioSeconds = Double(streamer.streamedSamples + samples.count)
                    / TranscriptionService.sampleRate
                self.streamer = nil
                // Every chunk failed. Joining leaves a lone gap marker, which is not
                // something to paste at somebody.
                if raw.trimmingCharacters(in: .whitespacesAndNewlines) == TranscriptJoiner.gapMarker {
                    throw TranscriptionError.allChunksFailed
                }
            } else {
                streamer?.cancel()
                self.streamer = nil
                raw = try await transcription.transcribe(
                    samples: samples,
                    extraDictionary: extraTerms,
                    language: takeLanguage
                )
            }
            // Cancellation is cooperative: the model call in flight runs to the end,
            // but nothing after it starts.
            guard canContinue(generation) else { return }
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
                    audioSeconds: audioSeconds,
                    language: loggedLanguage,
                    microphone: loggedMicrophone,
                    windowTitle: windowTitle
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
            let examples = await polishExamples(for: raw, appName: targetAppName)
            guard canContinue(generation) else { return }
            let relatedTakeIDs = examples.relatedIDs
            // Snapshot: what this take was shown is what the log should say.
            let contextGeneration = autoContextUpdates.generation
            let autoContextTopics = keepsAutoContext ? currentAutoContextTopics() : nil
            let autoContextShown = autoContextTopics?.map(\.text)
            let result = await makePipeline(
                sessionIntentOverride: autoContextTopics.map {
                    settings.hasUsableCloudPolish
                        ? AutoContext.polishIntent(session: liveSessionIntent(), topics: $0, now: Date())
                        : AutoContext.onDevicePolishIntent(session: liveSessionIntent(), topics: $0)
                },
                recentDictations: examples.prompt
            )
                .runChunked(raw, targetApp: targetApp)
            guard canContinue(generation), !result.isCancelled else { return }
            let output = result.text
            lastPolished = output
            lastStages = result.stages
            lastCleanupNote = result.cleanupNote
            rememberSessionContextUse(relevant: result.contextRelevant)
            // Filled in by the update after the paste; see updateAutoContext.
            let entryID = UUID()

            // Always paste when we have text — even if LLM cleanup failed.
            phase = .inserting
            hud.update(phase: .inserting)

            let insertion = await TextInserter.shared.insert(output, into: insertTarget)
            guard canContinue(generation) else { return }
            let contextPastedAt = Date()
            if insertion.success {
                phase = .success
                if let app = insertion.appName {
                    lastStages.append("insert:\(insertion.method.rawValue)→\(app)")
                } else {
                    lastStages.append("insert:\(insertion.method.rawValue)")
                }
                let entry = DictationLogEntry(
                    id: entryID,
                    date: contextPastedAt,
                    raw: raw,
                    polished: output,
                    stages: lastStages,
                    cleanupNote: result.cleanupNote,
                    appName: insertion.appName,
                    insertMethod: insertion.method.rawValue,
                    outcome: .success,
                    errorMessage: nil,
                    audioSeconds: audioSeconds,
                    language: loggedLanguage,
                    microphone: loggedMicrophone,
                    relatedTakeIDs: relatedTakeIDs,
                    windowTitle: windowTitle,
                    autoContext: autoContextShown,
                    speechModel: settings.asrModel.rawValue,
                    polishModel: polishModel(for: result.stages)
                )
                log.append(entry)
                // Queued only for someone who joined and chose to share takes as
                // they happen; the rules are in DataSharingStore.
                if DataSharing.isEnabled {
                    DataSharingStore.shared.takeFinished(entry)
                }
                if autoContextShown != nil {
                    updateAutoContext(after: output, targetApp: targetApp, appName: targetAppName, entryID: entryID,
                                      cloudAvailable: !result.cloudUnavailable, generation: contextGeneration,
                                      pastedAt: contextPastedAt)
                }
                // An insert we could not confirm keeps the dictation on the
                // clipboard rather than restoring the old one. Say so — otherwise
                // the user sees an empty field and has no idea the text is one ⌘V
                // away. Keyed on the flag, not one method: an unconfirmed
                // accessibility write leaves it there too.
                if insertion.textOnClipboard {
                    hud.flashSuccess(note: "Not confirmed — press ⌘V")
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
                guard canContinue(generation) else { return }
                phase = .idle
                hud.hide()
            } else {
                phase = .error("Could not insert text")
                // The app's name is deliberately not in the HUD copy. It was the
                // longest part of the sentence and the one piece that could be any
                // length at all, and the person reading it is looking straight at
                // the app in question. The log still records `appName` for later.
                hud.flashError(
                    insertion.method == .clipboardChanged
                        ? "Clipboard changed — copy from log"
                        : insertion.textOnClipboard
                        ? "Not inserted — press ⌘V"
                        : "Needs Accessibility access"
                )
                log.append(DictationLogEntry(
                    id: entryID,
                    date: contextPastedAt,
                    raw: raw,
                    polished: output,
                    stages: result.stages,
                    cleanupNote: result.cleanupNote,
                    appName: insertion.appName,
                    insertMethod: insertion.method.rawValue,
                    outcome: .insertFailed,
                    // The HUD dropped the app name to stay one width; the log is
                    // where it earns its place, read later and with room for it.
                    errorMessage: insertion.appName.map { "Could not insert text into \($0)" }
                        ?? "Could not insert text",
                    audioSeconds: audioSeconds,
                    language: loggedLanguage,
                    microphone: loggedMicrophone,
                    relatedTakeIDs: relatedTakeIDs,
                    windowTitle: windowTitle,
                    autoContext: autoContextShown,
                    speechModel: settings.asrModel.rawValue,
                    polishModel: polishModel(for: result.stages)
                ))
                // What was said still says what they are working on.
                if autoContextShown != nil {
                    updateAutoContext(after: output, targetApp: targetApp, appName: targetAppName, entryID: entryID,
                                      cloudAvailable: !result.cloudUnavailable, generation: contextGeneration,
                                      pastedAt: contextPastedAt)
                }
            }
        } catch {
            guard canContinue(generation), !(error is CancellationError) else { return }
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
                audioSeconds: audioSeconds,
                language: loggedLanguage,
                microphone: loggedMicrophone,
                windowTitle: windowTitle
            ))
        }
    }

    private func canContinue(_ generation: Int) -> Bool {
        !Task.isCancelled && generation == sessionGeneration
    }

    /// In the background: Accessibility can block on an app that is busy, and
    /// the take is starting. A take shorter than the read goes without.
    private func readWindowTitle(of target: TargetAppContext?) {
        dictationWindowTitle = nil
        guard FocusedWindowTitle.isEnabled, let pid = target?.pid else { return }
        let generation = sessionGeneration
        Task { @MainActor in
            let title = await Task.detached(priority: .utility) { FocusedWindowTitle.read(pid: pid) }.value
            guard generation == self.sessionGeneration else { return }
            self.dictationWindowTitle = title
        }
    }

    private func makePipeline(
        sessionIntentOverride: String? = nil,
        task: PolishTask = .dictation,
        recentDictations: String? = nil
    ) -> PolishPipeline {
        PolishPipeline(
            localLLM: onDevicePolisher(),
            cloud: cloudPolisher(),
            useLocalLLM: settings.shouldRunOnDevicePolish,
            localIsReady: localFallbackReady(),
            isOnline: { NetworkReachability.shared.isOnline },
            enableTextCleanup: settings.enableTextCleanup,
            language: takeLanguage,
            dictionary: CleanupPrompt.mergedDictionary(settings.dictionaryWords),
            personalContext: settings.cleanupPersonalContext,
            recentDictations: recentDictations ?? recentDictationsForPolish(),
            sessionIntent: sessionIntentOverride ?? liveSessionIntent(),
            task: task
        )
    }

    /// The model that cleaned a take, read from the steps that ran: the cloud
    /// model Settings names, or the on-device engine. Nil when no model did.
    private func polishModel(for stages: [String]) -> String? {
        if stages.contains("OpenAI") { return settings.openAIModel }
        if stages.contains("Anthropic") { return settings.anthropicModel }
        if stages.contains(LocalLLMPolisher.shared.name) { return "apple-intelligence" }
        if stages.contains(GemmaMLXPolisher.shared.name) { return GemmaMLXPolisher.shared.name }
        return nil
    }

    /// The cloud model Settings picks. Only with a key: a missing one would
    /// otherwise flag cleanupFailed on every take.
    private func cloudPolisher() -> (any TextPolisher & CloudAsking)? {
        switch settings.cloudPolishProvider {
        case .none:
            return nil
        case .openAI:
            guard !settings.openAIAPIKey.isEmpty else { return nil }
            return OpenAIPolisher(apiKey: settings.openAIAPIKey, model: settings.openAIModel)
        case .anthropic:
            guard !settings.anthropicAPIKey.isEmpty else { return nil }
            return AnthropicPolisher(apiKey: settings.anthropicAPIKey, model: settings.anthropicModel)
        }
    }

    /// Request-time only. Never written into Settings → System prompt.
    private func liveSessionIntent(now: Date = Date()) -> String {
        if let context = sessionContext, context.isExpired(now: now) {
            sessionContext = nil
        }
        let spoken = settings.enableSessionContext ? (sessionContext?.text ?? "") : ""
        return AutoContext.userIntent(session: spoken, topics: autoContext.userTopics)
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
        guard canContinue(generation), !result.isCancelled else { return }

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
        // Labelled, because the sentence alone is ambiguous. The toolbar used to
        // carry a CONTEXT badge through this moment; without it, a bare sentence
        // beside the amber checkmark reads exactly like "Not confirmed — press ⌘V",
        // and pressing ⌘V pastes whatever is on the clipboard. The label leads so it
        // survives the width cut; the whole sentence is on the tooltip.
        hud.flashSuccess(note: "Context saved: \(context.text)")
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
        // A relevance answer covers the combined context. With protected notes
        // present it cannot tell us whether the Shift phrase itself drifted.
        if let relevant, autoContext.userTopics.isEmpty {
            sessionContext = used.registerJudgment(relevant: relevant)
        } else {
            sessionContext = used
        }
    }

    /// Switched on, and a model to keep the topics: the cloud model that
    /// polishes, or Apple Intelligence when polish runs on it. Gemma is not
    /// asked to keep them.
    private var keepsAutoContext: Bool {
        AutoContext.isEnabled && settings.useAutoContext && settings.enableTextCleanup
            && (settings.hasUsableCloudPolish || polishesWithAppleIntelligence)
    }

    private var polishesWithAppleIntelligence: Bool {
        settings.shouldRunOnDevicePolish && settings.localPolishEngine == .appleIntelligence
    }

    var autoContextLine: String? {
        guard AutoContext.isEnabled, settings.useAutoContext else { return nil }
        let now = Date()
        let topics = currentAutoContextTopics(now: now)
        guard !topics.isEmpty else { return "Auto context: nothing noted yet" }
        let lines = AutoContext.newestFirst(topics).map { "\($0.text) — \(AutoContext.whereAndWhen($0, now: now))" }
        return (["Auto context, newest first:"] + lines).joined(separator: "\n")
    }

    private func currentAutoContextTopics(now: Date = Date()) -> [AutoContext.Topic] {
        let topics = autoContext.liveTopics(now: now)
        if topics.count != autoContext.topics.count { autoContext.expire(now: now) }
        return topics.filter { $0.source.isAutomatic }
    }

    func clearAutoContext() {
        autoContextUpdates.invalidate()
        autoContext.clearAutomatic()
    }

    func contextDraft(now: Date = Date()) -> ContextEditorDraft {
        ContextEditorDraft(session: sessionContext, topics: autoContext.liveTopics(now: now), now: now)
    }

    @discardableResult
    func saveContextDraft(_ draft: ContextEditorDraft) -> Bool {
        guard let (topics, spoken) = draft.applying(to: autoContext, session: sessionContext) else { return false }
        if draft.isDirty { autoContextUpdates.invalidate() }
        autoContext = topics
        sessionContext = spoken
        refreshHUDContext()
        return true
    }

    func clearAllContext() {
        autoContextUpdates.invalidate()
        autoContext.clear()
        sessionContext = nil
        refreshHUDContext()
    }

    var contextSummary: String {
        guard settings.enableTextCleanup else { return "Polish is off" }
        let notes = autoContext.userTopics.map(\.text)
        let spoken = hasActiveSessionContext ? [sessionContextText] : []
        let automatic = AutoContext.isEnabled && settings.useAutoContext
            ? AutoContext.newestFirst(autoContext.liveTopics().filter { $0.source.isAutomatic }).map(\.text) : []
        let texts = spoken + notes + automatic
        guard let first = texts.first else { return "No active topics" }
        let preview = first.count > 48 ? String(first.prefix(47)) + "…" : first
        return texts.count > 1 ? "\(preview) (+\(texts.count - 1))" : preview
    }

    private func refreshHUDContext() {
        hud.contextSummary = settings.enableTextCleanup ? contextSummary : nil
    }

    /// Asks how a pasted take changes the topics, and records the answer
    /// against the take's log entry. Off the paste's path: the request takes
    /// 1.3 s to the cloud or 0.7 s on this Mac, and the next take waits for none
    /// of it.
    ///
    /// A take that gets no answer — no model, a failed request, a reply with no
    /// line in it — still counts toward topics fading.
    private func updateAutoContext(
        after text: String, targetApp: String?, appName: String?, entryID: UUID,
        cloudAvailable: Bool, generation: UUID, pastedAt: Date
    ) {
        guard keepsAutoContext else { return }
        autoContextUpdates.enqueue(generation: generation, operation: { [weak self] () -> ContextUpdateResult? in
            guard let self, self.keepsAutoContext else { return nil }
            // Pick the provider only when sending, after the policy/generation
            // checks; a queued take must not retain a revoked cloud client.
            let updater = self.autoContextUpdater(cloudAvailable: cloudAvailable)
            let shown = self.currentAutoContextTopics()
            var change: AutoContext.Change?
            if let updater {
                do {
                    change = try await updater.answer(
                        topics: shown, take: text, targetApp: targetApp, now: pastedAt
                    ).change
                } catch {
                    if Task.isCancelled || error is CancellationError { return nil }
                    self.logger.error("Auto context update failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            return ContextUpdateResult(change: change, shown: shown)
        }, apply: { [weak self] result in
            guard let self, self.keepsAutoContext, let result else { return }
            let happened = self.autoContext.record(
                result.change, relativeTo: result.shown, app: appName,
                now: pastedAt, observedAt: Date()
            )
            self.log.recordAutoContextChange(happened, for: entryID)
        })
    }

    /// The cloud model when it could polish this take. Otherwise Apple
    /// Intelligence, on this Mac: it keeps the topics for on-device polish, and
    /// for a cloud take that fell back because the cloud could not be reached.
    private func autoContextUpdater(cloudAvailable: Bool) -> (any AutoContextUpdater)? {
        if cloudAvailable, let cloud = cloudPolisher() {
            return CloudContextUpdater(model: cloud)
        }
        return AppleIntelligenceContextUpdater.isAvailable ? AppleIntelligenceContextUpdater() : nil
    }

    func clearSessionContext() {
        sessionContext = nil
    }

    /// The examples for a dictation's polish, and which of them were chosen for
    /// sharing words with this take rather than for being recent.
    ///
    /// Release, Dev with the switch off, and Dev with nothing related found send
    /// exactly the recent takes. Otherwise Dev gives up to three of the eight
    /// slots to related takes and fills whatever it cannot use with recent ones
    /// again, so the count never drops. Everything goes in newest first, which
    /// is what the prompt says the list is.
    ///
    /// `relatedIDs` is nil when related takes were not looked for at all, and
    /// empty when they were and none qualified, so the log can tell a take run
    /// with the switch off from one that simply found nothing.
    private func polishExamples(for raw: String, appName: String?) async -> (prompt: String, relatedIDs: [UUID]?) {
        guard RelatedTakeIndex.isEnabled, settings.useRelatedTakes, settings.shouldIncludeRecentPolishLogs else {
            return (recentDictationsForPolish(), nil)
        }
        let cloud = settings.hasUsableCloudPolish
        let count = cloud
            ? settings.recentPolishLogCount
            : min(settings.recentPolishLogCount, CleanupPrompt.onDeviceRecentExampleLimit)
        let recent = log.recentPolishEntries(limit: count)
        let slots = RelatedTakeScoring.relatedSlots(outOf: count)
        var related: [DictationLogEntry] = []
        if slots > 0 {
            let matches = await RelatedTakeIndex.shared.related(
                to: raw,
                language: loggedLanguage,
                appName: appName,
                // All of them, not just the ones kept: a take recency would have
                // sent anyway is not a find.
                excluding: Set(recent.map(\.id)),
                limit: slots
            )
            related = log.entries(withIDs: matches.map(\.id))
            if !matches.isEmpty {
                let found = matches.map { "\($0.sharedRareWords.joined(separator: ",")) \(String(format: "%.2f", $0.score))" }
                logger.info("related takes: \(found.joined(separator: " | "), privacy: .private)")
            }
        }
        let chosen = (Array(recent.prefix(count - related.count)) + related)
            .sorted { $0.date > $1.date }
            .map(DictationLogStore.example)
        let prompt = CleanupPrompt.formatRecentDictations(
            chosen,
            maxCharsPerSide: cloud ? CleanupPrompt.cloudRecentMaxCharsPerSide : CleanupPrompt.onDeviceRecentMaxCharsPerSide
        )
        return (prompt, related.map(\.id))
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
