import Foundation

/// A failure a script can prove, no judge needed.
struct Failure: Codable, Sendable, Hashable {
    let code: String
    let detail: String
}

/// The failures that matter most, counted by code with zero tolerance.
enum HardChecks {
    /// Report order, with the label each one is shown under.
    static let kinds: [(code: String, label: String)] = [
        ("answered", "Answered or padded"),
        ("translated", "Changed language"),
        ("dropped", "Dropped content"),
        ("preamble", "Preamble or notes"),
        ("dictionary", "Dictionary word wrong"),
        ("missing", "Expected text missing"),
        ("forbidden", "Text that should be gone"),
        ("verbatim", "Changed a word-for-word case")
    ]

    static func run(_ output: TakeOutput, _ item: BenchCase) -> [Failure] {
        let text = Normalize.text(output.text)
        let reference = Normalize.text(item.reference)
        let checks = item.checks ?? CaseChecks()
        var failures: [Failure] = []

        if let hit = preamble(text, reference: reference) {
            failures.append(Failure(code: "preamble", detail: hit))
        }
        if let hit = languageSwitch(text, reference: reference) {
            failures.append(Failure(code: "translated", detail: hit))
        }

        let length = Normalize.visibleCount(text)
        let expected = Normalize.visibleCount(reference)

        // Almost none of the speaker's own words came back: the model answered the
        // dictation or rewrote it wholesale rather than cleaning it. Caught by
        // overlap rather than by length, because an answer is often shorter than
        // the question — "write a haiku about autumn" comes back as the haiku.
        let overlap = contentOverlap(text, reference: reference, byCharacter: item.scoresByCharacter)
        let answered = overlap < 0.4 && expected >= 12
        if answered {
            failures.append(Failure(code: "answered", detail: String(format: "%.0f%% of the answer key's words came back", overlap * 100)))
        }

        // Length against the answer key. The slack keeps "Yes." against "Yes!" from
        // counting, while "Yes." against "Yes, I can help with that." still does.
        let slack = Double(min(12, max(3, expected / 2)))
        let longest = Double(expected) * (checks.maxRatio ?? 1.5) + slack
        let shortest = Double(expected) * (checks.minRatio ?? 0.6) - slack / 2
        if !answered, Double(length) > longest {
            failures.append(Failure(code: "answered", detail: "\(length) characters, answer key has \(expected)"))
        }
        if !answered, Double(length) < shortest {
            failures.append(Failure(code: "dropped", detail: "\(length) characters, answer key has \(expected)"))
        }

        // Every dictionary word the answer key uses must come back spelled exactly.
        for term in item.promptDictionary where reference.contains(term) && !text.contains(term) {
            failures.append(Failure(code: "dictionary", detail: term))
        }

        for phrase in checks.mustContain ?? [] {
            let wanted = Normalize.text(phrase)
            let isDictionaryWord = item.promptDictionary.contains(phrase)
            // Dictionary terms are matched exactly, because their spelling is the
            // whole point. Every other anchor ignores case: capitalising the first
            // word of a sentence is cleaning, not a failure.
            if isDictionaryWord ? text.contains(wanted) : text.localizedCaseInsensitiveContains(wanted) { continue }
            if isDictionaryWord, reference.contains(phrase) { continue } // already counted above
            failures.append(Failure(code: isDictionaryWord ? "dictionary" : "missing", detail: phrase))
        }
        for phrase in checks.mustNotContain ?? [] where containsWord(text, phrase) {
            failures.append(Failure(code: "forbidden", detail: phrase))
        }
        if checks.verbatim == true, text != reference {
            failures.append(Failure(code: "verbatim", detail: "changed"))
        }
        return failures
    }

    // MARK: - Individual checks

