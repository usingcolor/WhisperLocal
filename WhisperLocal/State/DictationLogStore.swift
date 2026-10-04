import Foundation
import os

struct DictationLogEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let date: Date
    let raw: String
    let polished: String
    let stages: [String]
    let cleanupNote: String?
    let appName: String?
    let insertMethod: String?
    let outcome: Outcome
    let errorMessage: String?
    let audioSeconds: Double?
    /// The language the take ran in, and the microphone it came from.
    ///
    /// `var` with a default, and optional, on purpose: entries written before
    /// these existed have neither key. Optional fields keep those takes readable
    /// without sending an otherwise valid history through recovery.
    var language: String? = nil
    /// More than one name, joined, when the microphone was switched mid-take.
    var microphone: String? = nil
    /// Earlier takes polish was shown because they shared words with this one,
    /// rather than for being recent. Dev-only while that is tried; optional for
    /// the same reason as the two above. Empty when related takes were looked
    /// for and none qualified; nil when they were not looked for at all.
    var relatedTakeIDs: [UUID]? = nil
    /// The window the take was dictated into, as its title read then. Dev only,
    /// kept here and nowhere else — see `FocusedWindowTitle`.
    var windowTitle: String? = nil
    /// The topics polish was shown as what the speaker is working on, and what
    /// the update after the paste changed about them — filled in a moment after
    /// the entry is written, and never if the app quits first. Dev only; nil
    /// when not kept.
    var autoContext: [String]? = nil
    var autoContextChange: String? = nil
    /// The speech model and the polish model the take ran on, as ids. Nil for
    /// takes logged before they were recorded, and polish for no LLM step.
    var speechModel: String? = nil
    var polishModel: String? = nil

    enum Outcome: String, Codable {
        case success
        case insertFailed
        case heardNothing
        case error
    }

    var outcomeLabel: String {
        switch outcome {
        case .success: return "Inserted"
        case .insertFailed: return "Insert failed"
        case .heardNothing: return "Heard nothing"
        case .error: return "Error"
        }
    }
}

@MainActor
final class DictationLogStore: ObservableObject {
    static let shared = DictationLogStore()

    @Published private(set) var entries: [DictationLogEntry] = []
    @Published private(set) var recoveryMessage: String?
    private(set) var preservedHistoryURL: URL?

    /// How many takes the log keeps, newest first.
    ///
    /// Dev keeps 5,000 as a trial for choosing polish examples by relevance
    /// rather than recency. Release stays at 100 until the trial says whether
    /// retaining more history improves cleanup enough to justify the longer log.
    static let maxEntries = AppIdentity.isDevBuild ? 5_000 : 100

    private let logger = Logger(subsystem: "com.usingcolor.WhisperLocal", category: "dictation")
    private let fileURL: URL
    private let defaults: UserDefaults
    private let canPersist: Bool
    /// Saves run here, in order. At 5,000 takes the JSON is about 2.3 MB and
    /// encoding it takes ~40 ms, which on the main thread would land on every
    /// take, while the toolbar is animating its result.
    private let writer = DispatchQueue(label: "com.usingcolor.WhisperLocal.dictation-log", qos: .utility)

    init(fileURL suppliedURL: URL? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folder = suppliedURL?.deletingLastPathComponent()
            ?? dir.appendingPathComponent(AppIdentity.supportFolderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = suppliedURL ?? folder.appendingPathComponent("dictation-log.json")
        let loaded = Self.load(from: fileURL)
        entries = loaded.entries
        recoveryMessage = loaded.message
        preservedHistoryURL = loaded.backup
        canPersist = loaded.canPersist
        Self.restrictPermissions(at: fileURL)
        if loaded.backup != nil { persist() }
    }

    func recentPolishExamples(limit: Int) -> [RecentDictationExample] {
        recentPolishEntries(limit: limit).map(Self.example)
    }

    /// The newest takes an example can be made from, newest first.
    func recentPolishEntries(limit: Int) -> [DictationLogEntry] {
        let cap = CleanupPrompt.clampRecentPolishLogCount(limit)
        var picked: [DictationLogEntry] = []
        for entry in entries {
            guard entry.outcome == .success else { continue }
            guard !entry.raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !entry.polished.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            picked.append(entry)
            if picked.count == cap { break }
        }
        return picked
    }

    func entries(withIDs ids: [UUID]) -> [DictationLogEntry] {
        ids.compactMap { id in entries.first { $0.id == id } }
    }

    static func example(_ entry: DictationLogEntry) -> RecentDictationExample {
        RecentDictationExample(
            raw: entry.raw.trimmingCharacters(in: .whitespacesAndNewlines),
            polished: entry.polished.trimmingCharacters(in: .whitespacesAndNewlines),
            appName: entry.appName
        )
    }

    func append(_ entry: DictationLogEntry) {
        guard defaults.object(forKey: "enableDictationLog") as? Bool ?? true else { return }
        entries.insert(entry, at: 0)
        if entries.count > Self.maxEntries {
            entries = Array(entries.prefix(Self.maxEntries))
        }
        persist()
        let stages = entry.stages.joined(separator: " → ")
        let app = entry.appName ?? "—"
        logger.info("\(entry.outcome.rawValue, privacy: .public) app=\(app, privacy: .public) stages=\(stages, privacy: .public) raw=\(entry.raw, privacy: .private) polished=\(entry.polished, privacy: .private)")
    }

    /// Automatic context's answer arrives after its take is logged.
    func recordAutoContextChange(_ change: String, for id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].autoContextChange = change
        persist()
    }

    func clear() {
        entries = []
        persist()
    }

    private func persist() {
        guard canPersist else { return }
        let snapshot = entries
        let url = fileURL
        let logger = logger
        writer.async {
            do {
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: url, options: [.atomic])
                Self.restrictPermissions(at: url)
            } catch {
                logger.error("Failed to save dictation log: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Drain snapshots before quitting, and let recovery tests inspect the saved file.
    func flushPendingWrites() { writer.sync {} }

    nonisolated private static func restrictPermissions(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private static func load(from url: URL) -> (entries: [DictationLogEntry], message: String?, backup: URL?, canPersist: Bool) {
        guard FileManager.default.fileExists(atPath: url.path) else { return ([], nil, nil, true) }
        let data = try? Data(contentsOf: url)
        if let data, let entries = try? JSONDecoder().decode([DictationLogEntry].self, from: data) {
            return (entries, nil, nil, true)
        }
        let backup = url.deletingLastPathComponent()
            .appendingPathComponent("dictation-log-preserved-\(UUID().uuidString).json")
        do {
            try FileManager.default.moveItem(at: url, to: backup)
            restrictPermissions(at: backup)
        } catch {
            return ([], "History could not be read. The original file is untouched; new takes will stay in memory until it can be recovered.", nil, false)
        }
        var recovered: [DictationLogEntry] = []
        if let data, let items = (try? JSONSerialization.jsonObject(with: data)) as? [Any] {
            recovered = items.compactMap { item in
                guard JSONSerialization.isValidJSONObject(item),
                      let encoded = try? JSONSerialization.data(withJSONObject: item) else { return nil }
                return try? JSONDecoder().decode(DictationLogEntry.self, from: encoded)
            }
        }
        return (recovered, "History needed recovery. Recovered \(recovered.count) takes; the original file has been preserved.", backup, true)
    }
}
