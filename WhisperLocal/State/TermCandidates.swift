import Foundation

/// A word the dictation log wrote as a name or term, not yet in any dictionary.
struct TermCandidate: Identifiable, Equatable, Sendable {
    /// Lowercased. What the dictionaries, the handled list and the model's
    /// answers are all matched on.
    let id: String
    /// The spelling it was written with most often.
    let form: String
    let takeCount: Int
    /// Apps it was dictated into, the most frequent first.
    let apps: [String]
    /// The sentence from its most recent take, so it can be judged in context.
    let example: String
    let lastSeen: Date
}

/// The half of dictionary suggestions that needs no model: which words the
/// log's cleaned text wrote as names or terms, and how often.
///
/// Not the half that decides. The list mixes real terms with ordinary words
/// capitalised in a heading ("Table", "Today") and with mishearings the polish
/// kept. The model screens out
/// the first; only the person can tell the second from a real term, so every
/// suggestion can be respelled before it is added.
enum TermCandidates {
    static let exampleLength = 160

    static func collect(
        from entries: [DictationLogEntry],
        knownText: String,
        handled: Set<String>
    ) -> [TermCandidate] {
        let known = words(in: knownText)

        struct Tally {
            var takes = 0
            var forms: [String: Int] = [:]
            var apps: [String: Int] = [:]
            var example = ""
            var lastSeen = Date.distantPast
        }
        var tallies: [String: Tally] = [:]

        for entry in entries where entry.outcome == .success {
            var seenInTake = Set<String>()
            for form in RelatedTakeScoring.termForms(in: entry.polished) {
                let key = form.lowercased()
                // The capitals test only means something in Latin script.
                guard form.contains(where: { $0.isASCII && $0.isLetter }),
                      !known.contains(key), !handled.contains(key) else { continue }
                var tally = tallies[key, default: Tally()]
                tally.forms[form, default: 0] += 1
                if seenInTake.insert(key).inserted {
                    tally.takes += 1
                    if let app = entry.appName { tally.apps[app, default: 0] += 1 }
                    if entry.date > tally.lastSeen {
                        tally.lastSeen = entry.date
                        tally.example = sentence(containing: form, in: entry.polished)
                    }
                }
                tallies[key] = tally
            }
        }

        return tallies
            .map { key, tally in
                TermCandidate(
                    id: key,
                    form: tally.forms.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key ?? key,
                    takeCount: tally.takes,
                    apps: tally.apps.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key),
                    example: tally.example,
                    lastSeen: tally.lastSeen
                )
            }
            // A fixed order, so the same log asks the model the same question and
            // gets the same answer.
            .sorted {
                if $0.takeCount != $1.takeCount { return $0.takeCount > $1.takeCount }
                if $0.lastSeen != $1.lastSeen { return $0.lastSeen > $1.lastSeen }
                return $0.id < $1.id
            }
    }

    /// Every word in the dictionaries and the system prompt, split the same way
    /// a candidate is, so "README.md" there covers "README" here.
    static func words(in text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }

    static func sentence(containing form: String, in text: String) -> String {
        let found = sentences(in: text).first { $0.contains(form) } ?? text
        let trimmed = found.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > exampleLength else { return trimmed }
        return String(trimmed.prefix(exampleLength)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Ends at ".", "!" or "?" followed by a space, or at a line break — not at
    /// every full stop, which would cut "README.md" in half.
    static func sentences(in text: String) -> [String] {
        var result: [String] = []
        var current = ""
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            if character == "\n" {
                result.append(current)
                current = ""
                continue
            }
            current.append(character)
            let next = index + 1 < characters.count ? characters[index + 1] : " "
            if ".!?".contains(character), next.isWhitespace {
                result.append(current)
                current = ""
            }
        }
        result.append(current)
        return result
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
