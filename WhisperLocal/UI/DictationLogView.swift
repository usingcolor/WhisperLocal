import AppKit
import SwiftUI

struct DictationLogView: View {
    @ObservedObject var log = DictationLogStore.shared
    @ObservedObject var settings = SettingsStore.shared
    @State private var selectedID: UUID?
    @State private var query = ""
    @State private var confirmingClear = false

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            if let entry = selectedEntry {
                DictationLogDetailView(entry: entry)
            } else {
                ContentUnavailableView(
                    "No dictation selected",
                    systemImage: "text.alignleft",
                    description: Text("Pick a take from the list.")
                )
            }
        }
        .onChange(of: log.entries.first?.id) { _, newID in
            // Don't yank the selection out of a filtered list: the newest entry
            // usually isn't in it, and the detail pane would just go blank.
            guard query.isEmpty else { return }
            selectedID = newID
        }
        .onChange(of: query) { _, _ in
            if let selectedID, !filtered.contains(where: { $0.id == selectedID }) {
                self.selectedID = filtered.first?.id
            } else if selectedID == nil {
                selectedID = filtered.first?.id
            }
        }
        .onAppear {
            if selectedID == nil { selectedID = log.entries.first?.id }
        }
        .frame(minWidth: 760, minHeight: 460)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selectedID) {
            ForEach(sections) { section in
                Section(section.title) {
                    ForEach(section.entries) { entry in
                        DictationLogRow(entry: entry).tag(entry.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $query, placement: .sidebar, prompt: "Search dictations")
        .overlay { emptyState }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 400)
        .navigationTitle("Dictation Log")
        .toolbar { toolbar }
        .confirmationDialog(
            "Clear the dictation log?",
            isPresented: $confirmingClear,
            titleVisibility: .visible
        ) {
            Button("Clear \(log.entries.count) Entries", role: .destructive) {
                log.clear()
                selectedID = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone. Export first if you want to keep a copy.")
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            Menu {
                Section("All entries") {
                    ForEach(DictationLogExport.Format.allCases) { format in
                        Button(format.menuTitle) { export(entries: log.entries, format: format) }
                    }
                }
                .disabled(log.entries.isEmpty)
                if let entry = selectedEntry {
                    Section("Selected") {
                        ForEach(DictationLogExport.Format.allCases) { format in
                            Button(format.menuTitle) {
                                export(
                                    entries: [entry],
                                    format: format,
                                    suggestedName: format.suggestedFilename(for: entry.date)
                                )
                            }
                        }
                    }
                }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .disabled(log.entries.isEmpty)
            .help("Export the log")
        }
        ToolbarItem(placement: .automatic) {
            Button { confirmingClear = true } label: {
                Label("Clear", systemImage: "trash")
            }
            .disabled(log.entries.isEmpty)
            .help("Delete every entry")
        }
    }

    /// Entry count and total audio, so the window says something about itself
    /// instead of being a bare list.
    @ViewBuilder
    private var footer: some View {
        if !log.entries.isEmpty || !settings.enableDictationLog {
            VStack(alignment: .leading, spacing: 4) {
                Divider()
                if !settings.enableDictationLog {
                    Label(
                        "Logging is off. New takes are not saved.",
                        systemImage: "pause.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                }
                if !log.entries.isEmpty {
                    Text(summaryLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .padding(.horizontal, 12)
                        .padding(.top, settings.enableDictationLog ? 6 : 0)
                }
            }
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if log.entries.isEmpty {
            ContentUnavailableView {
                Label("No dictations yet", systemImage: "waveform")
            } description: {
                Text("Takes show up here after you dictate. They never leave this Mac.")
            }
        } else if filtered.isEmpty {
            ContentUnavailableView.search(text: query)
        }
    }

    // MARK: - Data

    private var selectedEntry: DictationLogEntry? {
        guard let selectedID else { return nil }
        return log.entries.first { $0.id == selectedID }
    }

    private var filtered: [DictationLogEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return log.entries }
        return log.entries.filter { entry in
            entry.polished.localizedCaseInsensitiveContains(needle)
                || entry.raw.localizedCaseInsensitiveContains(needle)
                || entry.appName?.localizedCaseInsensitiveContains(needle) == true
        }
    }

    /// A hundred undifferentiated rows is a database dump. Day headings turn it
    /// back into a history you can scan.
    private var sections: [DaySection] {
        let calendar = Calendar.current
        var order: [Date] = []
        var buckets: [Date: [DictationLogEntry]] = [:]
        for entry in filtered {
            let day = calendar.startOfDay(for: entry.date)
            if buckets[day] == nil { order.append(day) }
            buckets[day, default: []].append(entry)
        }
        return order.map { DaySection(id: $0, title: Self.dayTitle($0), entries: buckets[$0] ?? []) }
    }

    private var summaryLine: String {
        let count = filtered.count
        let noun = count == 1 ? "dictation" : "dictations"
        let seconds = filtered.compactMap(\.audioSeconds).reduce(0, +)
        guard seconds >= 1 else { return "\(count) \(noun)" }
        return "\(count) \(noun) · \(Self.durationLabel(seconds)) of audio"
    }

    private static func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        if let days = calendar.dateComponents([.day], from: day, to: Date()).day, days < 7 {
            return day.formatted(.dateTime.weekday(.wide))
        }
        return day.formatted(.dateTime.month(.abbreviated).day().year())
    }

    private static func durationLabel(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes)m \(total % 60)s" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    private struct DaySection: Identifiable {
        let id: Date
        let title: String
        let entries: [DictationLogEntry]
    }

    // MARK: - Export

    private func export(entries: [DictationLogEntry], format: DictationLogExport.Format, suggestedName: String? = nil) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = suggestedName ?? format.suggestedFilename
        panel.message = entries.count == 1
            ? "Export 1 dictation as \(format.filenameExtension.uppercased())"
            : "Export \(entries.count) dictations as \(format.filenameExtension.uppercased())"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try DictationLogExport.data(entries: entries, format: format).write(to: url, options: [.atomic])
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not export the dictation log"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }
}

// MARK: - Row

private struct DictationLogRow: View {
    let entry: DictationLogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: entry.outcomeSymbol)
                .font(.system(size: 11))
                .foregroundStyle(entry.outcomeTint)
                .frame(width: 13)
                .padding(.top, 2)
                .help(entry.outcomeLabel)
            VStack(alignment: .leading, spacing: 2) {
                Text(preview)
                    .font(.system(size: 12))
                    .lineLimit(2)
                    .foregroundStyle(hasText ? .primary : .secondary)
                HStack(spacing: 4) {
                    Text(entry.date, format: .dateTime.hour().minute())
                        .monospacedDigit()
                    if let app = entry.appName, !app.isEmpty {
                        Text("·")
                        Text(app).lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }

    private var hasText: Bool {
        !(entry.polished.isEmpty && entry.raw.isEmpty)
    }

    private var preview: String {
        let text = entry.polished.isEmpty ? entry.raw : entry.polished
        if !text.isEmpty { return text }
        return entry.errorMessage ?? entry.outcomeLabel
    }
}

// MARK: - Detail

private struct DictationLogDetailView: View {
    let entry: DictationLogEntry

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let error = entry.errorMessage, !error.isEmpty {
                    notice(error, symbol: "exclamationmark.triangle.fill")
                }
                if let note = entry.cleanupNote, !note.isEmpty {
                    notice(note, symbol: "info.circle.fill")
                }
                // The transcript is what you came to read, so it leads and the
                // metadata sits underneath instead of pushing it down the page.
                transcript(primaryTitle, primaryText, prominent: true)
                if let raw = secondaryRaw {
                    transcript("Raw transcript", raw, prominent: false)
                }
                metadata
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label(entry.outcomeLabel, systemImage: entry.outcomeSymbol)
                .font(.headline)
                .foregroundStyle(entry.outcomeTint)
            Spacer(minLength: 12)
            Text(entry.date, format: .dateTime.month(.abbreviated).day().hour().minute().second())
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var primaryTitle: String {
        entry.polished.isEmpty ? "Transcript" : "Inserted text"
    }

    private var primaryText: String {
        entry.polished.isEmpty ? entry.raw : entry.polished
    }

    /// Showing raw and polished side by side when they are identical just makes
    /// the reader compare two strings to discover nothing happened.
    private var secondaryRaw: String? {
        guard !entry.polished.isEmpty, !entry.raw.isEmpty, entry.raw != entry.polished else { return nil }
        return entry.raw
    }

    private func notice(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.callout)
            .foregroundStyle(.orange)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func transcript(_ title: String, _ text: String, prominent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                if !text.isEmpty { CopyButton(text: text) }
            }
            Text(text.isEmpty ? "—" : text)
                .textSelection(.enabled)
                .font(prominent ? .system(size: 15) : .system(size: 12))
                .foregroundStyle(prominent ? .primary : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor).opacity(prominent ? 1 : 0.5))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                )
        }
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150), spacing: 16, alignment: .leading)],
                alignment: .leading,
                spacing: 10
            ) {
                ForEach(facts) { fact in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(fact.id)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .textCase(.uppercase)
                        Text(fact.value)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var facts: [Fact] {
        var facts: [Fact] = []
        if let app = entry.appName, !app.isEmpty { facts.append(Fact(id: "App", value: app)) }
        if let method = entry.insertMethod, !method.isEmpty {
            facts.append(Fact(id: "Insert", value: method))
        }
        if let seconds = entry.audioSeconds {
            facts.append(Fact(id: "Audio", value: String(format: "%.1f s", seconds)))
        }
        if !entry.stages.isEmpty {
            facts.append(Fact(id: "Pipeline", value: entry.stages.joined(separator: " → ")))
        }
        return facts
    }

    private struct Fact: Identifiable {
        let id: String
        let value: String
    }
}

/// Copy with a confirmation in place. A button that gives no sign it fired makes
/// you click it twice and check the clipboard.
private struct CopyButton: View {
    let text: String
    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            resetTask?.cancel()
            withAnimation { copied = true }
            resetTask = Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled else { return }
                withAnimation { copied = false }
            }
        } label: {
            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                .font(.caption)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(copied ? Color.green : Color.accentColor)
    }
}

private extension DictationLogEntry {
    var outcomeSymbol: String {
        switch outcome {
        case .success: return "checkmark.circle.fill"
        case .insertFailed: return "exclamationmark.triangle.fill"
        case .heardNothing: return "waveform.slash"
        case .error: return "xmark.octagon.fill"
        }
    }

    var outcomeTint: Color {
        switch outcome {
        case .success: return .green
        case .insertFailed: return .orange
        case .heardNothing: return .secondary
        case .error: return .red
        }
    }
}
