import Foundation

/// Spreadsheet format for global + per-app dictionary (and optional per-app exceptions).
/// Empty `app` means every app. Designed so a user can ask an LLM to fill the file, then import it.
enum DictionaryCSV {
    struct Snapshot: Equatable, Sendable {
        var globalWords: [String]
        var apps: [AppDictionaryEntry]
        var exceptionsByApp: [String: String]
    }

    enum ParseError: LocalizedError {
        case empty

        var errorDescription: String? {
            switch self {
            case .empty:
                return "The CSV has no dictionary rows."
            }
        }
    }

    static let header = "app,kind,word,exception"

    static let template = """
    # WhisperLocal dictionary CSV
    # Empty app = words for every app. One word per row, or separate several with ;
    # kind: code editor, chat app, browser, terminal, mail app, notes app, app
    # exception: optional polish rule for that app (once per app is enough)
    # Fill this with an LLM, then Settings → Dictionary → Import CSV
    \(header)
    ,,WhisperLocal,
    Cursor,code editor,,
    Code,code editor,,
    Xcode,code editor,,
    Slack,chat app,,
    Discord,chat app,,
    Messages,chat app,,
    Safari,browser,,
    Google Chrome,browser,,
    Mail,mail app,,
    Notes,notes app,,
    Terminal,terminal,,
    """

