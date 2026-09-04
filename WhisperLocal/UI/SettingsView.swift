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

private enum PolishWhere: String, Hashable {
    case onDevice
    case cloud
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
                    Label {
                        HStack {
                            Text(item.title)
                            Spacer(minLength: 4)
                            if sidebarShowsSavedKey(for: item) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .imageScale(.small)
                                    .accessibilityLabel("API key saved")
                            }
                        }
                    } icon: {
                        Image(systemName: item.icon)
                    }
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
            .navigationTitle(AppIdentity.settingsWindowTitle)
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
            if AppIdentity.isDevBuild {
                Section {
                    Text("This is the Dev app \(AppIdentity.versionSummary). It does not replace /Applications/WhisperLocal.app. Default hotkey is Right Option so Globe / Fn stays on the public copy. Grant Microphone, Accessibility, and Input Monitoring for WhisperLocal Dev separately.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
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
                helpText("Hold Shift during a take to capture session context instead of pasting. Set it up under Polish.")

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
                Toggle("Ignore audio playing on this Mac", isOn: $settings.enableEchoCancellation)
                helpText(
                    "Music and video coming out of this Mac’s own speakers are less likely to end up in your transcript. Playback dips while you talk.",
                    more: "Known as echo cancellation. Off by default, because it changes what the speech model hears whether or not anything is playing, and because it does nothing on headphones — the mic never hears those in the first place. Cancellation is weakest when two voices overlap, so someone talking in a video can still get through while you are talking."
                )
                Toggle("Use the built-in mic while headphones are playing", isOn: $settings.preferBuiltInMicOverBluetooth)
                helpText(
                    "Keeps music and video playing at full quality while you dictate.",
                    more: "AirPods and most Bluetooth headsets cannot play high-quality audio and record at the same time — opening their mic drops playback to narrowband mono until the take ends. Their mic is also a worse input for speech recognition than the built-in array. Turn this off if you dictate away from your Mac and need the headset mic."
                )
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
                helpText(
                    "Saves recent takes as local JSON, text only.",
                    more: "Turning this off skips new entries; the existing log is not deleted. Polish can reuse these takes to match your style, but that stays off until you enable it on the Polish page."
                )
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
                Text("Polish with Apple Intelligence, Gemma, or cloud. If the model fails, text is still pasted. Um / uh / hmm are always dropped while this is on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("How dictation is polished") {
                polishInUseBanner
                Text("This is the polish that runs after speech-to-text. Choose one option — it stays in effect until you choose the other.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                polishModeCard(
                    .onDevice,
                    title: "On this Mac",
                    subtitle: "Apple Intelligence or Gemma. Text stays on this Mac."
                ) {
                    onDevicePolishControls
                }

                polishModeCard(
                    .cloud,
                    title: "Cloud",
                    subtitle: "OpenAI or Anthropic. Transcript text is sent; audio is not."
                ) {
                    cloudPolishControls
                }
            }

            Section {
                Text("Audio never leaves your Mac. Cloud polish sends transcript text only when Cloud is selected and a key is saved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Include recent dictations in polish", isOn: $settings.includeRecentPolishLogs)
                    .disabled(!settings.enableDictationLog || !settings.enableTextCleanup)
                if settings.includeRecentPolishLogs {
                    Picker("How many", selection: Binding(
                        get: { settings.recentPolishLogCount },
                        set: { settings.recentPolishLogCount = $0 }
                    )) {
                        ForEach(CleanupPrompt.recentPolishLogCounts, id: \.self) { count in
                            Text(count == 1 ? "Last take" : "Last \(count) takes").tag(count)
                        }
                    }
                    .disabled(!settings.enableDictationLog || !settings.enableTextCleanup)
                }
                recentPolishLogsHelp

                Toggle("Spoken session context", isOn: $settings.enableSessionContext)
                    .disabled(!settings.enableTextCleanup)
                sessionContextHelp
                if settings.enableSessionContext {
                    // The editor has its own window, reachable from the menu bar.
                    // A second copy here made Polish carry a whole other feature.
                    LabeledContent("Current context") {
                        HStack(spacing: 10) {
                            Text(controller.hasActiveSessionContext
                                 ? controller.sessionContextText
                                 : "Not set")
                                .foregroundStyle(controller.hasActiveSessionContext ? .primary : .secondary)
                                .lineLimit(2)
                            Spacer(minLength: 8)
                            Button("Edit…") {
                                AppWindowFocus.present(title: "Session context") {
                                    openWindow(id: "session-context")
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var selectedPolishWhere: PolishWhere {
        settings.isCloudPolishSelected ? .cloud : .onDevice
    }

    private var polishWhereBinding: Binding<PolishWhere> {
        Binding(
            get: { selectedPolishWhere },
            set: { destination in
                switch destination {
                case .onDevice:
                    applyCloudPolish(.none)
                case .cloud:
                    applyCloudPolish(settings.preferredCloudProvider)
                }
            }
        )
    }

    private var polishInUseBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: polishInUseSymbol)
                .foregroundStyle(polishInUseTint)
                .font(.title2)
                .frame(width: 28, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(polishInUseTitle)
                    .font(.body.weight(.semibold))
                Text(polishInUseDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            polishInUseTint.opacity(0.12),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(polishInUseTitle)
        .accessibilityValue(polishInUseDetail)
    }

    private var polishInUseSymbol: String {
        if !settings.enableTextCleanup { return "pause.circle.fill" }
        return settings.isCloudPolishSelected ? "cloud.fill" : "laptopcomputer"
    }

    private var polishInUseTint: Color {
        if !settings.enableTextCleanup { return .orange }
        return settings.isCloudPolishSelected ? .blue : .green
    }

    private var polishInUseTitle: String {
        if !settings.enableTextCleanup {
            return "Not polishing"
        }
        if settings.isCloudPolishSelected {
            return "In use: Cloud · \(settings.cloudPolishProvider.displayName)"
        }
        return "In use: On this Mac · \(settings.localPolishEngine.shortName)"
    }

    private var polishInUseDetail: String {
        if !settings.enableTextCleanup {
            return "Turn on text cleanup to polish dictation. The choice below is saved but not running."
        }
        if settings.isCloudPolishSelected {
            return "Every dictation is polished with \(settings.cloudPolishProvider.displayName) until you choose On this Mac."
        }
        switch settings.localPolishEngine {
        case .none:
            return "No on-device LLM. Choose Cloud below if you want OpenAI or Anthropic to polish instead."
        case .appleIntelligence, .gemma4_e2b:
            return "Every dictation is polished on this Mac until you choose Cloud."
        }
    }

    private func polishModeCard<Content: View>(
        _ destination: PolishWhere,
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let selected = selectedPolishWhere == destination
        return VStack(alignment: .leading, spacing: 10) {
            Button {
                polishWhereBinding.wrappedValue = destination
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: selected ? "circle.inset.filled" : "circle")
                        .font(.body)
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                        .frame(width: 20, alignment: .center)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(title)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.primary)
                            if selected, settings.enableTextCleanup {
                                Text("In use")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(Color.accentColor, in: Capsule())
                            }
                            Spacer(minLength: 0)
                        }
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!settings.enableTextCleanup)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityLabel(title)
            .accessibilityValue(selected ? "In use" : "Not in use")
            .accessibilityHint("Sets how dictation is polished")

            if !selected, settings.enableTextCleanup {
                Text("Click to polish dictation this way.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 30)
            }

            content()
                .disabled(!selected || !settings.enableTextCleanup)
                .opacity(selected && settings.enableTextCleanup ? 1 : 0.4)
                .padding(.leading, 30)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            (selected && settings.enableTextCleanup ? Color.accentColor : Color.secondary)
                .opacity(selected && settings.enableTextCleanup ? 0.10 : 0.06),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    selected && settings.enableTextCleanup
                        ? Color.accentColor.opacity(0.45)
                        : Color.secondary.opacity(0.18)
                )
        )
    }

    @ViewBuilder
    private var onDevicePolishControls: some View {
        Picker("On-device model", selection: Binding(
            get: { settings.localPolishEngine },
            set: { settings.localPolishEngine = $0 }
        )) {
            ForEach(LocalPolishEngine.allCases) { engine in
                Text(engine.displayName).tag(engine)
            }
        }
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

        switch settings.localPolishEngine {
        case .none:
            Text("No on-device LLM. Fillers like um / uh / hmm are still stripped. Switch to Cloud to polish with OpenAI or Anthropic.")
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

    @ViewBuilder
    private var cloudPolishControls: some View {
        Picker("Provider", selection: Binding(
            get: { displayedCloudProvider },
            set: { applyCloudPolish($0) }
        )) {
            ForEach(CloudPolishProvider.cloudCases) { option in
                Text(option.displayName).tag(option)
            }
        }

        switch displayedCloudProvider {
        case .none:
            EmptyView()
        case .openAI:
            Button(settings.hasOpenAIKey ? "OpenAI settings…" : "Add OpenAI API key…") {
                page = .openai
            }
            Text(cloudKeyStatusLine(
                hasKey: settings.hasOpenAIKey,
                suffix: settings.openAIKeySuffix
            ))
            .font(.caption)
            .foregroundStyle(settings.hasOpenAIKey ? Color.secondary : Color.orange)
        case .anthropic:
            Button(settings.hasAnthropicKey ? "Anthropic settings…" : "Add Anthropic API key…") {
                page = .anthropic
            }
            Text(cloudKeyStatusLine(
                hasKey: settings.hasAnthropicKey,
                suffix: settings.anthropicKeySuffix
            ))
            .font(.caption)
            .foregroundStyle(settings.hasAnthropicKey ? Color.secondary : Color.orange)
        }
    }

    private var displayedCloudProvider: CloudPolishProvider {
        if settings.isCloudPolishSelected, settings.cloudPolishProvider != .none {
            return settings.cloudPolishProvider
        }
        return settings.preferredCloudProvider
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
                    lineLimit: 6...12,
                    onClear: { settings.clearPersonalContext() }
                )
                promptEditor(
                    title: "Examples",
                    caption: "Input → output pairs that show how you want dictation cleaned. These are not about who you are.",
                    placeholder: "raw dictation → cleaned text",
                    text: Binding(
                        get: { settings.cleanupPersonalExamples },
                        set: { settings.cleanupPersonalExamples = $0 }
                    ),
                    lineLimit: 4...10,
                    onClear: { settings.clearPersonalExamples() }
                )
                promptEditor(
                    title: "Exceptions",
                    caption: "In Cursor keep comments tight. In Slack stay casual. In Mail, letter polish only if you dictated a letter.",
                    placeholder: "Per-app rules…",
                    text: Binding(
                        get: { settings.cleanupExceptions },
                        set: { settings.cleanupExceptions = $0 }
                    ),
                    lineLimit: 5...10,
                    onClear: { settings.clearExceptions() }
                )
                VStack(alignment: .leading, spacing: 8) {
                    prefillCommitControls
                    Button("Restore default drafts") {
                        settings.restoreDefaultPersonalContext()
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
        lineLimit: ClosedRange<Int>,
        onClear: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Clear sits on the thing it clears. Three "Clear X" buttons in a shared
            // footer made the reader pair button to editor themselves.
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.headline)
                Spacer(minLength: 8)
                Button("Clear", action: onClear)
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .disabled(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
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
                    loadSavedKey: { settings.openAIAPIKey },
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
            cloudProviderActivationSection(.openAI)
        }
    }

    private var anthropicPane: some View {
        settingsForm {
            Section("API key") {
                APIKeyField(
                    prompt: "sk-ant-…",
                    draft: $anthropicKeyDraft,
                    hasSavedKey: settings.hasAnthropicKey,
                    savedKeySuffix: settings.anthropicKeySuffix,
                    loadSavedKey: { settings.anthropicAPIKey },
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
            cloudProviderActivationSection(.anthropic)
        }
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
            // One menu instead of three equal-weight buttons: importing is the task,
            // export and template are the occasional helpers around it.
            HStack {
                Menu("CSV") {
                    Button("Import…", action: importDictionaryCSV)
                    Divider()
                    Button("Export…", action: exportDictionaryCSV)
                    Button("Copy blank template", action: copyDictionaryTemplate)
                }
                .fixedSize()
                Spacer()
            }
            Text("Changes here apply as you make them. To have an LLM draft a dictionary for you, use Copy setup prompt on the System prompt page.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let dictionaryFileNote {
                Text(dictionaryFileNote)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if case .app(let id) = dictionaryDestination,
               settings.appDictionaries.contains(where: { $0.id == id }) {
                Button("Remove app", role: .destructive) {
                    settings.removeAppDictionary(id: id)
                    dictionaryDestination = .everyApp
                    publishDictionaryChange()
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
                // The fix belongs on the row that needs it. A flat row of buttons
                // underneath made the reader match button to permission themselves.
                permissionRow("Microphone", granted: permissions.microphoneGranted, action: "Grant") {
                    Task { _ = await permissions.requestMicrophone() }
                }
                permissionRow("Accessibility", granted: permissions.accessibilityTrusted, action: "Open Settings") {
                    permissions.requestAccessibility()
                }
                permissionRow("Input Monitoring", granted: permissions.inputMonitoringTrusted, action: "Open Settings") {
                    permissions.requestInputMonitoring()
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
                // No Refresh button: this pane polls once a second while it is open,
                // so the rows above update themselves.
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

    private func permissionRow(
        _ title: String,
        granted: Bool,
        action: String,
        perform: @escaping () -> Void
    ) -> some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Text(granted ? "Granted" : "Missing")
                    .foregroundStyle(granted ? .green : .orange)
                if !granted {
                    Button(action, action: perform)
                }
            }
        }
    }

    /// A summary line, with the rest behind a disclosure. Long captions were burying
    /// the controls they explain, but the detail is real — licensing, privacy, where
    /// downloads come from — so it is folded away rather than cut.
    @ViewBuilder
    private func helpText(_ summary: String, more: String? = nil) -> some View {
        if let more {
            VStack(alignment: .leading, spacing: 2) {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                DisclosureGroup("More") {
                    Text(more)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 2)
                }
                .font(.caption)
            }
        } else {
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func settingsForm<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        Form {
            content()
        }
        .formStyle(.grouped)
        .padding(.trailing, 4)
    }

    /// The one place the assembled prompt is published. The Dictionary page used to
    /// show a second copy of this button under a different name, which committed the
    /// same thing — including whatever was typed here.
    private var prefillCommitControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                settings.commitSystemPrompt()
                controller.prewarmOnDevicePolish()
            } label: {
                Label("Save system prompt", systemImage: "square.and.arrow.down")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .disabled(!settings.isSystemPromptStale)
            .help("Applies About you, Examples, and Exceptions to polish. Until you save, dictation uses the previous prompt.")

            if settings.isSystemPromptStale {
                Text("Unsaved drafts — polish still uses the last saved system prompt.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if settings.cleanupPersonalContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("No custom prompt is set. Built-in cleanup rules still run.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Prefill is up to date.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var sessionContextHelp: some View {
        let hotkey = hotKey.selectedKey.displayName
        var detail = "It becomes a short topic that rides along with later polish so names and jargon resolve, then clears after 45 minutes idle or a few off-topic takes. Nothing is pasted, and it is never saved into your system prompt or kept across launches."
        if settings.hasUsableCloudPolish {
            detail += " With cloud polish, that text also goes to the API."
        }
        return helpText(
            "Hold Shift during a take, or start with Shift + \(hotkey), to capture context instead of pasting — the orange CONTEXT badge shows which you will get.",
            more: detail
        )
    }

    @ViewBuilder
    private var recentPolishLogsHelp: some View {
        if !settings.enableDictationLog {
            helpText("Turn on the dictation log on the Dictation page first.")
        } else if settings.hasUsableCloudPolish {
            helpText(
                "Sends your last few takes with each polish request so the model matches your names and tone.",
                more: "Off by default. Adds tokens and latency, and with cloud polish that text goes to the API too. These takes are never written into your system prompt."
            )
        } else {
            helpText(
                "Sends your last few takes with each polish request so the model matches your names and tone.",
                more: "Off by default. Adds latency. On-device models have a small context window, so at most three shortened examples are sent. These takes are never written into your system prompt."
            )
        }
    }

    @ViewBuilder
    private var speechModelHelp: some View {
        switch settings.asrModel.engine {
        case .whisper:
            helpText(
                "WhisperKit Core ML, running on this Mac.",
                more: "First use downloads weights from Hugging Face."
            )
        case .parakeet:
            helpText(
                "NVIDIA Parakeet TDT 0.6B v2, running on this Mac.",
                more: "English only, CC-BY-4.0, via FluidAudio. First load downloads Core ML weights from Hugging Face."
            )
        case .appleSpeech:
            helpText(
                "Apple’s on-device transcriber (macOS 26). English only.",
                more: "English even if that is not your system language. The OS may download a shared speech model on first use. Each take is written to a private temp file and deleted after transcription; audio stays on this Mac."
            )
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
            helpText(
                "Text-only 4-bit MLX weights. First load downloads about 2.7 GB.",
                more: "Weights come from Hugging Face (`mlx-community/Gemma4-E2B-IT-Text-int4`); the vision and audio towers are omitted. First load also compiles Metal kernels, after which polish should take a few seconds. Gemma is released under Google’s license."
            )
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
        publishDictionaryChange()
    }

    private func sidebarShowsSavedKey(for page: SettingsPage) -> Bool {
        switch page {
        case .openai: return settings.hasOpenAIKey
        case .anthropic: return settings.hasAnthropicKey
        default: return false
        }
    }

    private func cloudKeyStatusLine(hasKey: Bool, suffix: String?) -> String {
        guard hasKey else { return "No API key saved yet." }
        if let suffix, !suffix.isEmpty {
            return "API key is saved in Keychain · ends with \(suffix)"
        }
        return "API key is saved in Keychain."
    }

    private func store(openAI: Bool) -> Bool {
        if openAI {
            let key = openAIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            let ok = settings.saveOpenAIAPIKey(key)
            if ok, !key.isEmpty {
                Task { await models.fetchOpenAI(apiKey: key) }
                if settings.cloudPolishProvider == .none {
                    applyCloudPolish(.openAI)
                }
            }
            return ok
        }
        let key = anthropicKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let ok = settings.saveAnthropicAPIKey(key)
        if ok, !key.isEmpty {
            Task { await models.fetchAnthropic(apiKey: key) }
            if settings.cloudPolishProvider == .none {
                applyCloudPolish(.anthropic)
            }
        }
        return ok
    }

    /// Turns cloud polish on for this provider and optionally shows the Polish page.
    private func applyCloudPolish(_ provider: CloudPolishProvider) {
        if provider != .none {
            settings.enableTextCleanup = true
        }
        settings.cloudPolishProvider = provider
        if provider == .none {
            controller.prewarmOnDevicePolish()
        } else {
            GemmaMLXPolisher.shared.unload()
        }
    }

    @ViewBuilder
    private func cloudProviderActivationSection(_ provider: CloudPolishProvider) -> some View {
        let isCurrent = settings.cloudPolishProvider == provider
        let hasKey = provider == .openAI ? settings.hasOpenAIKey : settings.hasAnthropicKey
        let name = provider.displayName

        Section("Cloud polish") {
            if isCurrent {
                Text("Polish is using \(name). To polish on this Mac with Apple Intelligence or Gemma instead, change it on the Polish page.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Show Polish settings") {
                    page = .polish
                }
            } else {
                // Activates in place. This used to jump to the Polish page, so the two
                // pages bounced the reader between them mid-setup.
                Button {
                    applyCloudPolish(provider)
                } label: {
                    Label("Use \(name) for cloud polish", systemImage: "checkmark.circle.fill")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .disabled(!hasKey)
                if !hasKey {
                    Text("Save an API key first.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if settings.cloudPolishProvider != .none {
                    Text("Switches cloud polish from \(settings.cloudPolishProvider.displayName) to \(name).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Turns on cloud polish for \(name).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// App dictionaries reach polish through the assembled system prompt, so a change
    /// here has to be published to take effect. Every-app words are passed straight to
    /// the polisher and leave the prompt untouched, so this no-ops for them — which is
    /// why the old "Update dictionary" button sat greyed out for the commonest edit.
    private func publishDictionaryChange() {
        guard settings.isSystemPromptStale else { return }
        settings.commitSystemPrompt()
        controller.prewarmOnDevicePolish()
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
        publishDictionaryChange()
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
        publishDictionaryChange()
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
        dictionaryFileNote = "Setup prompt copied. Paste the LLM’s CSV via CSV → Import."
    }

    private func copyDictionaryTemplate() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(DictionaryCSV.template, forType: .string)
        dictionaryFileNote = "Template copied. Paste it into ChatGPT or Claude, then CSV → Import."
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
            dictionaryFileNote = "Exported. Fill it with an LLM, then CSV → Import."
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
            publishDictionaryChange()
            dictionaryFileNote = "Imported and applied."
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
    let loadSavedKey: () -> String
    let onSave: () -> Bool
    let onClear: () -> Void

    @State private var showKey = false
    @State private var saveNote: String?
    @State private var saveNoteIsError = false

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Empty draft + saved key: show a filled mask, not a blank field.
    private var showsSavedMask: Bool {
        hasSavedKey && !showKey && trimmedDraft.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusBanner

            // Reveal belongs in the field, not in the button row underneath. ⌘V
            // already pastes, so a Paste button was a third way to do one thing.
            HStack(spacing: 6) {
                if showsSavedMask {
                    maskedKeyPreview
                } else if showKey {
                    TextField(prompt, text: $draft)
                        .font(.body.monospaced())
                        .textFieldStyle(.roundedBorder)
                        .textSelection(.enabled)
                } else {
                    SecureField(prompt, text: $draft)
                        .font(.body.monospaced())
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.password)
                }
                Button {
                    toggleReveal()
                } label: {
                    Image(systemName: showKey ? "eye.slash" : "eye")
                        .frame(width: 16)
                }
                .buttonStyle(.borderless)
                .disabled(!hasSavedKey && trimmedDraft.isEmpty)
                .help(showKey ? "Hide API key" : "Show API key")
                .accessibilityLabel(showKey ? "Hide API key" : "Show API key")
            }

            if let fieldHint {
                Text(fieldHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let saveNote {
                Text(saveNote)
                    .font(.caption)
                    .foregroundStyle(saveNoteIsError ? Color.orange : Color.green)
            }

            Text("The key stays in the Keychain on this Mac. Audio never leaves this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Save key", action: save)
                    .disabled(trimmedDraft.isEmpty)
                Button("Remove key", role: .destructive, action: remove)
                    .disabled(!hasSavedKey && draft.isEmpty)
            }
        }
        .onAppear {
            if hasSavedKey, !showKey {
                draft = ""
            }
        }
        .onChange(of: hasSavedKey) { _, saved in
            if !saved {
                showKey = false
            } else if !showKey {
                draft = ""
            }
        }
    }

    private var fieldHint: String? {
        if showsSavedMask {
            return "Use the eye button to see the full key, or paste a new one to replace it."
        }
        if !trimmedDraft.isEmpty, !showKey, hasSavedKey {
            return "Unsaved replacement. Click Save key to store it."
        }
        if !trimmedDraft.isEmpty, showKey, hasSavedKey {
            return "This is the saved key. Edit it and click Save key to replace it."
        }
        if !trimmedDraft.isEmpty, !hasSavedKey {
            return "Click Save key to store this in Keychain."
        }
        return nil
    }

    private var maskedKeyPreview: some View {
        HStack(spacing: 6) {
            Text(APIKeyMask.preview(suffix: savedKeySuffix))
                .font(.body.monospaced())
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.green.opacity(0.45))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Saved API key")
        .accessibilityValue(savedKeySuffix.map { "Ends with \($0)" } ?? "Hidden")
    }

    private var statusBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: hasSavedKey ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(hasSavedKey ? Color.green : Color.orange)
                .font(.title2)
                .frame(width: 28, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(hasSavedKey ? "API key is saved" : "No API key saved")
                    .font(.body.weight(.semibold))
                Text(statusDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            (hasSavedKey ? Color.green : Color.orange).opacity(0.12),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(hasSavedKey ? "API key is saved" : "No API key saved")
        .accessibilityValue(statusDetail)
    }

    private var statusDetail: String {
        if !hasSavedKey {
            return "Paste a key and click Save key. WhisperLocal stores it in Keychain."
        }
        if let suffix = savedKeySuffix, !suffix.isEmpty {
            return "Stored in Keychain on this Mac · ends with \(suffix)"
        }
        return "Stored in Keychain on this Mac."
    }

    private func toggleReveal() {
        if showKey {
            hideRevealedKey()
            return
        }
        if trimmedDraft.isEmpty {
            let stored = loadSavedKey()
            if stored.isEmpty {
                saveNoteIsError = true
                saveNote = hasSavedKey
                    ? "Could not read the key from Keychain."
                    : "No API key to show."
                return
            }
            draft = stored
        }
        showKey = true
        saveNote = nil
    }

    private func hideRevealedKey() {
        showKey = false
        saveNote = nil
        if hasSavedKey {
            let stored = loadSavedKey()
            if trimmedDraft.isEmpty || trimmedDraft == stored {
                draft = ""
            }
        }
    }

    private func save() {
        let ok = onSave()
        if ok {
            showKey = false
            draft = ""
            saveNoteIsError = false
            saveNote = "Saved to Keychain."
        } else {
            saveNoteIsError = true
            saveNote = "Keychain did not store the key. Try again, or check Keychain Access."
        }
    }

    private func remove() {
        showKey = false
        onClear()
        draft = ""
        saveNoteIsError = false
        saveNote = "Key removed from Keychain."
    }
}

private enum APIKeyMask {
    static func preview(suffix: String?, bulletCount: Int = 20) -> String {
        let bullets = String(repeating: "•", count: max(8, bulletCount))
        guard let suffix, !suffix.isEmpty else { return bullets }
        return bullets + suffix
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
