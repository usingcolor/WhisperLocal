import Foundation

/// Choosing earlier takes for the polish prompt by what they share with this
/// one, not only by how recent they are.
///
/// Words carry it. Embedding similarity alone can rank an unrelated take above
/// the take that teaches a name, or give the two candidates similar scores.
/// A candidate therefore has to share words few other takes use: one that the
/// earlier take wrote as a name or term, or at least two of any kind. The
/// embedding only adds to the score, or admits a take that says nearly the same
/// thing in other words.
///
/// One shared rare word of any kind is not enough. The log is small, so to it
/// "okay", "then" and "match" can be rare too, and an overly broad rule
/// paired takes on nothing but those.
enum RelatedTakeScoring {
    /// Shorter words are mostly fillers and function words ("uh", "so", "it").
    static let minimumWordLength = 3
    /// Cosine this high is the same thing said again, shared words or not.
    ///
    /// The three similarity numbers are for `NLContextualEmbedding`, mean-pooled.
    /// Its scores crowd into a narrow band — in the initial 107-take evaluation, the best
    /// older match for a take was 0.88 at the 10th percentile, 0.93 at the median
    /// and 0.95 at the 90th — so they are set from that band, not by feel: the
    /// floor at the median, restatement two spreads above it, and the scale so
    /// that a take at the 90th percentile earns 0.1. Set on 107 takes; check
    /// them again once the log is bigger.
    static let restatementCosine = 0.98
    /// Below this the embedding says nothing: the median best match already
    /// scores this much, whatever the take is about.
    static let cosineFloor = 0.926
    /// What each point of similarity above the floor is worth, against overlap.
    static let cosineScale = 3.7
    /// A take from the same app is a better guide to tone, all else equal.
    static let sameAppBonus = 0.1

    struct Candidate {
        let id: UUID
        let date: Date
        let words: Set<String>
        /// Words the take's cleaned text wrote as a name or term — see `terms(in:)`.
        let terms: Set<String>
        /// Nil when there is no embedding for the take's language.
        let cosine: Double?
        let sameApp: Bool
    }

    struct Match: Equatable {
        let id: UUID
        let score: Double
        let sharedRareWords: [String]
    }

    static func words(in text: String) -> Set<String> {
        Set(
            text.lowercased()
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
                .filter { $0.count >= minimumWordLength && !stopWords.contains($0) }
        )
    }

    /// Lowercased words the text writes as a name or term — see `termForms(in:)`.
    static func terms(in text: String) -> Set<String> {
        Set(termForms(in: text).map { $0.lowercased() })
    }

    /// Words the text writes as a name or term, as written: capitalised away
    /// from the start of a sentence ("Casey"), with a capital inside
    /// ("QuillMate", "ZXPL"), or letters and digits together ("GPT5"). Read from
    /// cleaned text, where the capitals are the polish's, not the recogniser's.
    static func termForms(in text: String) -> [String] {
        var found: [String] = []
        var token = ""
        var tokenStartsSentence = true
        var atSentenceStart = true

        func finish() {
            defer { token = "" }
            let lower = token.lowercased()
            guard lower.count >= minimumWordLength, !stopWords.contains(lower), let first = token.first else { return }
            let innerCapital = token.dropFirst().contains { $0.isUppercase }
            let lettersAndDigits = token.contains { $0.isNumber } && token.contains { $0.isLetter }
            let capitalised = first.isUppercase && !tokenStartsSentence
            if innerCapital || lettersAndDigits || capitalised {
                found.append(token)
            }
        }

        for character in text {
            if character.isLetter || character.isNumber {
                if token.isEmpty { tokenStartsSentence = atSentenceStart }
                token.append(character)
                continue
            }
            if !token.isEmpty {
                finish()
                atSentenceStart = false
            }
            if ".!?\n".contains(character) { atSentenceStart = true }
        }
        if !token.isEmpty { finish() }
        return found
    }

    /// English words too common to say two takes are about the same thing, and
    /// the fragments contractions split into. Everything else is left to how
    /// often the word appears in the log.
    static let stopWords: Set<String> = [
        "about", "above", "actually", "after", "again", "all", "also", "and", "any", "are",
        "aren", "because", "been", "before", "being", "both", "but", "can", "could", "couldn",
        "did", "didn", "does", "doesn", "doing", "don", "down", "each", "even", "for", "from",
        "get", "going", "gonna", "got", "had", "has", "have", "haven", "having", "her", "here",
        "hers", "him", "his", "how", "into", "isn", "its", "just", "know", "let", "like",
        "made", "make", "many", "maybe", "more", "most", "much", "must", "need", "not", "now",
        "off", "okay", "once", "one", "only", "other", "our", "ours", "out", "over", "own",
        "please", "pretty", "really", "right", "same", "say", "see", "she", "should",
        "shouldn", "some", "something", "still", "such", "sure", "than", "that", "the",
        "their", "them", "then", "there", "these", "they", "thing", "things", "think", "this",
        "those", "through", "too", "under", "until", "very", "want", "was", "wasn", "way",
        "well", "were", "weren", "what", "when", "where", "which", "while", "who", "why",
        "will", "with", "won", "would", "wouldn", "yeah", "yes", "you", "your", "yours",
    ]

    /// How many of the example slots go to related takes: 3 of 8, 2 of 5, 1 of 3
    /// or 2, none of 1. Recency keeps the majority, because the last few takes
    /// carry the thread of what is being worked on right now.
    static func relatedSlots(outOf count: Int) -> Int {
        guard count > 1 else { return 0 }
        return (count * 3 + 4) / 8
    }

    /// A word is rare when at most this many takes contain it: about one take
    /// in fifty, and never fewer than two.
    static func rareCeiling(takeCount: Int) -> Int {
        max(2, takeCount / 50)
    }

    static func rank(
        query: Set<String>,
        candidates: [Candidate],
        documentFrequency: [String: Int],
        takeCount: Int,
        limit: Int
    ) -> [Match] {
        guard limit > 0, !query.isEmpty, !candidates.isEmpty else { return [] }
        let total = Double(takeCount + 1)
        func weight(_ word: String) -> Double {
            log(total / Double((documentFrequency[word] ?? 0) + 1))
        }
        let queryWeight = query.reduce(0) { $0 + weight($1) }
        let ceiling = rareCeiling(takeCount: takeCount)

        var scored: [(match: Match, date: Date)] = []
        for candidate in candidates {
            let shared = query.intersection(candidate.words)
            let rare = shared.filter { (documentFrequency[$0] ?? 0) <= ceiling }.sorted()
            let cosine = candidate.cosine ?? 0
            let distinctive = rare.count >= 2 || rare.contains { candidate.terms.contains($0) }
            guard distinctive || cosine >= restatementCosine else { continue }
            // The share of this take's information the candidate also has, so a
            // long take does not win just by having more words to match.
            let overlap = queryWeight > 0 ? shared.reduce(0) { $0 + weight($1) } / queryWeight : 0
            let score = overlap
                + max(0, cosine - cosineFloor) * cosineScale
                + (candidate.sameApp ? sameAppBonus : 0)
            scored.append((Match(id: candidate.id, score: score, sharedRareWords: rare), candidate.date))
        }
        return scored
            .sorted { $0.match.score != $1.match.score ? $0.match.score > $1.match.score : $0.date > $1.date }
            .prefix(limit)
            .map(\.match)
    }
}