    static func export(
        globalWords: [String],
        apps: [AppDictionaryEntry],
        exceptions: String
    ) -> String {
        var lines = [
            "# WhisperLocal dictionary CSV",
            "# Empty app = every app. Ask an LLM to fill word / exception, then Import CSV.",
            header
        ]
        let globals = CleanupPrompt.mergedDictionary(globalWords)
        if globals.isEmpty {
            lines.append(csvRow(app: "", kind: "", word: "", exception: ""))
        } else {
            for word in globals {
                lines.append(csvRow(app: "", kind: "", word: word, exception: ""))
            }
        }

        var emitted = Set<String>()
        for app in apps {
            let name = app.appName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            emitted.insert(name.lowercased())
            let note = exceptionNote(for: name, in: exceptions)
            let terms = CleanupPrompt.mergedDictionary(app.terms)
            if terms.isEmpty {
                lines.append(csvRow(app: name, kind: app.kind, word: "", exception: note))
            } else {
                for (index, word) in terms.enumerated() {
                    lines.append(csvRow(
                        app: name,
                        kind: app.kind,
                        word: word,
                        exception: index == 0 ? note : ""
                    ))
                }
            }
        }
        for preset in AppDictionaryEntry.presets where !emitted.contains(preset.appName.lowercased()) {
            let note = exceptionNote(for: preset.appName, in: exceptions)
            lines.append(csvRow(app: preset.appName, kind: preset.kind, word: "", exception: note))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func parse(_ text: String) throws -> Snapshot {
        let rows = parseRows(text)
        var global: [String] = []
        var appsInOrder: [String] = []
        var termsByApp: [String: [String]] = [:]
        var kindByApp: [String: String] = [:]
        var exceptionsByApp: [String: String] = [:]
        var displayName: [String: String] = [:]

        for row in rows {
            let appField = field(row, 0)
            let kindField = field(row, 1)
            let wordField = field(row, 2)
            let exceptionField = field(row, 3)
            if isCommentRow(row) { continue }
            if isHeader(appField, kindField, wordField) { continue }

            let words = splitWords(wordField)
            if isEveryApp(appField) {
                global.append(contentsOf: words)
                continue
            }

            let name = appField
            guard !name.hasPrefix("#") else { continue }
            let key = name.lowercased()
            if displayName[key] == nil {
                displayName[key] = name
                appsInOrder.append(key)
            }
            if kindByApp[key] == nil || kindByApp[key]?.isEmpty == true {
                kindByApp[key] = kindForApp(name: name, kindField: kindField)
            }
            termsByApp[key, default: []].append(contentsOf: words)
            if !exceptionField.isEmpty {
                exceptionsByApp[displayName[key] ?? name] = exceptionField
            }
        }

        let apps = appsInOrder.compactMap { key -> AppDictionaryEntry? in
            guard let name = displayName[key] else { return nil }
            return AppDictionaryEntry(
                appName: name,
                kind: kindByApp[key] ?? kindForApp(name: name, kindField: ""),
                terms: termsByApp[key] ?? []
            )
        }
        let snapshot = Snapshot(
            globalWords: CleanupPrompt.mergedDictionary(global),
            apps: apps,
            exceptionsByApp: exceptionsByApp
        )
        if snapshot.globalWords.isEmpty, snapshot.apps.allSatisfy(\.terms.isEmpty), snapshot.exceptionsByApp.isEmpty {
            throw ParseError.empty
        }
        return snapshot
    }

    static func summary(_ snapshot: Snapshot) -> String {
        let appCount = snapshot.apps.count
        let wordCount = snapshot.globalWords.count + snapshot.apps.reduce(0) { $0 + $1.terms.count }
        let exceptionCount = snapshot.exceptionsByApp.count
        return "\(wordCount) word\(wordCount == 1 ? "" : "s"), \(appCount) app\(appCount == 1 ? "" : "s"), \(exceptionCount) exception\(exceptionCount == 1 ? "" : "s"). Merge keeps existing words. Replace uses the file as the dictionary."
    }

    static func mergeExceptions(existing: String, byApp: [String: String]) -> String {
        var lines = existing
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for (app, note) in byApp.sorted(by: { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }) {
            let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedNote.isEmpty else { continue }
            lines.removeAll { isExceptionBullet($0, forApp: app) }
            lines.append("- \(app): \(trimmedNote)")
        }
        return CleanupPrompt.strippedUserExceptions(lines.joined(separator: "\n"))
    }

    static func exceptionNote(for appName: String, in blob: String) -> String {
        let name = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "" }
        for line in blob.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isExceptionBullet(trimmed, forApp: name) else { continue }
            if let colon = trimmed.firstIndex(of: ":") {
                return String(trimmed[trimmed.index(after: colon)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return ""
    }

    static func isPresetAppName(_ name: String) -> Bool {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return AppDictionaryEntry.presets.contains {
            $0.appName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == key
        }
    }

    // MARK: - CSV primitives

    static func parseRows(_ text: String) -> [[String]] {
        let source = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var index = source.startIndex

        func pushField() {
            row.append(field)
            field = ""
        }

        func pushRow() {
            pushField()
            if isCommentRow(row) {
                row = []
                return
            }
            let meaningful = row.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if meaningful {
                rows.append(row.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            }
            row = []
        }

        while index < source.endIndex {
            let character = source[index]
            let next = source.index(after: index)
            if inQuotes {
                if character == "\"" {
                    if next < source.endIndex, source[next] == "\"" {
                        field.append("\"")
                        index = source.index(after: next)
                        continue
                    }
                    inQuotes = false
                } else {
                    field.append(character)
                }
            } else if character == "#" && row.isEmpty && field.trimmingCharacters(in: .whitespaces).isEmpty {
                // Whole-line comments, including those that contain commas.
                while index < source.endIndex, source[index] != "\n" {
                    index = source.index(after: index)
                }
                field = ""
                row = []
                if index < source.endIndex {
                    index = source.index(after: index)
                }
                continue
            } else if character == "\"" && field.isEmpty {
                inQuotes = true
            } else if character == "," {
                pushField()
            } else if character == "\n" {
                pushRow()
            } else if character == "\r" {
                // ignore; \n handles CRLF
            } else {
                field.append(character)
            }
            index = next
        }
        if inQuotes || !field.isEmpty || !row.isEmpty {
            if isCommentRow((row + [field]).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }) {
                field = ""
                row = []
            } else {
                pushRow()
            }
        }
        return rows
    }

    private static func csvRow(app: String, kind: String, word: String, exception: String) -> String {
        [app, kind, word, exception].map(escape).joined(separator: ",")
    }

    static func escape(_ field: String) -> String {
        if field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }

    private static func field(_ row: [String], _ index: Int) -> String {
        guard index < row.count else { return "" }
        return row[index]
    }

    private static func isHeader(_ app: String, _ kind: String, _ word: String) -> Bool {
        app.lowercased() == "app" && kind.lowercased() == "kind"
            && (word.lowercased() == "word" || word.lowercased() == "words")
    }

    private static func isCommentRow(_ row: [String]) -> Bool {
        let first = row.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            ?? row.first
            ?? ""
        return first.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#")
    }

    private static func isEveryApp(_ app: String) -> Bool {
        let key = app.lowercased()
        return key.isEmpty || key == "*" || key == "all" || key == "every" || key == "every app"
    }

    private static func splitWords(_ field: String) -> [String] {
        if field.contains(";") || field.contains("|") {
            let separators = CharacterSet(charactersIn: ";|")
            return CleanupPrompt.mergedDictionary(
                field.components(separatedBy: separators)
            )
        }
        let trimmed = field.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? [] : [trimmed]
    }

    private static func kindForApp(name: String, kindField: String) -> String {
        let trimmed = kindField.trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = TargetAppContext.Kind.allCases.first(where: { $0.rawValue == trimmed.lowercased() }) {
            return match.rawValue
        }
        let lower = trimmed.lowercased()
        if lower.contains("code") || lower.contains("editor") || lower.contains("xcode") {
            return TargetAppContext.Kind.codeEditor.rawValue
        }
        if lower.contains("chat") || lower.contains("slack") || lower.contains("discord") {
            return TargetAppContext.Kind.chat.rawValue
        }
        if lower.contains("browser") || lower.contains("safari") || lower.contains("chrome") {
            return TargetAppContext.Kind.browser.rawValue
        }
        if lower.contains("mail") {
            return TargetAppContext.Kind.mail.rawValue
        }
        if lower.contains("note") || lower.contains("notion") {
            return TargetAppContext.Kind.notes.rawValue
        }
        if lower.contains("term") {
            return TargetAppContext.Kind.terminal.rawValue
        }
        if let preset = AppDictionaryEntry.presets.first(where: {
            $0.appName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                == name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }) {
            return preset.kind
        }
        return trimmed.isEmpty ? TargetAppContext.Kind.other.rawValue : trimmed
    }

    private static func isExceptionBullet(_ line: String, forApp app: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("-") else { return false }
        let body = trimmed.drop(while: { $0 == "-" || $0.isWhitespace })
        let label = body.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? String(body)
        return label.lowercased().contains(app.lowercased())
    }
}
