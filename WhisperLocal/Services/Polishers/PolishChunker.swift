import Foundation

/// Splits a long transcript into pieces small enough to polish one at a time.
///
/// A long take used to go to the polisher whole, where it met a single 20s/30s
/// timeout and, on Anthropic, an output cap that pins at 4096 tokens. Either one
/// threw the whole request away and the raw transcript was pasted instead. Split
/// up, a failure costs one piece rather than every word of cleanup.
enum PolishChunker {
    /// Well inside every provider's window, and small enough that one piece
    /// comfortably finishes inside the existing polish timeout.
    static let budget = 3_000

    /// Pieces are cut at sentence boundaries, falling back to whitespace so a word
    /// is never split. A piece may exceed `budget` only when a single "sentence"
    /// does — dictation with no punctuation at all.
    static func split(_ text: String, budget: Int = budget) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard budget > 0, trimmed.count > budget else { return [trimmed] }

        var pieces: [String] = []
        var current = ""

        for sentence in sentences(of: trimmed) {
            if current.isEmpty {
                current = sentence
            } else if current.count + 1 + sentence.count <= budget {
                current += " " + sentence
            } else {
                pieces.append(current)
                current = sentence
            }
            // One sentence longer than the budget: break it on whitespace so we
            // never hand back a piece cut mid-word.
            while current.count > budget {
                let head = breakOnWhitespace(current, budget: budget)
                pieces.append(head)
                current = String(current.dropFirst(head.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    private static func sentences(of text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if ".!?".contains(character) {
                let piece = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !piece.isEmpty { out.append(piece) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { out.append(tail) }
        return out
    }

    private static func breakOnWhitespace(_ text: String, budget: Int) -> String {
        let limit = text.index(text.startIndex, offsetBy: min(budget, text.count))
        let head = text[text.startIndex..<limit]
        if let space = head.lastIndex(where: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
            let cut = String(text[text.startIndex..<space]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !cut.isEmpty { return cut }
        }
        // No whitespace inside the budget at all — a single enormous token.
        return String(head)
    }
}
