import SwiftUI

struct SettingsView: View {
    @ObservedObject var controller: DictationController
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var permissions = PermissionManager.shared
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var models = CloudModelCatalog.shared

    @State private var openAIKeyDraft = ""
    @State private var anthropicKeyDraft = ""
    @State private var newDictionaryTerm = ""

    var body: some View {
        Form {
            Section("Dictation") {
                Picker("Hotkey", selection: Binding(
                    get: { controller.hotKey.selectedKey },
                    set: { controller.hotKey.selectedKey = $0 }
                )) {
                    ForEach(HotKeyManager.KeyChoice.allCases) { key in
                        Text(key.displayName).tag(key)
                    }
                }
                Picker("Mode", selection: Binding(
                    get: { controller.hotKey.mode },
                    set: { controller.hotKey.mode = $0 }
                )) {
                    ForEach(HotkeyMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                Text(controller.hotKey.mode.helpText)
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
                Text("Parakeet TDT 0.6B v2 is NVIDIA’s English model (CC-BY-4.0), running on-device via FluidAudio. First load downloads CoreML weights from Hugging Face.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("Speech status") {
                    HStack(spacing: 8) {
                        if controller.transcription.isLoadingModel {
                            ProgressView().controlSize(.small)
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

            Section("Polish") {
                Toggle("Enable text cleanup", isOn: $settings.enableTextCleanup)
                Text("Heuristic cleanup always runs locally, then Apple Intelligence or cloud polish — not both. If AI cleanup fails, text is still pasted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("On-device Apple Intelligence polish", isOn: Binding(
                    get: { settings.shouldUseLocalLLMPolish },
                    set: { settings.useLocalLLMPolish = $0 }
                ))
                .disabled(!settings.enableTextCleanup || settings.isCloudPolishSelected)
                .onChange(of: settings.useLocalLLMPolish) { _, enabled in
                    if enabled, settings.shouldUseLocalLLMPolish {
                        LocalLLMPolisher.shared.prewarm(
                            personalContext: settings.cleanupPersonalContext,
                            dictionary: settings.dictionaryWords
                        )
                    }
                }
                if settings.isCloudPolishSelected {
                    Text("Cloud polish replaces Apple Intelligence. Turn cloud off to use the on-device model again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(LocalLLMPolisher.statusMessage)
                        .font(.caption)
                        .foregroundStyle(LocalLLMPolisher.isAvailable ? Color.secondary : Color.orange)
                }
                if LocalLLMPolisher.needsSystemSettings, !settings.isCloudPolishSelected {
                    Button("Open Apple Intelligence Settings") {
                        LocalLLMPolisher.openAppleIntelligenceSettings()
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

                Text("Audio never leaves your Mac. Cloud polish sends transcript text only when enabled and a key is saved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Custom instructions") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("About you")
                        .font(.headline)
                    VisiblePlaceholderEditor(
                        placeholder: "Who you are, how you write, timezone, language, and anything cleanup should remember.",
                        text: Binding(
                            get: { settings.cleanupPersonalContext },
                            set: { settings.cleanupPersonalContext = $0 }
                        )
                    )
                    Text("Added to the polish prompt for Apple Intelligence and cloud cleanup. Built-in rules still apply: clean the transcript, never answer it. Changes apply to the next dictation.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Restore default") {
                            settings.restoreDefaultPersonalContext()
                        }
                        Button("Clear", role: .destructive) {
                            settings.clearPersonalContext()
                        }
                        .disabled(settings.cleanupPersonalContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("OpenAI") {
                APIKeyField(
                    title: "API key",
                    prompt: "Paste your OpenAI key (starts with sk-)",
                    draft: $openAIKeyDraft,
                    savedKey: settings.openAIAPIKey,
                    onSave: {
                        settings.openAIAPIKey = openAIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        Task { await models.fetchOpenAI(apiKey: settings.openAIAPIKey) }
                    },
                    onClear: {
                        openAIKeyDraft = ""
                        settings.openAIAPIKey = ""
                    }
                )
                .onAppear { openAIKeyDraft = settings.openAIAPIKey }
                CloudModelPicker(
                    title: "Model",
                    options: models.openAIModels,
                    modelID: $settings.openAIModel,
                    isLoading: models.isLoadingOpenAI,
                    status: models.openAIStatus,
                    canUpdate: !settings.openAIAPIKey.isEmpty
                ) {
                    Task { await models.fetchOpenAI(apiKey: settings.openAIAPIKey) }
                }
            }

            Section("Anthropic") {
                APIKeyField(
                    title: "API key",
                    prompt: "Paste your Anthropic key (starts with sk-ant-)",
                    draft: $anthropicKeyDraft,
                    savedKey: settings.anthropicAPIKey,
                    onSave: {
                        settings.anthropicAPIKey = anthropicKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        Task { await models.fetchAnthropic(apiKey: settings.anthropicAPIKey) }
                    },
                    onClear: {
                        anthropicKeyDraft = ""
                        settings.anthropicAPIKey = ""
                    }
                )
                .onAppear { anthropicKeyDraft = settings.anthropicAPIKey }
                CloudModelPicker(
                    title: "Model",
                    options: models.anthropicModels,
                    modelID: $settings.anthropicModel,
                    isLoading: models.isLoadingAnthropic,
                    status: models.anthropicStatus,
                    canUpdate: !settings.anthropicAPIKey.isEmpty
                ) {
                    Task { await models.fetchAnthropic(apiKey: settings.anthropicAPIKey) }
                }
            }

            Section("Personal dictionary") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 8) {
                        VisiblePlaceholderField(
                            placeholder: "Add a name or term",
                            text: $newDictionaryTerm,
                            onSubmit: addDictionaryTerm
                        )
                        Button("Add") {
                            addDictionaryTerm()
                        }
                        .disabled(newDictionaryTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    Text("Names and terms Whisper should spell exactly. Add or remove any of them — changes apply immediately.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                if settings.dictionaryWords.isEmpty {
                    Text("Dictionary is empty.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(settings.dictionaryWords, id: \.self) { word in
                        HStack {
                            Text(word)
                            Spacer()
                            Button {
                                settings.removeDictionaryWord(word)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help("Remove")
                        }
                    }
                }
            }

            Section("Permissions") {
                LabeledContent("Microphone") {
                    Text(permissions.microphoneGranted ? "Granted" : "Missing")
                        .foregroundStyle(permissions.microphoneGranted ? .green : .orange)
                }
                LabeledContent("Accessibility") {
                    Text(permissions.accessibilityTrusted ? "Granted" : "Missing")
                        .foregroundStyle(permissions.accessibilityTrusted ? .green : .orange)
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
                HStack {
                    Button("Request Microphone") {
                        Task { _ = await permissions.requestMicrophone() }
                    }
                    Button("Open Accessibility Settings") {
                        permissions.requestAccessibility()
                    }
                    Button("Refresh") {
                        permissions.refresh()
                    }
                }
                if !permissions.accessibilityTrusted {
                    Button("Quit & Reopen (needed after enabling Accessibility)") {
                        permissions.quitAndRelaunch()
                    }
                }
            }
            .onAppear { permissions.startPolling() }
            .onDisappear { permissions.stopPolling() }

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
                Button("Open dictation log…") {
                    AppWindowFocus.present(title: "Dictation Log") {
                        openWindow(id: "log")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 520, minHeight: 680)
        .navigationTitle("WhisperLocal Settings")
    }

    private func addDictionaryTerm() {
        settings.addDictionaryWord(newDictionaryTerm)
        newDictionaryTerm = ""
    }
}

private struct APIKeyField: View {
    let title: String
    let prompt: String
    @Binding var draft: String
    let savedKey: String
    let onSave: () -> Void
    let onClear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            VisiblePlaceholderField(
                placeholder: prompt,
                text: $draft,
                font: .body.monospaced(),
                isSecure: true
            )
            Text(statusLine)
                .font(.caption)
                .foregroundStyle(savedKey.isEmpty ? Color.orange : Color.secondary)
            Text("Click the box and paste. The key stays in the Keychain; audio never leaves this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Save key", action: onSave)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Remove key", role: .destructive, action: onClear)
                    .disabled(savedKey.isEmpty && draft.isEmpty)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusLine: String {
        if savedKey.isEmpty {
            return "No key saved yet."
        }
        if savedKey.count >= 4 {
            return "Key saved in Keychain · ends with \(savedKey.suffix(4))"
        }
        return "Key saved in Keychain."
    }
}

private struct VisiblePlaceholderField: View {
    let placeholder: String
    @Binding var text: String
    var font: Font = .body
    var isSecure: Bool = false
    var onSubmit: (() -> Void)? = nil

    @FocusState private var isFocused: Bool

    private var showsPlaceholder: Bool {
        text.isEmpty && !isFocused
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if showsPlaceholder {
                Text(placeholder)
                    .font(font)
                    .foregroundStyle(Color.secondary.opacity(0.55))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 7)
                    .allowsHitTesting(false)
            }

            Group {
                if isSecure {
                    SecureField("", text: $text)
                } else {
                    TextField("", text: $text)
                        .onSubmit { onSubmit?() }
                }
            }
            .labelsHidden()
            .font(font)
            .textFieldStyle(.plain)
            .focused($isFocused)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .settingsFieldChrome()
    }
}

private struct VisiblePlaceholderEditor: View {
    let placeholder: String
    @Binding var text: String
    var minHeight: CGFloat = 168

    @FocusState private var isFocused: Bool

    private var showsPlaceholder: Bool {
        text.isEmpty && !isFocused
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if showsPlaceholder {
                Text(placeholder)
                    .font(.body)
                    .foregroundStyle(Color.secondary.opacity(0.55))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .focused($isFocused)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
        }
        .frame(maxWidth: .infinity, minHeight: minHeight, maxHeight: 280, alignment: .topLeading)
        .settingsFieldChrome()
    }
}

private extension View {
    func settingsFieldChrome() -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.22), lineWidth: 1)
            )
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
            .onChange(of: options.map(\.id), initial: true) { _, ids in
                if !ids.contains(modelID), let first = ids.first {
                    modelID = first
                }
            }
        }
        HStack {
            if isLoading {
                ProgressView().controlSize(.small)
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
