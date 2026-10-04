import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings › Data Sharing (Dev only while it is tried).
struct DataSharingPane: View {
    @ObservedObject private var store = DataSharingStore.shared
    @State private var joining = false
    @State private var confirmingDelete = false

    var body: some View {
        Form {
            Section("Help improve WhisperLocal") {
                if store.isSharing {
                    LabeledContent("Status") {
                        Text(store.allowsTraining ? "Sharing, training allowed" : "Sharing")
                    }
                    Toggle("Share each take as it happens", isOn: $store.shareAutomatically)
                    caption("Each take waits \(Int(DataSharing.holdInterval / 60)) minutes below before it is sent, so you can take out anything said by mistake. You can also send single takes from the dictation log.")
                    Toggle("Allow training models on shared takes", isOn: Binding(
                        get: { store.allowsTraining },
                        set: { allowed in Task { await store.setTraining(allowed) } }
                    ))
                    caption("A model already trained on a take cannot forget it; a take you delete is never used for training again.")
                } else {
                    caption("Share takes with WhisperLocal's developer so polishing mistakes can be found and fixed. Off until you join, text only, and names, numbers and keys are taken out on this Mac first.")
                    Button("Join…") { joining = true }
                }
                status
            }

            Section("Before a take leaves this Mac") {
                Toggle("Hide people's names", isOn: $store.hideNames)
                caption("Names become [NAME_1], [NAME_2] and so on, the same in what you said and what was pasted. Apple's name detector does not read every language: Korean names, for one, are not caught.")
                LabeledContent("Never share from") {
                    TextField("", text: $store.excludedAppsText, axis: .vertical)
                        .lineLimit(1...3)
                }
                caption("App names, separated by commas. Password managers are there from the start.")
            }

            if store.isSharing {
                Section("Waiting to be sent") {
                    if store.queue.isEmpty {
                        caption(store.shareAutomatically ? "Nothing waiting." : "Nothing waiting. Takes are only sent from the dictation log while sharing each take is off.")
                    } else {
                        ForEach(store.queue) { item in
                            QueuedTakeRow(item: item) { store.remove(item.id) }
                        }
                        Button("Send All Now") { Task { await store.sendQueuedNow() } }
                            .disabled(store.isBusy)
                    }
                }
            }

            if store.hasCredentials {
                Section("What you have sent") {
                    LabeledContent("Sent") {
                        Text(store.sent.count == 1 ? "1 take" : "\(store.sent.count) takes")
                    }
                    HStack(spacing: 10) {
                        Button("Download…") { Task { await download() } }
                        Button("Delete Everything…", role: .destructive) { confirmingDelete = true }
                        Spacer()
                        if store.isSharing {
                            Button("Stop Sharing") { Task { await store.stopSharing() } }
                        }
                    }
                    .disabled(store.isBusy)
                    caption("Stopping takes effect at once and clears what is waiting. What was already sent stays on the server until you delete it.")
                }
            }

            Section("Server (Dev)") {
                TextField("Address", text: $store.serverAddress)
                caption("This Dev build sends to a test server on this Mac, scripts/data-sharing-server.py. Anywhere else, only https is accepted.")
            }
        }
        .formStyle(.grouped)
        .padding(.trailing, 4)
        .sheet(isPresented: $joining) {
            DataSharingConsentSheet { joining = false }
        }
        .confirmationDialog(
            "Delete everything you have sent?",
            isPresented: $confirmingDelete
        ) {
            Button("Delete Everything", role: .destructive) { Task { await store.deleteEverything() } }
        } message: {
            Text("The server removes every take and consent record for this Mac. Sharing stops, and joining again starts from nothing.")
        }
    }

    @ViewBuilder
    private var status: some View {
        if let error = store.lastError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        } else if let result = store.lastResult {
            Text(result)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func download() async {
        guard let data = await store.download() else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "WhisperLocal shared takes.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url, options: .atomic)
    }
}

private struct QueuedTakeRow: View {
    let item: DataSharingStore.QueuedTake
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.take.polished)
                    .lineLimit(2)
                Text("\(item.take.appKind) · sends at \(item.sendsAt().formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Don't send this take")
        }
    }
}

