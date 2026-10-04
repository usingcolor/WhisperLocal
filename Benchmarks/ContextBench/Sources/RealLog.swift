import Foundation

/// `real-log`: your own takes, polished again with and without auto context,
/// for you to compare blind. Everything it writes stays under
/// Benchmarks/results, which git ignores — this is real dictation.
enum RealLog {
    struct Take: Codable {
        let id: UUID
        let date: Date
        let app: String?
        let raw: String
        let logged: String
        var plain = ""
        var plainAgain = ""
        var auto = ""
        var topicsShown: [String] = []
        var change = ""
    }

    /// One comparison on the page. `testSide` is where the auto-context output
    /// sits for a context pair, or the second plain run for a noise pair; the
    /// page keeps it out of sight until the end.
    struct Pair: Codable {
        let id: String
        let kind: String
        let app: String?
        let date: Date
        let raw: String
        let left: String
        let right: String
        let testSide: String
    }

    static func run(_ options: CBOptions, paths: CBPaths) async throws {
        let key = try CBKeys.openAI(allowKeychain: options.flags.contains("keychain"))
        let model = options.values["model"] ?? CBDevSettings.model
        let seed = options.values["seed"].flatMap(Int.init)
        let cache = CBCache(directory: paths.cache, fresh: options.flags.contains("fresh"))
        let logURL = options.values["log"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Application Support/WhisperLocalDev/dictation-log.json")
        let entries = try JSONDecoder().decode([DictationLogEntry].self, from: Data(contentsOf: logURL))
            .filter { $0.outcome == .success && !$0.raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.polished.isEmpty }
            .sorted { $0.date < $1.date }
        let personal = CBDevSettings.personalContext
        let dictionary = CBDevSettings.dictionary
        print("model \(model) · seed \(seed.map(String.init) ?? "none") · \(entries.count) takes from \(logURL.lastPathComponent)")

        // The examples every run gets are the log's own: what the app actually
        // sent at the time, the same for all three.
        func examples(before index: Int) -> String {
            let prior = entries[max(0, index - CBSession.recentWindow)..<index].reversed().map(DictationLogStore.example)
            return CleanupPrompt.formatRecentDictations(Array(prior), maxCharsPerSide: CleanupPrompt.cloudRecentMaxCharsPerSide)
        }
        func target(_ entry: DictationLogEntry) -> String? { entry.appName.map(CBSessionRunner.target) }

        var takes = entries.map { Take(id: $0.id, date: $0.date, app: $0.appName, raw: $0.raw, logged: $0.polished) }
        struct Job: Sendable { let index: Int; let sample: Int; let raw: String; let target: String?; let examples: String }
        let plainJobs = entries.indices.flatMap { index in
            [0, 1].map { Job(index: index, sample: $0, raw: entries[index].raw, target: target(entries[index]), examples: examples(before: index)) }
        }
        let plain = await cbBounded(plainJobs, width: options.int("parallel", 6)) { job in
            await CBPolish.run(engine: .openAI(model), key: key, seed: seed, sample: job.sample, cache: cache,
                               personalContext: personal, dictionary: dictionary,
                               raw: job.raw, target: job.target, examples: job.examples, intent: "").0.text
        }
        for (job, text) in zip(plainJobs, plain) {
            if job.sample == 0 { takes[job.index].plain = text } else { takes[job.index].plainAgain = text }
        }
        print("plain, twice: done")

        // In order, carrying the topics forward, as the Dev app does: polish sees
        // them as context, then the update after the paste reports the change.
        var context = AutoContext()
        for (index, entry) in entries.enumerated() {
            takes[index].topicsShown = context.topicTexts
            let (record, _) = await CBPolish.run(
                engine: .openAI(model), key: key, seed: seed, sample: 0, cache: cache,
                personalContext: personal, dictionary: dictionary,
                raw: entry.raw, target: target(entry), examples: examples(before: index),
                intent: AutoContext.polishIntent(session: "", topics: context.topics, now: entry.date)
            )
            takes[index].auto = record.text
            let update = await CBUpdate.run(
                engine: .openAI(model), key: key, seed: seed, sample: 0, cache: cache,
                topics: context.topics, take: record.text, target: target(entry), now: entry.date
            )
            takes[index].change = context.record(AutoContext.change(fromTag: update.tag), app: entry.appName, now: entry.date)
        }
        print("auto context: done")

        let directory = paths.run(options.runName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(takes).write(to: directory.appending(path: "reallog.json"))

        // Only differences in words are worth a look; case and punctuation are not.
        func differs(_ a: String, _ b: String) -> Bool { CBChecks.tokens(a) != CBChecks.tokens(b) }
        var random = CBRandom(seed: 20260928)
        func shuffled<T>(_ items: [T]) -> [T] {
            var items = items
            for index in items.indices.reversed() where index > 0 {
                items.swapAt(index, Int(random.next() % UInt64(index + 1)))
            }
            return items
        }
        let contextTakes = shuffled(takes.filter { differs($0.plain, $0.auto) }).prefix(options.int("pairs", 40))
        let noiseTakes = shuffled(takes.filter { differs($0.plain, $0.plainAgain) }).prefix(options.int("noise", 10))
        var pairs: [Pair] = []
        for (kind, chosen) in [("context", Array(contextTakes)), ("noise", Array(noiseTakes))] {
            for take in chosen {
                let test = kind == "context" ? take.auto : take.plainAgain
                let testLeft = random.next() % 2 == 0
                pairs.append(Pair(
                    id: "\(kind)-\(take.id.uuidString.prefix(8))", kind: kind, app: take.app, date: take.date, raw: take.raw,
                    left: testLeft ? test : take.plain, right: testLeft ? take.plain : test,
                    testSide: testLeft ? "left" : "right"
                ))
            }
        }
        pairs = shuffled(pairs)
        try encoder.encode(pairs).write(to: directory.appending(path: "pairs.json"))

        let pairsJSON = String(decoding: try encoder.encode(pairs), as: UTF8.self).replacingOccurrences(of: "</", with: "<\\/")
        let page = try String(contentsOf: paths.template, encoding: .utf8)
            .replacingOccurrences(of: "__RUN_ID__", with: directory.lastPathComponent)
            .replacingOccurrences(of: "\"__PAIRS_JSON__\"", with: pairsJSON)
        try page.write(to: directory.appending(path: "blind.html"), atomically: true, encoding: .utf8)

        let contextDiffers = takes.filter { differs($0.plain, $0.auto) }.count
        let noiseDiffers = takes.filter { differs($0.plain, $0.plainAgain) }.count
        print("words differ: auto context vs plain in \(contextDiffers) of \(takes.count) takes; plain vs plain again in \(noiseDiffers)")
        print("page: \(contextTakes.count) context pairs and \(noiseTakes.count) noise pairs, mixed")
        print("wrote \(directory.appending(path: "blind.html").path)")
    }
}

/// `blind-score`: the page's saved choices, scored against what it hid.
enum BlindScore {
    struct Saved: Decodable { let choices: [String: String] }

    static func run(_ options: CBOptions, paths: CBPaths) throws {
        guard let name = options.values["name"], let resultsPath = options.values["results"] else {
            throw CBError("blind-score needs --name <run> and --results <saved JSON>")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let pairs = try decoder.decode([RealLog.Pair].self, from: Data(contentsOf: paths.run(name).appending(path: "pairs.json")))
        let saved = try JSONDecoder().decode(Saved.self, from: Data(contentsOf: URL(fileURLWithPath: resultsPath)))
        print(summary(pairs: pairs, choices: saved.choices))
    }

    static func summary(pairs: [RealLog.Pair], choices: [String: String]) -> String {
        var lines: [String] = []
        for kind in ["context", "noise"] {
            let judged = pairs.filter { $0.kind == kind && choices[$0.id] != nil }
            let test = judged.filter { choices[$0.id] == $0.testSide }.count
            let same = judged.filter { choices[$0.id] == "same" }.count
            let other = judged.count - test - same
            let label = kind == "context" ? ("auto context", "plain") : ("second run", "first run")
            lines.append("\(kind) pairs: \(label.0) better \(test), \(label.1) better \(other), same \(same) — of \(judged.count)")
        }
        return lines.joined(separator: "\n")
    }
}
