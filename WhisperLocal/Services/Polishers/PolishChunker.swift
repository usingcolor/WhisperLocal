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

    /// Sentence enders. The full-width forms are what Japanese and Chinese use;
    /// with only ASCII here a long ja/zh take had no boundary at all and was
    /// hard-cut at the budget, mid-sentence.
    static let terminators: Set<Character> = [".", "!", "?", "。", "！", "？"]

    /// Japanese and Chinese put no space between words or sentences, so a piece
    /// must not gain one when sentences — or polished pieces — are put back
    /// together. Korean does use spaces, so Hangul is deliberately not in this
    /// set; English still joins with a space, exactly as before.
    static func separator(after text: String) -> String {
        guard let last = text.last else { return "" }
        if "。！？、，".contains(last) { return "" }
        return last.unicodeScalars.allSatisfy(isUnspacedScript) ? "" : " "
    }

    private static func isUnspacedScript(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF,   // Hiragana, Katakana
             0x3400...0x4DBF,   // CJK Extension A
             0x4E00...0x9FFF,   // CJK Unified Ideographs
             0xF900...0xFAFF:   // CJK Compatibility Ideographs
            return true
        default:
            return false
        }
    }

    /// Rejoins polished pieces with the same rule the split used.
    static func join(_ pieces: [String]) -> String {
        pieces.reduce(into: "") { joined, piece in
            let piece = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty else { return }
            joined += joined.isEmpty ? piece : separator(after: joined) + piece
        }
    }

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
            } else if current.count + separator(after: current).count + sentence.count <= budget {
                current += separator(after: current) + sentence
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
            if terminators.contains(character) {
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
        // Japanese and Chinese have no spaces to fall back on. A clause comma is
        // the next-best place, and keeps the cut off the middle of a word.
        if let comma = head.lastIndex(where: { $0 == "、" || $0 == "，" }) {
            let cut = String(text[text.startIndex...comma])
            if !cut.isEmpty { return cut }
        }
        // No whitespace inside the budget at all — a single enormous token.
        return String(head)
    }
}
