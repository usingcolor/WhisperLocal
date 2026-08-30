import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum SettingsPage: String, CaseIterable, Identifiable {
    case dictation
    case polish
    case prompt
    case openai
    case anthropic
    case dictionary
    case permissions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dictation: return "Dictation"
        case .polish: return "Polish"
        case .prompt: return "System prompt"
        case .openai: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .dictionary: return "Dictionary"
        case .permissions: return "Permissions"
        }
    }

    var icon: String {
        switch self {
        case .dictation: return "mic"
        case .polish: return "wand.and.stars"
        case .prompt: return "text.alignleft"
        case .openai: return "cloud"
        case .anthropic: return "cloud.fill"
        case .dictionary: return "character.book.closed"
        case .permissions: return "lock.shield"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var controller: DictationController
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var permissions = PermissionManager.shared
    @ObservedObject private var hotKey = HotKeyManager.shared
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var models = CloudModelCatalog.shared
    @ObservedObject private var gemma = GemmaMLXPolisher.shared

    @State private var page: SettingsPage = .dictation
    @State private var openAIKeyDraft = ""
    @State private var anthropicKeyDraft = ""
    @State private var newDictionaryTerm = ""
    @State private var dictionaryDestination: DictionaryDestination = .everyApp
    @State private var isAddingOtherApp = false
    @State private var customAppName = ""
    @State private var customAppKind = TargetAppContext.Kind.other
    @State private var dictionaryFileNote: String?
    @State private var promptCopyNote: String?

    var body: some View {
        NavigationSplitView {
            List(selection: $page) {
                ForEach(SettingsPage.allCases) { item in
                    Label(item.title, systemImage: item.icon)
                        .tag(item)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 160, ideal: 176, max: 220)
        } detail: {
            Group {
                switch page {
                case .dictation: dictationPane
                case .polish: polishPane
                case .prompt: promptPane
                case .openai: openAIPane
                case .anthropic: anthropicPane
                case .dictionary: dictionaryPane
                case .permissions: permissionsPane
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .navigationTitle("WhisperLocal Settings")
            .navigationSubtitle(page.title)
        }
        .frame(minWidth: 720, minHeight: 500)
        .background(SettingsWindowChrome())
        .onAppear {
            if !controller.transcription.isReady, !controller.transcription.isLoadingModel {
                Task { await controller.transcription.ensureModel(named: settings.asrModel) }
            }
        }
        .onChange(of: settings.appDictionariesRaw) { _, _ in
            if case .app(let id) = dictionaryDestination,
               !settings.appDictionaries.contains(where: { $0.id == id }) {
                dictionaryDestination = .everyApp
            }
        }
    }

    private var dictationPane: some View {
        settingsForm {
            Section {
                Picker("Hotkey", selection: $hotKey.selectedKey) {
                    ForEach(HotKeyManager.KeyChoice.allCases) { key in
                        Text(key.displayName).tag(key)
                    }
                }
                Picker("Mode", selection: $hotKey.mode) {
                    ForEach(HotkeyMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                Text(hotKey.mode.helpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Speech model", selection: Binding(
                    get: { settings.asrModel },
                    set: { newValue in
                        settings.asrModel = newValue
                        Task { await controller.transcription.ensureModel(named: newValue) }
                    }
                )) {
                    ForEach(ASRModelOption.allCases) { model in
                        Text(model.displayName).tag(model)
                    }
                }
                speechModelHelp
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if settings.asrModel == .appleSpeech, !AppleSpeechASR.isAvailable {
                    Text(AppleSpeechASR.availabilityMessage)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                LabeledContent("Speech status") {
                    HStack(spacing: 8) {
                        if controller.transcription.isLoadingModel {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 16, height: 16)
                        }
                        Text(controller.transcription.statusMessage)
                            .foregroundStyle(controller.transcription.isReady ? Color.secondary : Color.orange)
                            .textSelection(.enabled)
                    }
                }
                if let loaded = controller.transcription.loadedModel,
                   loaded != settings.asrModel {
                    Text("Picker is \(settings.asrModel.displayName); memory still has \(loaded.displayName) until loading finishes.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Toggle("Insert trailing space", isOn: $settings.insertTrailingSpace)
            }

            Section("Last dictation") {
                LabeledContent("Raw") {
                    Text(controller.lastTranscript.isEmpty ? "—" : controller.lastTranscript)
                        .lineLimit(3)
                }
                LabeledContent("Polished") {
                    Text(controller.lastPolished.isEmpty ? "—" : controller.lastPolished)
                        .lineLimit(3)
                }
                if !controller.lastStages.isEmpty {
                    LabeledContent("Stages") {
                        Text(controller.lastStages.joined(separator: " → "))
                            .foregroundStyle(.secondary)
                    }
                }
                if let note = controller.lastCleanupNote {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Toggle("Keep a dictation log", isOn: $settings.enableDictationLog)
                Text("Saves recent takes as local JSON (text only). Turn off to skip new entries; existing log is not deleted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Open dictation log…") {
                    AppWindowFocus.present(title: "Dictation Log") {
                        openWindow(id: "log")
                    }
                }
            }
        }
    }

    private var polishPane: some View {
        settingsForm {
            Section {
                Toggle("Enable text cleanup", isOn: $settings.enableTextCleanup)
                Text("One on-device model or cloud polish — not both. If AI cleanup fails, text is still pasted. Um / uh / hmm are always dropped while this is on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Heuristic cleanup", isOn: $settings.enableHeuristicCleanup)
                    .disabled(!settings.enableTextCleanup)
                Text("Local fillers, spoken punctuation, and dictionary replacements before the model. Turn off to send raw ASR to Gemma, Apple Intelligence, or cloud. Um / uh / hmm are still stripped.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("On-device polish", selection: Binding(
                    get: { settings.localPolishEngine },
                    set: { settings.localPolishEngine = $0 }
                )) {
                    ForEach(LocalPolishEngine.allCases) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }
                .disabled(!settings.enableTextCleanup || settings.isCloudPolishSelected)
                .onChange(of: settings.localPolishEngine) { _, engine in
                    switch engine {
                    case .gemma4_e2b:
                        if settings.shouldUseLocalLLMPolish {
                            GemmaMLXPolisher.shared.prewarm()
                        }
                    case .appleIntelligence:
                        GemmaMLXPolisher.shared.unload()
                        if settings.shouldUseLocalLLMPolish {
                            LocalLLMPolisher.shared.prewarm(
                                personalContext: settings.cleanupPersonalContext,
                                dictionary: settings.dictionaryWords
                            )
                        }
                    case .none:
                        GemmaMLXPolisher.shared.unload()
                    }
                }

                if settings.isCloudPolishSelected {
                    Text("Cloud polish replaces the on-device model. Turn cloud off to use Apple Intelligence or Gemma again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    switch settings.localPolishEngine {
                    case .none:
                        Text(settings.enableHeuristicCleanup
                             ? "On-device LLM polish is off. Heuristic cleanup still runs."
                             : "On-device LLM and heuristic cleanup are off. Fillers like um / uh / hmm are still stripped; the rest is raw ASR unless cloud polish is on.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .appleIntelligence:
                        Text(LocalLLMPolisher.statusMessage)
                            .font(.caption)
                            .foregroundStyle(LocalLLMPolisher.isAvailable ? Color.secondary : Color.orange)
                        if LocalLLMPolisher.needsSystemSettings {
                            Button("Open Apple Intelligence Settings") {
                                LocalLLMPolisher.openAppleIntelligenceSettings()
                            }
                        }
                    case .gemma4_e2b:
                        gemmaStatusRow
                    }
                }

                Picker("Cloud polish", selection: Binding(
                    get: { settings.cloudPolishProvider },
                    set: { settings.cloudPolishProvider = $0 }
                )) {
                    ForEach(CloudPolishProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .disabled(!settings.enableTextCleanup)
                .onChange(of: settings.cloudPolishProvider) { _, provider in
                    if provider == .none {
                        controller.prewarmOnDevicePolish()
                    } else {
                        GemmaMLXPolisher.shared.unload()
                    }
                }

                Text("Audio never leaves your Mac. Cloud polish sends transcript text only when enabled and a key is saved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var promptPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Draft with an LLM")
                        .font(.headline)
                    Text("Copy a setup prompt, paste it into ChatGPT or Claude, and it will interview you, then output About you, Examples, Exceptions, and a dictionary CSV to import.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Copy setup prompt") {
                        copySettingsGeneratorPrompt()
                    }
                    if let promptCopyNote {
                        Text(promptCopyNote)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                promptEditor(
                    title: "About you",
                    caption: "Who you are and how you write. Included in every polish. Keep this short — app-specific rules belong in Exceptions and Dictionary.",
                    placeholder: "Who you are, how you write, timezone, language, names.",
                    text: Binding(
                        get: { settings.cleanupPersonalNotes },
                        set: { settings.cleanupPersonalNotes = $0 }
                    ),
                    lineLimit: 6...12
                )
                promptEditor(
                    title: "Examples",
                    caption: "Input → output pairs that show how you want dictation cleaned. These are not about who you are.",
                    placeholder: "raw dictation → cleaned text",
                    text: Binding(
                        get: { settings.cleanupPersonalExamples },
                        set: { settings.cleanupPersonalExamples = $0 }
                    ),
                    lineLimit: 4...10
                )
                promptEditor(
                    title: "Exceptions",
                    caption: "In Cursor keep comments tight. In Slack stay casual. In Mail, letter polish only if you dictated a letter.",
                    placeholder: "Per-app rules…",
                    text: Binding(
                        get: { settings.cleanupExceptions },
                        set: { settings.cleanupExceptions = $0 }
                    ),
                    lineLimit: 5...10
                )
                VStack(alignment: .leading, spacing: 8) {
                    prefillCommitControls(.systemPrompt)
                    HStack {
                        Button("Restore default drafts") {
                            settings.restoreDefaultPersonalContext()
                        }
                        Button("Clear about you") {
                            settings.clearPersonalContext()
                        }
                        .disabled(settings.cleanupPersonalNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("Clear examples") {
                            settings.clearPersonalExamples()
                        }
                        .disabled(settings.cleanupPersonalExamples.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("Clear exceptions", role: .destructive) {
                            settings.clearExceptions()
                        }
                        .disabled(settings.cleanupExceptions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 680, alignment: .leading)
        }
    }

    private func promptEditor(
        title: String,
        caption: String,
        placeholder: String,
        text: Binding<String>,
        lineLimit: ClosedRange<Int>
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("", text: text, prompt: Text(placeholder), axis: .vertical)
                .lineLimit(lineLimit)
                .font(.body)
                .padding(8)
                .background(.background, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.25))
                )
        }
    }

    private var openAIPane: some View {
        settingsForm {
            Section("API key") {
                APIKeyField(
                    prompt: "sk-…",
                    draft: $openAIKeyDraft,
                    hasSavedKey: settings.hasOpenAIKey,
                    savedKeySuffix: settings.openAIKeySuffix,
                    onSave: { store(openAI: true) },
                    onClear: {
                        openAIKeyDraft = ""
                        settings.openAIAPIKey = ""
                    }
                )
            }
            Section("Model") {
                CloudModelPicker(
                    title: "Model",
                    options: models.openAIModels,
                    modelID: $settings.openAIModel,
                    isLoading: models.isLoadingOpenAI,
                    status: models.openAIStatus,
                    canUpdate: settings.hasOpenAIKey
                ) {
                    Task { await models.fetchOpenAI(apiKey: settings.openAIAPIKey) }
                }
            }
        }
        .onAppear { openAIKeyDraft = "" }
    }

    private var anthropicPane: some View {
        settingsForm {
            Section("API key") {
                APIKeyField(
                    prompt: "sk-ant-…",
                    draft: $anthropicKeyDraft,
                    hasSavedKey: settings.hasAnthropicKey,
                    savedKeySuffix: settings.anthropicKeySuffix,
                    onSave: { store(openAI: false) },
                    onClear: {
                        anthropicKeyDraft = ""
                        settings.anthropicAPIKey = ""
                    }
                )
            }
            Section("Model") {
                CloudModelPicker(
                    title: "Model",
                    options: models.anthropicModels,
                    modelID: $settings.anthropicModel,
                    isLoading: models.isLoadingAnthropic,
                    status: models.anthropicStatus,
                    canUpdate: settings.hasAnthropicKey
                ) {
                    Task { await models.fetchAnthropic(apiKey: settings.anthropicAPIKey) }
                }
            }
        }
        .onAppear { anthropicKeyDraft = "" }
    }

    private var dictionaryPane: some View {
        HStack(spacing: 0) {
            dictionaryAppColumn
                .frame(width: 228)
            Divider()
            dictionaryWordsColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var dictionaryAppColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Apps")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.top, 14)
                .padding(.bottom, 6)
            List(selection: $dictionaryDestination) {
                Text("Every app")
                    .badge(settings.dictionaryWords.count)
                    .tag(DictionaryDestination.everyApp)
                ForEach(settings.appDictionaries) { entry in
                    Text(entry.appName)
                        .badge(entry.terms.count)
                        .tag(DictionaryDestination.app(entry.id))
                }
            }
            .listStyle(.sidebar)
            Text("Select an app to see its words. Those terms are used when you dictate into that app.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(12)
            Button("Other app…") {
                isAddingOtherApp = true
            }
            .padding(.horizontal, 12)
            if isAddingOtherApp {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("App name, like Notion", text: $customAppName)
                        .onSubmit(addOtherAppDictionary)
                    Picker("Kind", selection: $customAppKind) {
                        ForEach(TargetAppContext.Kind.allCases) { kind in
                            Text(kind.menuLabel).tag(kind)
                        }
                    }
                    HStack {
                        Button("Create app", action: addOtherAppDictionary)
                            .disabled(customAppName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("Cancel") {
                            isAddingOtherApp = false
                            customAppName = ""
                        }
                    }
                }
                .padding(12)
            }
            Spacer(minLength: 8)
        }
    }

    private var dictionaryWordsColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(dictionarySectionTitle)
                .font(.headline)
            HStack {
                TextField(dictionaryWordPlaceholder, text: $newDictionaryTerm)
                    .onSubmit(addDictionaryTerm)
                Button("Add word") {
                    addDictionaryTerm()
                }
                .disabled(newDictionaryTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            HStack {
                Button("Import CSV…", action: importDictionaryCSV)
                Button("Export CSV…", action: exportDictionaryCSV)
                Button("Copy template", action: copyDictionaryTemplate)
                Button("Copy setup prompt") {
                    copySettingsGeneratorPrompt()
                }
            }
            Text("Copy setup prompt asks an LLM to draft About you and this CSV. Copy template is an empty CSV. Import, then Update dictionary.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let dictionaryFileNote {
                Text(dictionaryFileNote)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            prefillCommitControls(.dictionary)
            if case .app(let id) = dictionaryDestination,
               settings.appDictionaries.contains(where: { $0.id == id }) {
                Button("Remove app", role: .destructive) {
                    settings.removeAppDictionary(id: id)
                    dictionaryDestination = .everyApp
                }
            }
            if visibleDictionaryWords.isEmpty {
                Text("No words yet.")
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            } else {
                List {
                    ForEach(visibleDictionaryWords, id: \.self) { word in
                        dictionaryWordRow(word) {
                            removeVisibleDictionaryWord(word)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .padding(16)
    }

    private var permissionsPane: some View {
        settingsForm {
            Section {
                LabeledContent("Microphone") {
                    Text(permissions.microphoneGranted ? "Granted" : "Missing")
                        .foregroundStyle(permissions.microphoneGranted ? .green : .orange)
                }
                LabeledContent("Accessibility") {
                    Text(permissions.accessibilityTrusted ? "Granted" : "Missing")
                        .foregroundStyle(permissions.accessibilityTrusted ? .green : .orange)
                }
                LabeledContent("Input Monitoring") {
                    Text(permissions.inputMonitoringTrusted ? "Granted" : "Missing")
                        .foregroundStyle(permissions.inputMonitoringTrusted ? .green : .orange)
                }
                if !permissions.accessibilityTrusted {
                    Text(permissions.accessibilityHelpText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Running from: \(permissions.runningAppPath)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if !permissions.inputMonitoringTrusted {
                    Text(permissions.inputMonitoringHelpText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Request Microphone") {
                        Task { _ = await permissions.requestMicrophone() }
                    }
                    Button("Open Accessibility Settings") {
                        permissions.requestAccessibility()
                    }
                    Button("Open Input Monitoring") {
                        permissions.requestInputMonitoring()
                    }
                    Button("Refresh") {
                        permissions.refresh()
                    }
                }
                if !permissions.accessibilityTrusted || !permissions.inputMonitoringTrusted {
                    Button("Quit & Reopen (needed after enabling these)") {
                        permissions.quitAndRelaunch()
                    }
                }
            }
        }
        .onAppear { permissions.startPolling() }
        .onDisappear { permissions.stopPolling() }
    }

    private func settingsForm<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        Form {
            content()
        }
        .formStyle(.grouped)
        .padding(.trailing, 4)
    }

    @ViewBuilder
    private func prefillCommitControls(_ copy: PrefillCommitCopy) -> some View {
        Button(copy.buttonTitle) {
            settings.commitSystemPrompt()
            controller.prewarmOnDevicePolish()
        }
        .disabled(!settings.isSystemPromptStale)
        if settings.isSystemPromptStale {
            Text(copy.staleMessage)
                .font(.caption)
                .foregroundStyle(.orange)
        } else if settings.cleanupPersonalContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(copy.emptyMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text(copy.currentMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var speechModelHelp: some View {
        switch settings.asrModel.engine {
        case .whisper:
            Text("WhisperKit Core ML. First use downloads weights from Hugging Face.")
        case .parakeet:
            Text("Parakeet TDT 0.6B v2 is NVIDIA’s English model (CC-BY-4.0), running on-device via FluidAudio. First load downloads CoreML weights from Hugging Face.")
        case .appleSpeech:
            Text("On-device Apple SpeechTranscriber (macOS 26). English, even if the system language is Korean. The OS may download a shared speech model on first use. Each take is written to a private temp file and deleted after transcription; audio stays on this Mac.")
        }
    }

    @ViewBuilder
    private var gemmaStatusRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if case .downloading(let fraction) = gemma.status {
                    ProgressView(value: fraction)
                        .frame(width: 80, height: 8)
                } else if gemma.status == .loading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                }
                Text(gemma.statusMessage)
                    .font(.caption)
                    .foregroundStyle(gemma.isReady ? Color.secondary : Color.orange)
                    .textSelection(.enabled)
            }
            Text("Text-only 4-bit MLX weights from Hugging Face (`mlx-community/Gemma4-E2B-IT-Text-int4`). Vision and audio towers are omitted. First load downloads ~2.7 GB and compiles Metal kernels; after that polish should take a few seconds. Gemma is released under Google’s license.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !gemma.isReady {
                Button(gemma.status.isFailed ? "Retry download" : "Download / Load Gemma") {
                    GemmaMLXPolisher.shared.prewarm()
                }
                .disabled(gemma.status.isWorking)
            }
        }
    }

    private var dictionaryWordPlaceholder: String {
        switch dictionaryDestination {
        case .everyApp:
            return "Word for every app"
        case .app(let id):
            let name = settings.appDictionaries.first(where: { $0.id == id })?.appName ?? "this app"
            return "Word for \(name)"
        }
    }

    private var dictionarySectionTitle: String {
        switch dictionaryDestination {
        case .everyApp:
            return "Every app — \(settings.dictionaryWords.count) words"
        case .app(let id):
            let entry = settings.appDictionaries.first(where: { $0.id == id })
            let name = entry?.appName ?? "App"
            return "\(name) — \(entry?.terms.count ?? 0) words"
        }
    }

    private var visibleDictionaryWords: [String] {
        switch dictionaryDestination {
        case .everyApp:
            return settings.dictionaryWords
        case .app(let id):
            return settings.appDictionaries.first(where: { $0.id == id })?.terms ?? []
        }
    }

    @ViewBuilder
    private func dictionaryWordRow(_ word: String, remove: @escaping () -> Void) -> some View {
        HStack {
            Text(word)
            Spacer()
            Button(action: remove) {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Remove word")
        }
    }

    private func removeVisibleDictionaryWord(_ word: String) {
        switch dictionaryDestination {
        case .everyApp:
            settings.removeDictionaryWord(word)
        case .app(let id):
            settings.removeAppDictionaryTerm(id: id, term: word)
        }
    }

    private func store(openAI: Bool) -> Bool {
        if openAI {
            let key = openAIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            let ok = settings.saveOpenAIAPIKey(key)
            if ok, !key.isEmpty {
                Task { await models.fetchOpenAI(apiKey: key) }
            }
            return ok
        }
        let key = anthropicKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let ok = settings.saveAnthropicAPIKey(key)
        if ok, !key.isEmpty {
            Task { await models.fetchAnthropic(apiKey: key) }
        }
        return ok
    }

    private func addDictionaryTerm() {
        let term = newDictionaryTerm
        switch dictionaryDestination {
        case .everyApp:
            settings.addDictionaryWord(term)
        case .app(let id):
            settings.addAppDictionaryTerm(id: id, raw: term)
        }
        newDictionaryTerm = ""
    }

    private func addAppDictionary(_ entry: AppDictionaryEntry) {
        settings.addAppDictionary(entry)
        if let added = settings.appDictionaries.first(where: {
            $0.appName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                == entry.appName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }) {
            dictionaryDestination = .app(added.id)
        }
        isAddingOtherApp = false
        customAppName = ""
        customAppKind = .other
    }

    private func addOtherAppDictionary() {
        let name = customAppName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        addAppDictionary(AppDictionaryEntry(appName: name, kind: customAppKind.rawValue))
    }

    private func copySettingsGeneratorPrompt() {
        let text = CleanupPrompt.settingsGeneratorPrompt(
            personalNotes: settings.cleanupPersonalNotes,
            examples: settings.cleanupPersonalExamples,
            exceptions: settings.cleanupExceptions,
            dictionaryCSV: DictionaryCSV.export(
                globalWords: settings.dictionaryWords,
                apps: settings.appDictionaries,
                exceptions: settings.cleanupExceptions
            )
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        promptCopyNote = "Copied. Paste into ChatGPT, Claude, or another LLM."
        dictionaryFileNote = "Setup prompt copied. Paste the LLM’s CSV via Import CSV, then Update dictionary."
    }

    private func copyDictionaryTemplate() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(DictionaryCSV.template, forType: .string)
        dictionaryFileNote = "Template copied. Paste it into ChatGPT or Claude, then Import CSV."
    }

    private func exportDictionaryCSV() {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "whisperlocal-dictionary.csv"
        panel.message = "CSV for every-app words, per-app words, and optional exceptions."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = DictionaryCSV.export(
            globalWords: settings.dictionaryWords,
            apps: settings.appDictionaries,
            exceptions: settings.cleanupExceptions
        )
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            dictionaryFileNote = "Exported. Fill it with an LLM, then Import CSV."
        } catch {
            presentDictionaryFileError(error)
        }
    }

    private func importDictionaryCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Columns: app, kind, word, exception. Empty app = every app."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let snapshot = try DictionaryCSV.parse(text)
            let alert = NSAlert()
            alert.messageText = "Import dictionary CSV"
            alert.informativeText = DictionaryCSV.summary(snapshot)
            alert.addButton(withTitle: "Merge")
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                settings.applyDictionarySnapshot(snapshot, replace: false)
            case .alertSecondButtonReturn:
                settings.applyDictionarySnapshot(snapshot, replace: true)
            default:
                return
            }
            dictionaryFileNote = "Imported. Click Update dictionary to apply."
        } catch {
            presentDictionaryFileError(error)
        }
    }

    private func presentDictionaryFileError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Could not read the dictionary CSV"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}

/// Hide the window-title string in the traffic-light strip so it doesn't sit to the left of the sidebar.
/// NavigationSplitView then shows the title in the detail column.
private struct SettingsWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        SettingsWindowChromeView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class SettingsWindowChromeView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        apply()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        apply()
    }

    private func apply() {
        guard let window else { return }
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
    }
}

private enum PrefillCommitCopy {
    case systemPrompt
    case dictionary

    var buttonTitle: String {
        switch self {
        case .systemPrompt: return "Set system prompt"
        case .dictionary: return "Update dictionary"
        }
    }

    var staleMessage: String {
        switch self {
        case .systemPrompt:
            return "Unsaved drafts — polish still uses the last Set system prompt."
        case .dictionary:
            return "Unsaved changes — polish still uses the last update."
        }
    }

    var emptyMessage: String {
        switch self {
        case .systemPrompt:
            return "No custom prompt is set. Built-in cleanup rules still run."
        case .dictionary:
            return "No custom dictionary is applied to polish yet."
        }
    }

    var currentMessage: String {
        switch self {
        case .systemPrompt: return "Prefill is up to date."
        case .dictionary: return "Dictionary is up to date."
        }
    }
}

private enum DictionaryDestination: Hashable, Identifiable {
    case everyApp
    case app(UUID)

    var id: String {
        switch self {
        case .everyApp: return "every"
        case .app(let id): return id.uuidString
        }
    }
}

private struct APIKeyField: View {
    let prompt: String
    @Binding var draft: String
    let hasSavedKey: Bool
    let savedKeySuffix: String?
    let onSave: () -> Bool
    let onClear: () -> Void

    @State private var showKey = false
    @State private var saveNote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showKey {
                TextField(prompt, text: $draft)
                    .font(.body.monospaced())
                    .textFieldStyle(.roundedBorder)
            } else {
                SecureField(prompt, text: $draft)
                    .font(.body.monospaced())
                    .textFieldStyle(.roundedBorder)
            }
            Text(statusLine)
                .font(.caption)
                .foregroundStyle(hasSavedKey ? Color.secondary : Color.orange)
            if let saveNote {
                Text(saveNote)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Text("The key stays in the Keychain. Audio never leaves this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Paste") {
                    pasteFromClipboard()
                }
                Button(showKey ? "Hide key" : "Show key") {
                    showKey.toggle()
                }
                Button("Save key", action: save)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Remove key", role: .destructive, action: {
                    saveNote = nil
                    onClear()
                })
                .disabled(!hasSavedKey && draft.isEmpty)
            }
        }
    }

    private var statusLine: String {
        if !hasSavedKey {
            return "No key saved yet."
        }
        if let suffix = savedKeySuffix, !suffix.isEmpty {
            return "Key saved in Keychain · ends with \(suffix)"
        }
        return "Key saved in Keychain."
    }

    private func pasteFromClipboard() {
        let pasted = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !pasted.isEmpty else {
            saveNote = "Clipboard is empty."
            return
        }
        draft = pasted
        saveNote = nil
    }

    private func save() {
        let ok = onSave()
        if ok {
            saveNote = nil
        } else {
            saveNote = "Keychain did not store the key. Try again, or check Keychain Access."
        }
    }
}

private struct CloudModelPicker: View {
    let title: String
    let options: [CloudModelOption]
    @Binding var modelID: String
    let isLoading: Bool
    let status: String?
    let canUpdate: Bool
    let onUpdate: () -> Void

    private var selection: Binding<String> {
        Binding(
            get: {
                if options.contains(where: { $0.id == modelID }) {
                    return modelID
                }
                return options.first?.id ?? ""
            },
            set: { newValue in
                guard options.contains(where: { $0.id == newValue }) else { return }
                modelID = newValue
            }
        )
    }

    var body: some View {
        if options.isEmpty {
            Text("No models yet. Save a key and hit Update models.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Picker(title, selection: selection) {
                ForEach(options) { option in
                    Text(option.pickerLabel).tag(option.id)
                }
            }
            .onChange(of: options.map(\.id)) { _, ids in
                if !ids.contains(modelID), let first = ids.first {
                    modelID = first
                }
            }
        }
        HStack {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 16, height: 16)
            }
            Button("Update models") {
                onUpdate()
            }
            .disabled(!canUpdate || isLoading)
        }
        if let status, !status.isEmpty {
            Text(status)
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if !canUpdate {
            Text("Save an API key, then Update models to refresh the list.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