/// What joining means, said once before anything is sent. A draft for Dev:
/// the wording is reviewed by a lawyer before Release, and bumping
/// `DataSharing.consentVersion` asks everyone again.
struct DataSharingConsentSheet: View {
    @ObservedObject private var store = DataSharingStore.shared
    @State private var allowTraining = false
    @State private var adult = false
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            DataSharingConsentText(server: store.serverAddress)
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Also allow training models on my shared takes", isOn: $allowTraining)
                Text("Optional. A model already trained on a take cannot forget it; a take you delete is never used for training again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 20)
                Toggle("I am 18 or older", isOn: $adult)
            }
            .toggleStyle(.checkbox)
            if let error = store.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Not Now", role: .cancel, action: done)
                    .keyboardShortcut(.cancelAction)
                Button("Join") {
                    Task {
                        await store.join(allowTraining: allowTraining)
                        if store.isSharing { done() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!adult || store.isBusy)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear { store.clearMessages() }
    }
}

private struct DataSharingConsentText: View {
    let server: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Help improve WhisperLocal")
                .font(.title2.weight(.semibold))
            Text("Share takes with WhisperLocal's developer so polishing mistakes can be found and fixed.")
                .fixedSize(horizontal: false, vertical: true)
            point("doc.text", "What is sent", "The words you said, the text that was pasted and the auto-context topics polish was shown, with the day, the kind of app (chat, code editor and so on), the language, how long you spoke, the app version, and the models and steps used.")
            point("eye.slash", "Taken out on this Mac first", "Email addresses, phone numbers, street addresses, links, card and ID numbers, and keys — and people's names, unless you turn that off. Names Apple's detector cannot read, such as Korean ones, stay in.")
            point("lock", "Never sent", "Your audio, the app's name, window titles, your microphone, API keys and your custom instructions. Nothing said into a password manager.")
            point("hand.raised", "Yours to stop", "Takes shared as they happen wait \(Int(DataSharing.holdInterval / 60)) minutes first, so you can take any out. Stop at any time, download what you sent, or delete all of it.")
            point("clock", "Kept for", "Up to \(DataSharing.retentionMonths) months, then deleted.")
            Text("Dev build: takes go to \(server).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func point(_ symbol: String, _ title: String, _ text: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(.tint)
                .frame(width: 20)
        }
    }
}

/// "Send this take", from the dictation log: exactly what would leave the
/// Mac, before it does. Asks to join first for someone who has not.
struct ShareTakeSheet: View {
    @ObservedObject private var store = DataSharingStore.shared
    let entry: DictationLogEntry
    let done: () -> Void

    var body: some View {
        if !store.isSharing {
            DataSharingConsentSheet(done: {
                if !store.isSharing { done() }
            })
        } else {
            VStack(alignment: .leading, spacing: 14) {
                Text("Send this take")
                    .font(.title2.weight(.semibold))
                if store.wasSent(entry.id) {
                    Text("Already sent.")
                        .foregroundStyle(.secondary)
                    footer(sendable: nil)
                } else if let take = store.preview(entry) {
                    Text("Exactly this leaves the Mac:")
                        .foregroundStyle(.secondary)
                    SharedTakePreview(take: take)
                    footer(sendable: take)
                } else {
                    Text(DataSharing.isExcluded(appName: entry.appName, excluded: store.excludedApps)
                         ? "This take was dictated into an app you never share from."
                         : "Only takes that were pasted, with something said, can be sent.")
                        .foregroundStyle(.secondary)
                    footer(sendable: nil)
                }
            }
            .padding(24)
            .frame(width: 560)
        }
    }

    private func footer(sendable take: SharedTake?) -> some View {
        HStack {
            if let error = store.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
            Spacer()
            Button(take == nil ? "Close" : "Cancel", role: .cancel, action: done)
                .keyboardShortcut(.cancelAction)
            if let take {
                Button("Send") {
                    Task {
                        await store.send(take, from: entry)
                        if store.wasSent(take.id) { done() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(store.isBusy)
            }
        }
    }
}

struct SharedTakePreview: View {
    let take: SharedTake

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            field("You said", take.raw)
            field("Pasted", take.polished)
            if let topics = take.contextTopics, !topics.isEmpty {
                field("Auto context", topics.joined(separator: " · "))
            }
            Text(details)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Every other field, so the preview is the whole of what leaves.
    private var details: String {
        var parts = [take.day, take.appKind]
        if let language = take.language { parts.append(language) }
        if let seconds = take.audioSeconds { parts.append(String(format: "%.1f s", seconds)) }
        parts.append("WhisperLocal \(take.appVersion)")
        if let model = take.speechModel { parts.append(model) }
        if let model = take.polishModel { parts.append(model) }
        if !take.stages.isEmpty { parts.append("steps: " + take.stages.joined(separator: " → ")) }
        if let note = take.cleanupNote { parts.append(note) }
        let removed = take.redacted.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }
        parts.append(removed.isEmpty ? "nothing taken out" : "taken out: " + removed.joined(separator: ", "))
        return parts.joined(separator: " · ")
    }

    private func field(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
        }
    }
}

private func caption(_ text: String) -> some View {
    Text(text)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
}
