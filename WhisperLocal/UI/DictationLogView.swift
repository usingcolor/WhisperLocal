import AppKit
import SwiftUI

struct DictationLogView: View {
    @ObservedObject var log = DictationLogStore.shared
    @State private var selectedID: UUID?

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedID) {
                if log.entries.isEmpty {
                    Text("No dictations yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(log.entries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(entry.date, format: .dateTime.hour().minute().second())
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text(entry.outcomeLabel)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(color(for: entry.outcome))
                            Spacer()
                            if let app = entry.appName, !app.isEmpty {
                                Text(app)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Text(preview(for: entry))
                            .lineLimit(2)
                    }
                    .tag(entry.id)
                }
            }
            .navigationTitle("Dictation Log")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Menu("Export") {
                        Section("All entries") {
                            ForEach(DictationLogExport.Format.allCases) { format in
                                Button(format.menuTitle) {
                                    export(entries: log.entries, format: format)
                                }
                            }
                        }
                        .disabled(log.entries.isEmpty)
                        if let selectedID, let entry = log.entries.first(where: { $0.id == selectedID }) {
                            Section("Selected") {
                                ForEach(DictationLogExport.Format.allCases) { format in
                                    Button(format.menuTitle) {
                                        export(entries: [entry], format: format, suggestedName: format.suggestedFilename(for: entry.date))
                                    }
                                }
                            }
                        }
                    }
                    .disabled(log.entries.isEmpty)
                }
                ToolbarItem(placement: .automatic) {
                    Button("Clear") { log.clear() }
                        .disabled(log.entries.isEmpty)
                }
            }
        } detail: {
            if let selectedID, let entry = log.entries.first(where: { $0.id == selectedID }) {
                DictationLogDetailView(entry: entry)
            } else {
                Text("Select a dictation")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: log.entries.first?.id) { _, newID in
            selectedID = newID
        }
        .onAppear {
            if selectedID == nil {
                selectedID = log.entries.first?.id
            }
        }
        .frame(minWidth: 720, minHeight: 420)
    }

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

    private func preview(for entry: DictationLogEntry) -> String {
        let text = entry.polished.isEmpty ? entry.raw : entry.polished
        return text.isEmpty ? (entry.errorMessage ?? "—") : text
    }

    private func color(for outcome: DictationLogEntry.Outcome) -> Color {
        switch outcome {
        case .success: return .green
        case .insertFailed, .error: return .orange
        case .heardNothing: return .secondary
        }
    }
}

private struct DictationLogDetailView: View {
    let entry: DictationLogEntry

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LabeledContent("Time") {
                    Text(entry.date, format: .dateTime.month().day().hour().minute().second())
                }
                LabeledContent("Outcome") {
                    Text(entry.outcomeLabel)
                }
                if let app = entry.appName {
                    LabeledContent("App") { Text(app) }
                }
                if let method = entry.insertMethod {
                    LabeledContent("Insert") { Text(method) }
                }
                if let seconds = entry.audioSeconds {
                    LabeledContent("Audio") {
                        Text("\(seconds, format: .number.precision(.fractionLength(1))) s")
                    }
                }
                if !entry.stages.isEmpty {
                    LabeledContent("Stages") {
                        Text(entry.stages.joined(separator: " → "))
                            .foregroundStyle(.secondary)
                    }
                }
                if let note = entry.cleanupNote {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let error = entry.errorMessage {
                    Text(error)
                        .foregroundStyle(.orange)
                }

                group("Raw transcript", entry.raw)
                group("Polished", entry.polished)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Detail")
    }

    @ViewBuilder
    private func group(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                if !text.isEmpty {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                    .buttonStyle(.borderless)
                }
            }
            Text(text.isEmpty ? "—" : text)
                .textSelection(.enabled)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}