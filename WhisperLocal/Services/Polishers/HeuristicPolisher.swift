import Foundation

/// Offline cleanup that approximates Wispr-style edits without an LLM.
/// Runs entirely on-device; no network. Cloud / local-LLM polish may follow.
struct HeuristicPolisher: TextPolisher {
    let name = "Heuristic"

    func polish(
        _ text: String,
        dictionary: [String],
        personalContext _: String = "",
        targetApp _: String? = nil
    ) async throws -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return result }

        result = applySpokenStructure(result)
        result = applySpokenPunctuation(result)
        result = applyScratchThat(result)
        result = applyMidSentenceCorrections(result)
        result = stripFillers(result)
        result = collapseWhitespace(result)
        result = stripUtteranceStarters(result)
        result = collapseRepeatedWords(result)
        result = collapseRepeatedBigrams(result)
        result = collapseWhitespace(result)
        result = applyDictionaryFixes(result, dictionary: dictionary)
        result = capitalizePronounI(result)
        result = capitalizeSentenceStarts(result, dictionary: dictionary)
        result = ensureTerminalPunctuation(result)

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Spoken structure / punctuation

    private func applySpokenStructure(_ text: String) -> String {
        var result = text
        result = replacing(#"\bnew paragraph\b|\bnext paragraph\b"#, in: result, with: "\n\n")
        result = replacing(#"\bnew line\b|\bnext line\b|\bnewline\b"#, in: result, with: "\n")
        return result
    }

    /// Determiners/modifiers that mark a *literal mention* of a punctuation name
    /// ("the comma", "an exclamation mark", "Oxford comma", "double quote").
    private static let mentionBefore =
        "(?:the|a|an|this|that|these|those|my|your|our|their|its|each|every|any|some|no"
        + "|oxford|serial|trailing|leading|double|single|closing|opening|matching)"

    /// Words that mark a literal mention when they follow ("comma separated", "colon is").
    private static let mentionAfter =
        "(?:separated|delimited|separator|delimiter|key|character|char|symbol|symbols"
        + "|rule|rules|usage|placement|notation|syntax|is|are|was|were|and|or|of|when|in|to|from|vs|versus)"

    /// Only convert when the word reads as a dictation command, not as its own name.
    /// A missed conversion stays readable; a wrong one destroys the word.
    private static func spokenPattern(_ core: String) -> String {
        "(?<!\\b" + mentionBefore + "\\s)\\b(?:" + core + ")\\b(?!\\s+" + mentionAfter + "\\b)"
    }

    private func applySpokenPunctuation(_ text: String) -> String {
        var result = text
        // Semicolon before colon so "semicolon" is not eaten as "semi" + "colon".
        let replacements: [(String, String)] = [
            (Self.spokenPattern(#"semi colon|semicolon"#), ";"),
            (Self.spokenPattern(#"comma"#), ","),
            (Self.spokenPattern(#"colon"#), ":"),
            (Self.spokenPattern(#"question mark"#), "?"),
            (Self.spokenPattern(#"exclamation point|exclamation mark"#), "!"),
            (Self.spokenPattern(#"full stop"#), "."),
            (Self.spokenPattern(#"open parenthesis|open paren"#), "("),
            (Self.spokenPattern(#"close parenthesis|close paren"#), ")"),
            (Self.spokenPattern(#"open quote"#), "\""),
            (Self.spokenPattern(#"close quote"#), "\""),
            (Self.spokenPattern(#"period"#), ".")
        ]
        for (pattern, replacement) in replacements {
            result = replacing(pattern, in: result, with: replacement)
        }
        return result
    }

    // MARK: - Self-corrections

    /// "… John scratch that send it to Sarah" → drop the clause before the marker.
    private func applyScratchThat(_ text: String) -> String {
        guard let marker = try? NSRegularExpression(
            pattern: #"\bscratch that\b[.,]?"#,
            options: [.caseInsensitive]
        ) else { return text }

        var result = text
        var guardCount = 0
        while guardCount < 8 {
            guardCount += 1
            let ns = result as NSString
            guard let match = marker.firstMatch(in: result, range: NSRange(location: 0, length: ns.length)),
                  let matchRange = Range(match.range, in: result) else { break }

            let before = result[..<matchRange.lowerBound]
            let after = result[matchRange.upperBound...]
            var cut = before.startIndex
            for index in before.indices {
                if ".!?\n".contains(before[index]) {
                    cut = before.index(after: index)
                }
            }
            result = (String(before[..<cut]) + String(after))
                .replacingOccurrences(of: #"^[ \t]+"#, with: "", options: .regularExpression)
        }
        return result
    }

    /// Mid-utterance replacements: "meet at 5 actually 6" → "meet at 6".
    /// Skips adverbial "actually" ("I actually think").
    private func applyMidSentenceCorrections(_ text: String) -> String {
        var result = text
        let preps = "at|on|to|for|by|from|until|till|into|onto|of"
        let markers = "actually|i mean|or rather|wait no|no wait"

        result = replacing(
            #"\b(\#(preps))\s+([\w'/-]+)\s+(?:\#(markers))\s+([\w'/-]+)\b"#,
            in: result,
            with: "$1 $3"
        )
        result = replacing(
            #"\b(\d+(?:[:.]\d+)?)\s+actually\s+(\d+(?:[:.]\d+)?)\b"#,
            in: result,
            with: "$2"
        )
        result = replacing(
            #"\b(\#(Self.weekdays))\s+actually\s+(\#(Self.weekdays))\b"#,
            in: result,
            with: "$2"
        )
        result = replacing(
            #"\b(\#(Self.months))\s+actually\s+(\#(Self.months))\b"#,
            in: result,
            with: "$2"
        )
        return result
    }

    private static let weekdays = "monday|tuesday|wednesday|thursday|friday|saturday|sunday"
    private static let months = "january|february|march|april|may|june|july|august|september|october|november|december"

    // MARK: - Fillers

    private func stripUtteranceStarters(_ text: String) -> String {
        // "so I think…" / "well we should…" — not "so much" / "well known"
        let starter = #"(?:so|well|okay|ok|alright|yeah)\s+(?=i\b|we\b|you\b|they\b|it\b|let's\b|lets\b)"#
        var result = replacing(#"^\s*"# + starter, in: text, with: "")
        result = replacing(#"([.!?]\s+)"# + starter, in: result, with: "$1")
        return result
    }

    private func stripFillers(_ text: String) -> String {
        var result = VocalFillerFilter.strip(text)
        result = replacing(#",\s*you know\s*,"#, in: result, with: " ")
        result = replacing(#"(?<=\s)you know,(?=\s)"#, in: result, with: "")
        result = replacing(#"^you know,?\s+"#, in: result, with: "")
        result = replacing(#",?\s*you know$"#, in: result, with: "")
        result = replacing(#",\s*i mean\s*,"#, in: result, with: " ")
        result = replacing(#"^i mean,?\s+"#, in: result, with: "")
        result = replacing(#"([.!?]\s+)i mean,?\s+"#, in: result, with: "$1")
        result = replacing(#",\s*sort of\s*,"#, in: result, with: " ")
        result = replacing(#",\s*kind of\s*,"#, in: result, with: " ")
        result = replacing(#",\s*like\s*,"#, in: result, with: " ")
        result = replacing(#"(?<=\s)like,(?=\s)"#, in: result, with: "")
        result = replacing(
            #"\b(was|is|are|were|it's|be)\s+like\s+(?=(really|so|just|literally|very|um|uh)\b)"#,
            in: result,
            with: "$1 "
        )
        return result
    }

    // MARK: - Repetition / whitespace

    private static let keptDoubles: Set<String> = ["had", "that"]

    private func collapseRepeatedWords(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"\b(\w+)(\s+\1\b)+"#,
            options: .caseInsensitive
        ) else { return text }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var result = text
        for match in matches.reversed() {
            guard let wordRange = Range(match.range(at: 1), in: result),
                  let fullRange = Range(match.range, in: result) else { continue }
            let word = String(result[wordRange]).lowercased()
            if Self.keptDoubles.contains(word) { continue }
            result.replaceSubrange(fullRange, with: String(result[wordRange]))
        }
        return result
    }

    private func collapseRepeatedBigrams(_ text: String) -> String {
        // Only collapse lowercase repetitions ("i think i think"). Keep "New York New York".
        replacing(#"\b(([a-z][\w']*)\s+([\w']+))\s+\1\b"#, in: text, with: "$1", caseInsensitive: false)
    }

    private func collapseWhitespace(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(of: #"^[ \t]+"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"[ \t]+([,.;!?:)])"#, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: #"([(\"])[ \t]+"#, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\n[ \t]+"#, with: "\n", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return result
    }

    // MARK: - Dictionary / casing / punctuation

    private func applyDictionaryFixes(_ text: String, dictionary: [String]) -> String {
        guard !dictionary.isEmpty else { return text }
        var result = text
        for word in dictionary {
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: word))\\b"
            result = replacing(
                pattern,
                in: result,
                with: NSRegularExpression.escapedTemplate(for: word)
            )
        }
        return result
    }

    private func capitalizePronounI(_ text: String) -> String {
        replacing(#"(?<!for |print )\bi\b"#, in: text, with: "I")
    }

    private func capitalizeSentenceStarts(_ text: String, dictionary: [String]) -> String {
        let dictLower = Dictionary(uniqueKeysWithValues: dictionary.map { ($0.lowercased(), $0) })
        var chars = Array(text)
        var capitalizeNext = true
        var i = 0
        while i < chars.count {
            if capitalizeNext, chars[i].isLetter {
                let word = wordAt(chars, startingAt: i)
                if let preferred = dictLower[word.lowercased()] {
                    let preferredChars = Array(preferred)
                    chars.replaceSubrange(i..<(i + word.count), with: preferredChars)
                    i += preferredChars.count
                    capitalizeNext = false
                    continue
                }
                chars[i] = Character(chars[i].uppercased())
                capitalizeNext = false
            } else if ".!?\n".contains(chars[i]) {
                capitalizeNext = true
            }
            i += 1
        }
        return String(chars)
    }

    private func wordAt(_ chars: [Character], startingAt index: Int) -> String {
        var end = index
        while end < chars.count, chars[end].isLetter || chars[end] == "'" || chars[end] == "-" {
            end += 1
        }
        return String(chars[index..<end])
    }

    private func ensureTerminalPunctuation(_ text: String) -> String {
        text.components(separatedBy: "\n").map(punctuateLine).joined(separator: "\n")
    }

    private func punctuateLine(_ line: String) -> String {
        var core = line.trimmingCharacters(in: .whitespaces)
        while core.last == "," {
            core = String(core.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        guard let last = core.last else { return line }
        if ".!?:;".contains(last) { return core }

        let words = core.split(whereSeparator: { $0.isWhitespace || $0 == "'" }).map(String.init)
        let firstWord = words.first?.lowercased() ?? ""
        let questionWords: Set<String> = ["who", "what", "when", "where", "why", "how"]
        if questionWords.contains(firstWord) {
            return core + "?"
        }
        let auxiliaries: Set<String> = [
            "is", "are", "do", "does", "did", "can", "could",
            "would", "will", "should", "may", "might"
        ]
        let questionSubjects: Set<String> = [
            "you", "i", "we", "they", "he", "she", "it",
            "there", "that", "this", "the", "my", "your",
            "our", "their", "his", "her", "its", "these", "those", "a", "an"
        ]
        if auxiliaries.contains(firstWord),
           let second = words.dropFirst().first?.lowercased(),
           questionSubjects.contains(second) {
            return core + "?"
        }
        return core + "."
    }

    // MARK: - Regex

    private func replacing(
        _ pattern: String,
        in text: String,
        with template: String,
        caseInsensitive: Bool = true
    ) -> String {
        var options: NSRegularExpression.Options = []
        if caseInsensitive { options.insert(.caseInsensitive) }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}

/// Drops vocalized pauses / sound effects that ASR writes as words.
/// Runs even when full heuristic cleanup is off, so Apple Intelligence still loses um / hmm / uh.
enum VocalFillerFilter {
    static func strip(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(
            of: #"\b(um+|uh+|uhm|er|erm|ah+|eh+|hm+|mm+|mhm)\b[.,!?…]*"#,
            with: " ",
            options: [.regularExpression, .caseInsensitive]
        )
        result = result.replacingOccurrences(of: #",[ \t]*,+"#, with: ",", options: .regularExpression)
        result = result.replacingOccurrences(of: #"^[ \t,;:]+"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"[ \t,;:]+$"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\s+([,.;!?])"#, with: "$1", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
