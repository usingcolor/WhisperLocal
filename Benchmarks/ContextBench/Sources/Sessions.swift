import Foundation

struct CBSessionFile: Decodable {
    let persona: CBPersona
    let sessions: [CBSession]

    static func load(_ url: URL) throws -> CBSessionFile {
        try JSONDecoder().decode(CBSessionFile.self, from: Data(contentsOf: url))
    }
}

struct CBPersona: Decodable {
    let personalContext: String
    let dictionary: [String]
}

struct CBThread: Decodable {
    let id: String
    /// What a perfect updater would keep for this thread: short, names exact.
    let topic: String
    /// How a kept topic is recognised as this thread, case-insensitively.
    let keywords: [String]
}

enum CBRole: String, Decodable {
    /// Says a name correctly, the first time the thread comes up.
    case setup
    /// Mishears a name an earlier take said. Only context can fix it when far.
    case probe
    /// More of a thread, no name.
    case distractor
    /// Must come back unchanged in meaning and language, context or not.
    case control
    case smalltalk
}

struct CBTake: Decodable {
    let id: String
    let minute: Double
    let app: String
    let thread: String?
    let role: CBRole
    let raw: String
    let expected: String
    let required: [String]?
    let forbidden: [String]?
    /// "ko" for a Korean take. Everything else is English.
    let language: String?
}

struct CBSession: Decodable {
    let id: String
    let summary: String
    let threads: [CBThread]
    let takes: [CBTake]

    /// The window polish sees as recent examples; `DictationController` sends
    /// the last eight takes.
    static let recentWindow = 8

    /// A probe is near when one of the previous eight takes says its name, so
    /// the recent examples alone can carry it; far when none does.
    func isNear(_ index: Int) -> Bool {
        let required = takes[index].required ?? []
        return takes[max(0, index - Self.recentWindow)..<index].contains { take in
            required.contains { take.expected.contains($0) }
        }
    }

    /// The topics a perfect updater would hold before take `index`, by the same
    /// rules `AutoContext` enforces: threads seen so far, oldest first, dropping
    /// any unused for 15 takes or 45 minutes, at most three — each with the
    /// apps its takes went into and when the last one was, as the app keeps
    /// them. `start` is the time of minute zero.
    func oracleTopics(before index: Int, start: Date) -> [AutoContext.Topic] {
        var firstSeen: [String: Int] = [:]
        var lastSeen: [String: Int] = [:]
        var apps: [String: [String]] = [:]
        for (position, take) in takes[..<index].enumerated() {
            guard let thread = take.thread else { continue }
            if firstSeen[thread] == nil { firstSeen[thread] = position }
            lastSeen[thread] = position
            apps[thread] = Array(([take.app] + (apps[thread] ?? []).filter { $0 != take.app }).prefix(AutoContext.maxApps))
        }
        let now = takes[index].minute
        let alive = lastSeen.filter { thread, position in
            index - position <= AutoContext.fadeAfterTakes
                && (now - takes[position].minute) * 60 <= AutoContext.fadeAfterIdle
        }
        let kept = alive.keys
            .sorted { (lastSeen[$0] ?? 0) > (lastSeen[$1] ?? 0) }
            .prefix(AutoContext.maxTopics)
            .sorted { (firstSeen[$0] ?? 0) < (firstSeen[$1] ?? 0) }
        return kept.compactMap { id in
            guard let topic = threads.first(where: { $0.id == id })?.topic, let last = lastSeen[id] else { return nil }
            return AutoContext.Topic(
                text: topic, apps: apps[id] ?? [], lastTake: last,
                lastUsedAt: start.addingTimeInterval(takes[last].minute * 60)
            )
        }
    }

    /// Which threads a kept topic belongs to. More than one is a merge.
    func threads(of topic: String) -> [String] {
        let lower = topic.lowercased()
        return threads.filter { thread in thread.keywords.contains { lower.contains($0.lowercased()) } }.map(\.id)
    }
}

/// `validate`: the cases checked against themselves before any money is spent.
/// Every expected text must pass the checks the runs are scored with, and
/// every probe's raw text must fail them, or the probe tests nothing.
enum Validate {
    static func run(paths: CBPaths) throws {
        let file = try CBSessionFile.load(paths.cases)
        var problems: [String] = []
        var probes = (near: 0, far: 0)
        var roles: [String: Int] = [:]
        var korean = 0
        for session in file.sessions {
            let threadIDs = Set(session.threads.map(\.id))
            var seenIDs = Set<String>()
            for (index, take) in session.takes.enumerated() {
                roles[take.role.rawValue, default: 0] += 1
                if take.language == "ko" { korean += 1 }
                if !seenIDs.insert(take.id).inserted { problems.append("\(take.id): duplicate id") }
                if let thread = take.thread, !threadIDs.contains(thread) { problems.append("\(take.id): unknown thread \(thread)") }
                if index > 0, take.minute < session.takes[index - 1].minute { problems.append("\(take.id): time goes backwards") }
                let gold = CBChecks.score(take, output: take.expected, dictionary: file.persona.dictionary)
                if !gold.passes { problems.append("\(take.id): its own expected text fails — \(gold.summary)") }
                if take.role == .probe {
                    if (take.required ?? []).isEmpty { problems.append("\(take.id): probe with nothing required") }
                    if CBChecks.probeFixed(take, output: take.raw) { problems.append("\(take.id): raw already passes; the probe tests nothing") }
                    if session.isNear(index) { probes.near += 1 } else { probes.far += 1 }
                }
            }
            for thread in session.threads where session.threads(of: thread.topic) != [thread.id] {
                problems.append("\(session.id): topic \"\(thread.topic)\" is not recognised as only \(thread.id)")
            }
        }
        let takes = file.sessions.reduce(0) { $0 + $1.takes.count }
        print("\(file.sessions.count) sessions, \(takes) takes")
        print("roles: " + roles.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        print("probes: \(probes.near) near, \(probes.far) far · Korean takes: \(korean)")
        if problems.isEmpty {
            print("ok: every expected text passes, every probe's raw text fails")
        } else {
            problems.forEach { print("  " + $0) }
            throw CBError("\(problems.count) problems in \(paths.cases.path)")
        }
    }
}
