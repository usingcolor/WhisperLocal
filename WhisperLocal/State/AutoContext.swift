import Foundation

/// What the speaker has been working on, kept by the polish model in a second,
/// small request after each take is pasted — the cloud model, or Apple
/// Intelligence with a prompt of its own. Available in the public app from 0.2.5.
///
/// Polish sees the topics the way it sees a context set with Shift and is asked
/// nothing back. Asking it for the change in the same reply cost 0.7 s on every
/// paste, and GPT-6 Luna left the line out of 29% of replies. Asked separately,
/// the same model keeps topics that let polish recover 80% of the names only
/// context can supply — 60% in the same reply, 38% with no topics at all
/// (Benchmarks/ContextBench, 28 Sep 2026).
///
/// Several things can be going on at once — a paper in Overleaf, a chat about
/// lunch — so it holds up to three topics rather than one line, and it moves
/// slowly on purpose. The model is asked for one small change per take, and
/// the app holds it to that whatever it answers:
///
/// - At most one change per take.
/// - A topic is at most eight words, and a longer answer is cut. Unchecked, the
///   model grew topics into to-do lists, ten words at the median.
/// - A refinement has to keep at least half of the topic's words. One that does
///   not is added as a new topic instead, and the old one fades on its own.
/// - An addition that repeats a topic refreshes that topic rather than
///   duplicating it.
/// - The model never removes a topic. Topics fade: one unused for 15 takes or
///   45 minutes goes, and a fourth pushes out the one used longest ago.
///
/// Each topic also keeps where and when: the last two apps it came up in and
/// how long ago it was last used. The app records these; no model is asked
/// for them. Cloud polish sees the topics as a list of what the speaker has
/// been doing, newest first — "Pellucid rebuttal for ICLR (Overleaf, 2 min
/// ago)" — and the cloud model that keeps them sees the same beside the app the
/// take went into. Told that a take in a topic's app soon after is often part
/// of it, GPT-6 Luna let more topics fade when work moved between apps (a paper
/// in Overleaf, then ChatGPT), so it is only shown where and when, not told
/// what to make of them. Apple Intelligence sees neither: it keeps names from
/// the take alone, and polishes with the topics on one line.
///
/// The Context window also keeps typed notes and corrected topics. Those belong
/// to the user: learning cannot rewrite, expire, or evict them.
struct AutoContext: Equatable, Sendable {
    static let isEnabled = true

    struct Topic: Equatable, Sendable, Identifiable {
        enum Source: Equatable, Sendable {
            case automatic, typed, edited, shift

            var isAutomatic: Bool { self == .automatic }
        }
        /// A reply's topic number still names this topic if another expires
        /// while the request is in flight.
        var id = UUID()
        var text: String
        var source: Source = .automatic
        /// The apps it came up in, the latest first; at most `maxApps`.
        var apps: [String] = []
        /// The take this topic was last added, used or refined on.
        var lastTake: Int
        var lastUsedAt: Date
    }

    enum Change: Equatable, Sendable {
        /// Small talk, a one-off, or too short to tell. Named so it cannot be
        /// mistaken for `Optional.none`, which means the model gave no answer.
        case skip
        /// 1-based, as the prompt numbers them.
        case use(Int)
        case refine(Int, String)
        case add(String)

        /// The line a cloud model writes for this change, so an answer given in
        /// another form reads the same in the log and the benchmark.
        var tag: String {
            switch self {
            case .skip: return "<context-none/>"
            case .use(let number): return "<context-use n=\"\(number)\"/>"
            case .refine(let number, let text): return "<context-refine n=\"\(number)\">\(text)</context-refine>"
            case .add(let text): return "<context-add>\(text)</context-add>"
            }
        }
    }

