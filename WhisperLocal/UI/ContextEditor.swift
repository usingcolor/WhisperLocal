import SwiftUI
import Combine

/// One readable surface for Shift dictation, user notes, and automatic topics.
/// Drafts belong to the window; incoming context never replaces unsaved text.
struct ContextEditor: View {
    @ObservedObject var controller: DictationController
    @ObservedObject private var settings = SettingsStore.shared
    @State private var draft = ContextEditorDraft(session: nil, topics: [])
    @State private var message: String?
    @State private var saveFailed = false
    @FocusState private var focusedEntry: UUID?

    private let tick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        AppGroupedForm {
            Section {
                if AutoContext.isEnabled {
                    Toggle("Learn from dictation", isOn: $settings.useAutoContext)
                        .disabled(!settings.enableTextCleanup)
                }
                Text(learningDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                if draft.entries.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No context yet").font(.headline)
                        Text("Add names or terminology to remember, or hold Shift during a dictation to capture a topic.")
                            .foregroundStyle(.secondary)
                        Button("Add note", action: addNote)
                    }
                    .padding(.vertical, 8)
                }
                ForEach(draft.entries) { entry in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(sourceLabel(entry.source))
                                .font(.headline)
                                .fixedSize()
                            Spacer(minLength: 8)
                            Text(entry.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                                .fixedSize(horizontal: false, vertical: true)
                            Button {
                                if focusedEntry == entry.id { focusedEntry = nil }
                                draft.entries.removeAll { $0.id == entry.id }
                                clearMessage()
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help("Remove this topic")
                            .accessibilityLabel("Remove context: \(entry.text.isEmpty ? "new note" : entry.text)")
                        }
                        TextField("", text: topicText(for: entry),
                                  prompt: Text("e.g. reviewing the checkout redesign with Sam"), axis: .vertical)
                            .lineLimit(1...6)
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                            .multilineTextAlignment(.leading)
                            .font(.system(size: 16))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .focused($focusedEntry, equals: entry.id)
                            .accessibilityLabel("Edit \(sourceLabel(entry.source)) context")
                        if entry.text.count >= SessionContext.maxCharacters * 3 / 4 {
                            Text("\(entry.text.count)/\(SessionContext.maxCharacters)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("Topics")
            } footer: {
                Text("Typed notes and corrected topics stay until removed or the app quits. Automatic learning cannot overwrite your edits.")
            }
        }
        .navigationTitle("Context")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: addNote) {
                    Label("Add note", systemImage: "plus")
                }
                .disabled(!canAddNote)
                .help("Add a context note")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { actions }
        .background(AppWindowChrome())
        .frame(minWidth: 540, minHeight: 360)
        .onAppear { reload() }
        .onReceive(tick) { _ in refreshIfClean() }
        .onChange(of: controller.autoContext) { _, _ in refreshIfClean() }
        .onChange(of: controller.sessionContext) { _, _ in refreshIfClean() }
    }

    private var actions: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                Text(message ?? (draft.isDirty ? "Unsaved changes" : (settings.enableTextCleanup ? "Used with your next dictation" : "Polish is off")))
                    .font(.caption)
                    .foregroundStyle(saveFailed && message != nil ? Color.orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)
                Spacer(minLength: 8)
                Button("Discard changes") { reload() }
                    .keyboardShortcut(.escape, modifiers: [])
                    .disabled(!draft.isDirty)
                Button("Save changes") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!draft.isDirty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(.bar)
    }

    private var learningDescription: String {
        guard settings.enableTextCleanup else {
            return "Polish is off. Enable it in Settings to use context with dictation."
        }
        guard settings.useAutoContext else {
            return "Automatic learning is off. Your notes still help with names and terminology."
        }
        if settings.hasUsableCloudPolish {
            return "Automatic topics are learned after each paste using your selected cloud cleanup provider. Context is sent with cleanup requests."
        }
        if settings.shouldRunOnDevicePolish && settings.localPolishEngine == .appleIntelligence {
            return "Apple Intelligence learns names on this Mac after each paste. Add a note to supply names or terminology yourself."
        }
        return "Automatic learning needs Apple Intelligence or cloud cleanup. You can still add and edit notes."
    }

    private var canAddNote: Bool {
        draft.entries.filter { !$0.source.isAutomatic && $0.source != .shift }.count < AutoContext.maxUserTopics
    }

    private func addNote() {
        guard canAddNote else { return }
        focusedEntry = draft.addNote()
        clearMessage()
    }

    private func clearMessage() {
        message = nil
        saveFailed = false
    }

    /// A text field can finish an edit after its row was removed or reordered.
    /// Resolve by identity each time instead of retaining an array-index binding.
    private func topicText(for entry: ContextEditorDraft.Entry) -> Binding<String> {
        Binding {
            draft.entries.first(where: { $0.id == entry.id })?.text ?? entry.text
        } set: { value in
            guard let index = draft.entries.firstIndex(where: { $0.id == entry.id }) else { return }
            draft.entries[index].text = String(value.prefix(SessionContext.maxCharacters))
            clearMessage()
        }
    }

    private func sourceLabel(_ source: AutoContext.Topic.Source) -> String {
        switch source {
        case .automatic: return "Automatic"
        case .shift: return settings.enableSessionContext ? "Shift dictation" : "Shift dictation (disabled)"
        case .typed: return "Your note"
        case .edited: return "Corrected topic"
        }
    }

    private func refreshIfClean() {
        guard !draft.isDirty else { return }
        draft = controller.contextDraft()
    }

    private func reload() {
        draft = controller.contextDraft()
        message = nil
        saveFailed = false
    }

    private func save() {
        guard controller.saveContextDraft(draft) else {
            saveFailed = true
            message = "Keep up to \(AutoContext.maxUserTopics) user notes. Remove one before saving."
            return
        }
        reload()
        message = "Saved"
    }
}
