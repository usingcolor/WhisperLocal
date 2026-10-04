import Foundation

struct CBScore: Codable {
    /// Nil unless the take is a probe.
    var probeFixed: Bool?
    var languageKept: Bool
    var leaked: Bool
    /// Names and numbers the output has that neither the raw take nor the
    /// answer key does — "Table 2" for "the table", a topic pasted into a take
    /// about something else.
    var invented: [String]
    var editRate: Double

    var harmed: Bool { !languageKept || leaked || !invented.isEmpty }
    var passes: Bool { (probeFixed ?? true) && !harmed }

    var summary: String {
        var parts: [String] = []
        if probeFixed == false { parts.append("probe not fixed") }
        if !languageKept { parts.append("language changed") }
        if leaked { parts.append("context line leaked") }
        if !invented.isEmpty { parts.append("invented " + invented.joined(separator: ", ")) }
        return parts.isEmpty ? "ok" : parts.joined(separator: "; ")
    }
}

/// Script checks only, so a run's verdicts do not depend on a judge's mood.
enum CBChecks {
    static func score(_ take: CBTake, output: String, dictionary: [String]) -> CBScore {
        CBScore(
            probeFixed: take.role == .probe ? probeFixed(take, output: output) : nil,
            languageKept: languageKept(take, output: output),
            leaked: output.contains("<context") || output.contains("</context"),
            invented: invented(output, take: take, dictionary: dictionary),
            editRate: editRate(output, expected: take.expected)
        )
    }

    /// Every required spelling present, exactly, and no misheard form left.
    static func probeFixed(_ take: CBTake, output: String) -> Bool {
        let required = take.required ?? []
        let lower = output.lowercased()
        return required.allSatisfy { output.contains($0) }
            && !(take.forbidden ?? []).contains { lower.contains($0.lowercased()) }
    }

    /// A Korean take stays Korean; an English one gains no Korean.
    static func languageKept(_ take: CBTake, output: String) -> Bool {
        let written = scripts(output)
        if take.language == "ko" { return written.hangul >= written.latin }
        return written.hangul <= scripts(take.raw).hangul
    }

    static func invented(_ output: String, take: CBTake, dictionary: [String]) -> [String] {
        let known = Set(tokens(take.raw + " " + take.expected + " " + dictionary.joined(separator: " ")))
        let numbers = numberValues(in: take.raw).union(numberValues(in: take.expected))
        var found: [String] = []
        for form in RelatedTakeScoring.termForms(in: output) where !isKnown(form, words: known, numbers: numbers) {
            found.append(form)
        }
        for value in digitValues(in: output) where !numbers.contains(value) {
            found.append(String(value))
        }
        return found
    }

    /// A term is known when every run of letters in it is a word the take or
    /// its key uses and every run of digits a number either says — so "12시"
    /// for "열두 시" and "2.0" for "two point oh" are formatting, not invention.
    private static func isKnown(_ form: String, words: Set<String>, numbers: Set<Int>) -> Bool {
        var runs: [(digits: Bool, text: String)] = []
        for character in form.lowercased() where character.isLetter || character.isNumber {
            let isDigit = character.isNumber
            if let last = runs.last, last.digits == isDigit {
                runs[runs.count - 1].text.append(character)
            } else {
                runs.append((isDigit, String(character)))
            }
        }
        return runs.allSatisfy { run in
            run.digits ? Int(run.text).map(numbers.contains) ?? false : words.contains(run.text)
        }
    }

    /// Word-level edits to reach the answer key, per word of the key. Case and
    /// punctuation are ignored: they are style, and the key is one style of many.
    static func editRate(_ output: String, expected: String) -> Double {
        let a = tokens(output), b = tokens(expected)
        guard !b.isEmpty else { return a.isEmpty ? 0 : 1 }
        var previous = Array(0...b.count)
        for (i, word) in a.enumerated() {
            var current = [i + 1] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (word == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return Double(previous[b.count]) / Double(b.count)
    }

    // MARK: - Pieces

    static func tokens(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    static func scripts(_ text: String) -> (hangul: Int, latin: Int) {
        var hangul = 0, latin = 0
        for scalar in text.unicodeScalars {
            if (0xAC00...0xD7A3).contains(scalar.value) { hangul += 1 }
            else if scalar.isASCII, CharacterSet.letters.contains(scalar) { latin += 1 }
        }
        return (hangul, latin)
    }

    private static func digitValues(in text: String) -> [Int] {
        text.split { !$0.isNumber }.compactMap { $0.count <= 9 ? Int($0) : nil }
    }

    /// Numbers a text says, in digits or words, so "three" in the raw take
    /// allows "3" in the output.
    static func numberValues(in text: String) -> Set<Int> {
        var values = Set<Int>()
        let words = tokens(text)
        for (index, word) in words.enumerated() {
            let digits = word.filter(\.isNumber)
            if !digits.isEmpty, digits.count <= 9, let value = Int(digits) { values.insert(value) }
            guard let value = numberWords[word] else { continue }
            values.insert(value)
            if value >= 20, value % 10 == 0, index + 1 < words.count,
               let unit = numberWords[words[index + 1]], unit < 10 {
                values.insert(value + unit)
            }
        }
        return values
    }

    private static let numberWords: [String: Int] = {
        var map: [String: Int] = ["oh": 0, "zero": 0, "hundred": 100, "thousand": 1000]
        let ones = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven",
                    "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
        let ordinals = ["first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth",
                        "tenth", "eleventh", "twelfth", "thirteenth", "fourteenth", "fifteenth", "sixteenth",
                        "seventeenth", "eighteenth", "nineteenth"]
        for (index, word) in ones.enumerated() { map[word] = index + 1 }
        for (index, word) in ordinals.enumerated() { map[word] = index + 1 }
        let tens = ["twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]
        for (index, word) in tens.enumerated() { map[word] = (index + 2) * 10 }
        map["twentieth"] = 20
        map["thirtieth"] = 30
        // Korean native numbers as they come up in times and counts.
        let korean = ["한": 1, "하나": 1, "두": 2, "둘": 2, "세": 3, "셋": 3, "네": 4, "넷": 4, "다섯": 5,
                      "여섯": 6, "일곱": 7, "여덟": 8, "아홉": 9, "열": 10, "열한": 11, "열두": 12]
        map.merge(korean) { current, _ in current }
        return map
    }()
}
