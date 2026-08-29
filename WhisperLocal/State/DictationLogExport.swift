import Foundation
import UniformTypeIdentifiers

enum DictationLogExport {
    enum Format: String, CaseIterable, Identifiable {
        case json
        case csv
        case plainText

        var id: String { rawValue }

        var menuTitle: String {
            switch self {
            case .json: return "JSON…"
            case .csv: return "CSV…"
            case .plainText: return "Plain Text…"
            }
        }

        var contentType: UTType {
            switch self {
            case .json: return .json
            case .csv: return .commaSeparatedText
            case .plainText: return .plainText
            }
        }

        var filenameExtension: String {
            switch self {
            case .json: return "json"
            case .csv: return "csv"
            case .plainText: return "txt"
            }
        }

        var suggestedFilename: String {
            "whisperlocal-dictation-log.\(filenameExtension)"
        }

        func suggestedFilename(for date: Date) -> String {
            "whisperlocal-dictation-\(DictationLogExport.fileStamp.string(from: date)).\(filenameExtension)"
        }
    }

    static func data(entries: [DictationLogEntry], format: Format) throws -> Data {
        let text: String
        switch format {
        case .json:
            return try jsonData(entries: entries)
        case .csv:
            text = csv(entries: entries)
        case .plainText:
            text = plainText(entries: entries)
        }
        guard let data = text.data(using: .utf8) else {
            throw ExportError.encodingFailed
        }
        return data
    }

    static func jsonData(entries: [DictationLogEntry]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(entries)
    }

    static func csv(entries: [DictationLogEntry]) -> String {
        let header = [
            "date", "outcome", "app", "insert", "audio_seconds",
            "stages", "cleanup_note", "error", "raw", "polished"
        ]
        var lines = [header.map(escapeCSV).joined(separator: ",")]
        for entry in entries {
            let columns = [
                iso8601.string(from: entry.date),
                entry.outcome.rawValue,
                entry.appName ?? "",
                entry.insertMethod ?? "",
                entry.audioSeconds.map { String(format: "%.1f", $0) } ?? "",
                entry.stages.joined(separator: " | "),
                entry.cleanupNote ?? "",
                entry.errorMessage ?? "",
                entry.raw,
                entry.polished
            ]
            lines.append(columns.map(escapeCSV).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func plainText(entries: [DictationLogEntry]) -> String {
        if entries.isEmpty { return "" }
        return entries.map(plainText(for:)).joined(separator: "\n\n") + "\n"
    }

    static func plainText(for entry: DictationLogEntry) -> String {
        var lines: [String] = []
        lines.append("=== \(iso8601.string(from: entry.date)) · \(entry.outcomeLabel) ===")
        if let app = entry.appName, !app.isEmpty {
            lines.append("App: \(app)")
        }
        if let method = entry.insertMethod, !method.isEmpty {
            lines.append("Insert: \(method)")
        }
        if let seconds = entry.audioSeconds {
            lines.append("Audio: \(String(format: "%.1f", seconds)) s")
        }
        if !entry.stages.isEmpty {
            lines.append("Stages: \(entry.stages.joined(separator: " → "))")
        }
        if let note = entry.cleanupNote, !note.isEmpty {
            lines.append("Note: \(note)")
        }
        if let error = entry.errorMessage, !error.isEmpty {
            lines.append("Error: \(error)")
        }
        lines.append("Raw:")
        lines.append(entry.raw.isEmpty ? "—" : entry.raw)
        lines.append("Polished:")
        lines.append(entry.polished.isEmpty ? "—" : entry.polished)
        return lines.joined(separator: "\n")
    }

    static func escapeCSV(_ field: String) -> String {
        var value = field
        if let first = value.first, "=+-@".contains(first) {
            value = "'" + value
        }
        if value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }

    enum ExportError: LocalizedError {
        case encodingFailed

        var errorDescription: String? {
            "Could not encode the dictation log."
        }
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let fileStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}