    /// Apple Intelligence's answer: the names a take uses. On this path a topic
    /// is a list of names — what polish needs from it — and the app, not the
    /// model, decides where they go. Names that share a topic with one already
    /// kept join it, newest first, so the eight-word cut drops the oldest;
    /// others start a topic.
    ///
    /// A name counts only if the take has it exactly as given and it has a
    /// capital or a digit: the model also lists plain words — "table",
    /// "invoice", "diff" — which would push real names out. That leaves out
    /// names in a script without capitals; it listed 아빠 and 시간 as names, and
    /// there is nothing to check them against.
    ///
    /// The ~3B model is asked for nothing else because it could not do more.
    /// Given use, refine, add and skip, it answered "use 1" to nearly every
    /// take, with nothing listed yet. Shown the topics, it copied the first into
    /// its answer; asked what named work a take is part of, it named the task
    /// in front of it — "table", "invoice", "diff" — and pushed the real
    /// topics out.
    static func change(names: [String], in take: String, topics: [String]) -> Change {
        var found: [String] = []
        let edges = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,;:!?\"'“”‘’()"))
        // "Yep." and "Thanks." came back as names: capitalised, and in the take.
        let whole = take.trimmingCharacters(in: edges)
        for raw in names {
            let name = raw.trimmingCharacters(in: edges)
            guard name.count >= 2,
                  name.contains(where: { $0.isUppercase || $0.isNumber }),
                  containsName(name, in: take),
                  name.caseInsensitiveCompare(whole) != .orderedSame,
                  !calendarWords.contains(name.lowercased()),
                  !found.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { continue }
            found.append(name)
        }
        guard !found.isEmpty else { return .skip }
        func has(_ topic: String, _ name: String) -> Bool {
            containsName(name, in: topic, options: [.caseInsensitive, .diacriticInsensitive])
        }
        guard let index = topics.firstIndex(where: { topic in found.contains { has(topic, $0) } }) else {
            return .add(found.joined(separator: ", "))
        }
        let new = found.filter { !has(topics[index], $0) }
        return new.isEmpty ? .use(index + 1) : .refine(index + 1, (new + [topics[index]]).joined(separator: ", "))
    }

    /// Capitalised, so they pass for names, and it lists them despite being
    /// told not to: "Thursday" took one of three topics in the benchmark.
    private static let calendarWords: Set<String> = {
        let calendar = Calendar(identifier: .gregorian)
        var english = calendar
        english.locale = Locale(identifier: "en_US_POSIX")
        return Set((english.weekdaySymbols + english.monthSymbols).map { $0.lowercased() })
    }()

    static let maxTopics = 3
    static let maxUserTopics = 6
    static let maxApps = 2
    static let maxWords = 8
    /// For a script written without spaces, where eight words can be a paragraph.
    static let maxCharacters = 120
    static let fadeAfterTakes = 15
    static let fadeAfterIdle: TimeInterval = SessionContext.idleExpiry
    static let refineKeepsAtLeast = 0.5

    private(set) var topics: [Topic] = []
    private(set) var takes = 0

    var topicTexts: [String] { topics.map(\.text) }
    var isEmpty: Bool { topics.isEmpty }
    var userTopics: [Topic] { topics.filter { !$0.source.isAutomatic } }

    func liveTopics(now: Date = Date()) -> [Topic] {
        topics.filter { !isStale($0, now: now) }
    }

    /// The order the lists show topics in: the one used last comes first.
    static func newestFirst(_ topics: [Topic]) -> [Topic] {
        topics.sorted { $0.lastTake > $1.lastTake }
    }

    /// What cloud polish is told the speaker is working on: a context set with
    /// Shift as they said it, then the kept topics as a list, newest first,
    /// each with where it came up and how long ago.
    ///
    /// Against the same topics on one line, GPT-6 Luna fixed more far probes
    /// with the list: 100% against 95% given the correct topics, 95% against 92%
    /// with names kept by Apple Intelligence (Benchmarks/ContextBench, 30 Sep
    /// 2026). Apple Intelligence polish did worse with it, so it gets
    /// `onDevicePolishIntent`.
    static func polishIntent(session: String, topics: [Topic], now: Date) -> String {
        var lines: [String] = []
        let session = userIntent(session: session, topics: topics)
        if !session.isEmpty {
            lines.append(session)
        }
        let automatic = topics.filter { $0.source.isAutomatic }
        if !automatic.isEmpty {
            lines.append("Recently, newest first:")
            lines += newestFirst(automatic).map { "- \($0.text) (\(whereAndWhen($0, now: now)))" }
        }
        return lines.joined(separator: "\n")
    }

    /// What Apple Intelligence polish is told: the Shift context, then the
    /// topics' words on one line, as they are kept. Shown the list, the ~3B
    /// model fixed 8 of 20 far probes against 10 on one line, and once put the
    /// first name listed in place of the one said — "Professor Nnamdi" for
    /// "Adebayo-Lindqvist".
    static func onDevicePolishIntent(session: String, topics: [Topic]) -> String {
        [userIntent(session: session, topics: topics), topics.filter { $0.source.isAutomatic }.map(\.text).joined(separator: "; ")]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    static func userIntent(session: String, topics: [Topic]) -> String {
        let session = session.trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = topics.filter { !$0.source.isAutomatic }.map { "- \($0.text)" }
        return ([session] + (notes.isEmpty ? [] : ["User-provided context; prefer these spellings over automatic topics:"] + notes))
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// "Overleaf and ChatGPT, 12 min ago": the apps a topic came up in and
    /// when it was last used, as every list of topics shows them.
    static func whereAndWhen(_ topic: Topic, now: Date) -> String {
        let when = ago(topic.lastUsedAt, now: now)
        return topic.apps.isEmpty ? when : topic.apps.joined(separator: " and ") + ", " + when
    }

    static func ago(_ date: Date, now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(date) / 60)
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes) min ago" }
        return "\(minutes / 60) h ago"
    }

    /// Applies what the model said about one take, fades stale topics, and
    /// says what happened in words the log can show. `app` is where the take
    /// went; the topic it was added to, used or refined on remembers it.
    @discardableResult
    mutating func record(_ change: Change?, app: String? = nil, now: Date = Date()) -> String {
        takes += 1
        let app = app?.trimmingCharacters(in: .whitespacesAndNewlines)
        let place = app?.isEmpty == false ? app : nil
        let happened: String
        let faded: [String]
        if case .add? = change {
            // Room first, so a stale topic goes before a live one is pushed out.
            faded = expire(now: now)
            happened = apply(change, app: place, now: now)
        } else {
            // An answer's numbers are the list the model was shown, so they are
            // read before anything fades — and a topic named again stays.
            happened = apply(change, app: place, now: now)
            faded = expire(now: now)
        }
        return faded.isEmpty ? happened : happened + "; faded: " + faded.joined(separator: " | ")
    }

    /// Resolve the answer against the list actually shown, never a newly shifted
    /// index. Use the take's date for recency, but today's clock for expiry so a
    /// delayed answer cannot bring an idle topic back.
    @discardableResult
    mutating func record(
        _ change: Change?, relativeTo shown: [Topic], app: String? = nil,
        now: Date = Date(), observedAt: Date? = nil
    ) -> String {
        let clock = observedAt ?? now
        var faded = expire(now: clock)
        var resolved = change
        var missingTopic = false
        switch change {
        case .use(let number)?, .refine(let number, _)?:
            if shown.indices.contains(number - 1),
               let index = topics.firstIndex(where: { $0.id == shown[number - 1].id }) {
                if case .refine(_, let text)? = change {
                    resolved = .refine(index + 1, text)
                } else {
                    resolved = .use(index + 1)
                }
            } else {
                resolved = .skip
                missingTopic = true
            }
        default: break
        }
        var happened = record(resolved, app: app, now: now)
        if missingTopic {
            happened = "unchanged (topic no longer available)" + String(happened.dropFirst("unchanged".count))
        }
        faded += expire(now: clock)
        return faded.isEmpty ? happened : happened + "; faded: " + faded.joined(separator: " | ")
    }

    private mutating func apply(_ change: Change?, app: String?, now: Date) -> String {
        let happened: String
        switch change {
        case nil:
            happened = "no answer"
        case .skip?:
            happened = "unchanged"
        case .use(let number)?:
            if topics.indices.contains(number - 1) {
                touch(number - 1, app: app, now: now)
                happened = "used \(number)"
            } else {
                happened = "unchanged (no topic \(number))"
            }
        case .refine(let number, let raw)?:
            guard let text = Self.clean(raw) else { happened = "unchanged"; break }
            guard topics.indices.contains(number - 1) else {
                happened = add(text, app: app, now: now)
                break
            }
            guard topics[number - 1].source.isAutomatic else {
                happened = "unchanged (user-controlled topic)"
                break
            }
            if Self.keepsEnough(of: topics[number - 1].text, in: text) {
                topics[number - 1].text = text
                touch(number - 1, app: app, now: now)
                happened = "refined \(number): \(text)"
            } else {
                happened = "too big a change to \(number), so " + add(text, app: app, now: now)
            }
        case .add(let raw)?:
            guard let text = Self.clean(raw) else { happened = "unchanged"; break }
            happened = add(text, app: app, now: now)
        }
        return happened
    }

    mutating func clear() {
        topics = []
    }

    mutating func clearAutomatic() {
        topics.removeAll { $0.source.isAutomatic }
    }

    mutating func remove(id: UUID) {
        topics.removeAll { $0.id == id }
    }

    /// A saved correction retains its identity but leaves the model's collection.
    /// Explicit user text gets the manual-context budget, not the eight-word cut.
    mutating func setUserTopic(id: UUID = UUID(), text: String, source: Topic.Source = .typed, now: Date = Date()) {
        let text = SessionContext.capped(text)
        guard !text.isEmpty else { remove(id: id); return }
        if let index = topics.firstIndex(where: { $0.id == id }) {
            topics[index].text = text
            topics[index].source = source.isAutomatic ? .edited : source
            topics[index].lastUsedAt = now
        } else {
            topics.append(Topic(id: id, text: text, source: source.isAutomatic ? .edited : source, lastTake: takes, lastUsedAt: now))
        }
    }

    private mutating func add(_ text: String, app: String?, now: Date) -> String {
        if let existing = topics.firstIndex(where: {
            Self.keepsEnough(of: $0.text, in: text) || Self.keepsEnough(of: text, in: $0.text)
        }) {
            touch(existing, app: app, now: now)
            return "already noted as \(existing + 1)"
        }
        topics.append(Topic(text: text, apps: app.map { [$0] } ?? [], lastTake: takes, lastUsedAt: now))
        let automatic = topics.indices.filter { topics[$0].source.isAutomatic }
        guard automatic.count > Self.maxTopics,
              let oldest = automatic.min(by: { topics[$0].lastTake < topics[$1].lastTake }) else {
            return "added: \(text)"
        }
        let dropped = topics.remove(at: oldest)
        return "added: \(text); dropped: \(dropped.text)"
    }

    private mutating func touch(_ index: Int, app: String?, now: Date) {
        guard topics[index].source.isAutomatic else { return }
        topics[index].lastTake = takes
        topics[index].lastUsedAt = now
        guard let app else { return }
        var apps = topics[index].apps.filter { $0.caseInsensitiveCompare(app) != .orderedSame }
        apps.insert(app, at: 0)
        topics[index].apps = Array(apps.prefix(Self.maxApps))
    }

    @discardableResult
    mutating func expire(now: Date = Date()) -> [String] {
        let stale = topics.filter { isStale($0, now: now) }
        topics.removeAll { topic in stale.contains(topic) }
        return stale.map(\.text)
    }

    private func isStale(_ topic: Topic, now: Date) -> Bool {
        topic.source.isAutomatic && (takes - topic.lastTake > Self.fadeAfterTakes || now.timeIntervalSince(topic.lastUsedAt) > Self.fadeAfterIdle)
    }

    // MARK: - Reading the model's line

    /// The change a `<context-…>` tag asks for, or nil for no usable answer.
    ///
    /// Reads the loose forms GPT-6 Luna also answers with — `<context-use 1/>`,
    /// `<context-use>1</context-use>`, a refinement with no topic number — which
    /// were 9 of its 360 answers in the benchmark, all lost as "no answer".
    static func change(fromTag tag: String?) -> Change? {
        guard let tag = tag?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if tag.hasPrefix("<context-none") { return .skip }
        let attributes = firstMatch(#"^<context-\w+([^>]*)>"#, in: tag) ?? ""
        let number = firstMatch(#"(\d+)"#, in: attributes).flatMap { Int($0) }
        let body = firstMatch(#"^<context-\w+[^>]*>(.*)</context-\w+\s*>$"#, in: tag)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // A bare number where the topic goes names a topic and adds nothing to it.
        let named = body.flatMap { Int($0) }
        if tag.hasPrefix("<context-use") {
            return (number ?? named).map { Change.use($0) }
        }
        if tag.hasPrefix("<context-refine") {
            if let named { return .use(number ?? named) }
            guard let body, !body.isEmpty else { return number.map { Change.use($0) } }
            // No number: an addition, which refreshes the topic it repeats.
            guard let number else { return .add(body) }
            return .refine(number, body)
        }
        if tag.hasPrefix("<context-add") {
            guard let body, !body.isEmpty else { return nil }
            return .add(body)
        }
        return nil
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    /// One line of at most eight words, no wrapping quotes. Nil when nothing is left.
    static func clean(_ raw: String) -> String? {
        var text = raw
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        let quotes: Set<Character> = ["\"", "'", "“", "”", "‘", "’"]
        while let first = text.first, quotes.contains(first) { text.removeFirst() }
        while let last = text.last, quotes.contains(last) { text.removeLast() }
        text = text.trimmingCharacters(in: .whitespaces)
        let parts = text.split(separator: " ")
        if parts.count > maxWords {
            // Cut where the eighth word ends, without the comma or dash it ran
            // on with, and marked so the menu does not show it as the whole topic.
            text = parts.prefix(maxWords).joined(separator: " ")
                .trimmingCharacters(in: CharacterSet(charactersIn: ",;:-–—").union(.whitespaces)) + "…"
        }
        guard !text.isEmpty else { return nil }
        guard text.count > maxCharacters else { return text }
        return String(text.prefix(maxCharacters - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Whether `new` keeps at least half of the words in `old`.
    static func keepsEnough(of old: String, in new: String) -> Bool {
        let before = words(old)
        guard !before.isEmpty else {
            return old.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(new.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
        }
        let kept = before.intersection(words(new)).count
        return Double(kept) / Double(before.count) >= refineKeepsAtLeast
    }

    /// Keep short names and acronyms (Bo, AI, UI, C) as well as longer words.
    /// Lowercase only after checking capitals, which distinguish short names
    /// from connective words like "of".
    private static func words(_ text: String) -> Set<String> {
        Set(
            text.split { !$0.isLetter && !$0.isNumber }
                .filter { $0.count >= 3 || $0.contains { !$0.isASCII || $0.isUppercase || $0.isNumber } }
                .map { $0.lowercased() }
        )
    }

    private static func containsName(
        _ name: String, in text: String, options: String.CompareOptions = []
    ) -> Bool {
        guard !name.isEmpty else { return false }
        var search = text.startIndex..<text.endIndex
        func isWord(_ character: Character) -> Bool {
            character.isLetter || character.isNumber || character == "_"
        }
        while let range = text.range(of: name, options: options, range: search) {
            let left = range.lowerBound == text.startIndex || !isWord(text[text.index(before: range.lowerBound)])
            let right = range.upperBound == text.endIndex || !isWord(text[range.upperBound])
            if left && right { return true }
            search = text.index(after: range.lowerBound)..<text.endIndex
        }
        return false
    }
}
