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

    private let maxEntries = 100
    private let logger = Logger(subsystem: "com.usingcolor.WhisperLocal", category: "dictation")
    private let fileURL: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folder = dir.appendingPathComponent("WhisperLocal", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent("dictation-log.json")
        entries = Self.load(from: fileURL)
        Self.restrictPermissions(at: fileURL)
    }

    func append(_ entry: DictationLogEntry) {
        guard UserDefaults.standard.object(forKey: "enableDictationLog") as? Bool ?? true else { return }
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
        persist()
        let stages = entry.stages.joined(separator: " → ")
        let app = entry.appName ?? "—"
        logger.info("\(entry.outcome.rawValue, privacy: .public) app=\(app, privacy: .public) stages=\(stages, privacy: .public) raw=\(entry.raw, privacy: .private) polished=\(entry.polished, privacy: .private)")
    }

    func clear() {
        entries = []
        persist()
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: fileURL, options: [.atomic])
            Self.restrictPermissions(at: fileURL)
        } catch {
            logger.error("Failed to save dictation log: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func restrictPermissions(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private static func load(from url: URL) -> [DictationLogEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([DictationLogEntry].self, from: data)) ?? []
    }
}