    /// "Here's the cleaned text:", "Sure!", markdown, leaked prompt tags, or a note
    /// to the reader. Allowed when the answer key itself starts that way — a
    /// dictated "Sure, sounds good" is not a preamble.
    static func preamble(_ text: String, reference: String) -> String? {
        let opener = #"^(?:here(?:'s| is| are)\b|sure[,!.]|certainly\b|of course\b|okay[,!.]? here|(?:the )?(?:cleaned|corrected|polished|edited)(?: up)? (?:text|transcript|version)|(?:output|transcript|result|cleaned)\s*:|\*\*)"#
        if matches(opener, text), !matches(opener, reference) {
            return String(text.prefix(40))
        }
        let scaffolding = ["<transcript", "</transcript", "<target-app", "<app-notes", "<app-dictionary",
                           "<language", "<part ", "<session-intent", "```"]
        for tag in scaffolding where text.contains(tag) && !reference.contains(tag) {
            return "leaked \(tag)"
        }
        let aside = #"(?:^|\n|\s)\((?:note|i |i've|i have|the (?:speaker|transcript))|(?:^|\n)note:"#
        if matches(aside, text), !matches(aside, reference) {
            return "added a note"
        }
        return nil
    }

    /// Translation, or a script appearing that the speaker never used.
    static func languageSwitch(_ text: String, reference: String) -> String? {
        let out = ScriptShare(text)
        let key = ScriptShare(reference)
        if key.hangul >= 0.3, out.hangul < key.hangul * 0.5 {
            return String(format: "Hangul %.0f%% of letters, answer key %.0f%%", out.hangul * 100, key.hangul * 100)
        }
        if key.hangul == 0, out.hangul > 0 { return "Hangul in a take with none" }
        if key.kanaOrHan == 0, out.kanaOrHan > 0 { return "Chinese or Japanese characters in a take with none" }
        return nil
    }

    /// Share of the answer key's own words that came back at all.
    static func contentOverlap(_ text: String, reference: String, byCharacter: Bool) -> Double {
        let out = Set(TextDistance.tokens(text.lowercased(), byCharacter: byCharacter))
        let key = TextDistance.tokens(reference.lowercased(), byCharacter: byCharacter)
            .filter { byCharacter || ($0.count >= 3 && $0.rangeOfCharacter(from: .alphanumerics) != nil) }
        guard key.count >= 3 else { return 1 }
        return Double(key.filter { out.contains($0) }.count) / Double(key.count)
    }

    static func containsWord(_ text: String, _ phrase: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: Normalize.text(phrase))
        return matches(#"(?<![\p{L}\p{N}])"# + escaped + #"(?![\p{L}\p{N}])"#, text)
    }

    static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

struct ScriptShare {
    var hangul = 0.0
    var kanaOrHan = 0.0
    var latin = 0.0

    init(_ text: String) {
        var hangul = 0, kanaOrHan = 0, latin = 0, letters = 0
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            letters += 1
            switch scalar.value {
            case 0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F: hangul += 1
            case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF: kanaOrHan += 1
            case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F: latin += 1
            default: break
            }
        }
        guard letters > 0 else { return }
        self.hangul = Double(hangul) / Double(letters)
        self.kanaOrHan = Double(kanaOrHan) / Double(letters)
        self.latin = Double(latin) / Double(letters)
    }
}

enum Normalize {
    /// Curly quotes and runs of spaces are presentation, not content.
    static func text(_ text: String) -> String {
        var result = text
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(of: "“", with: "\"")
            .replacingOccurrences(of: "”", with: "\"")
        result = result.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func visibleCount(_ text: String) -> Int {
        text.reduce(0) { $0 + ($1.isWhitespace ? 0 : 1) }
    }
}

/// Edit distance to the answer key: 0 is identical, 1 is as many edits as the
/// answer has tokens. Case and punctuation count, because getting them right is
/// half of what polishing is for.
enum TextDistance {
    static func editRate(_ text: String, reference: String, byCharacter: Bool) -> Double {
        let out = tokens(Normalize.text(text), byCharacter: byCharacter)
        let key = tokens(Normalize.text(reference), byCharacter: byCharacter)
        guard !key.isEmpty else { return out.isEmpty ? 0 : 1 }
        return Double(levenshtein(out, key)) / Double(key.count)
    }

    /// Words and single punctuation marks. Korean goes by characters instead: the
    /// same sentence can be correctly spaced more than one way.
    static func tokens(_ text: String, byCharacter: Bool) -> [String] {
        if byCharacter {
            return text.filter { !$0.isWhitespace }.map(String.init)
        }
        let pattern = #"[\p{L}\p{M}\p{N}]+(?:['\-][\p{L}\p{M}\p{N}]+)*|[^\s\p{L}\p{M}\p{N}]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }

    static func levenshtein(_ a: [String], _ b: [String]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
