import Foundation

enum CBArm: String, CaseIterable, Codable {
    /// What the app does without auto context: recent takes as examples only.
    case plain
    /// The correct topics, as the session context a perfect updater would keep,
    /// with nothing asked back. The most context can do for polish.
    case oracle
    /// Retired 28 Sep 2026: polish saw the kept topics and reported a change in
    /// the same reply. It kept 38% of what correct topics gain, cost 0.7 s on the
    /// paste, and the app no longer has it. Kept so earlier runs still read.
    case single
    /// The Dev design: polish sees the kept topics as session context and is
    /// asked nothing; a second request, after the paste in the app, reports the
    /// change.
    case separate

    static let runnable: [CBArm] = [.plain, .oracle, .separate]
}

struct CBStep: Codable {
    let session: String
    let take: String
    let arm: CBArm
    let sample: Int
    let output: String
    let seconds: Double
    let cleanupFailed: Bool
    let topicsShown: [String]
    let tag: String?
    let change: String?
    let topicsAfter: [String]
    let updaterSeconds: Double?
    /// The updater's whole reply, to see why one had no line in it.
    var updaterReply: String? = nil
}

struct CBPolishRecord: Codable {
    let text: String
    let seconds: Double
}

/// Where a step runs: an OpenAI model, or Apple Intelligence on this Mac.
enum CBEngine: Equatable, Sendable {
    case openAI(String)
    case apple

    /// `--polish` / `--updater`: `cloud` for the OpenAI model, or `apple`.
    static func parse(_ value: String?, model: String) throws -> CBEngine? {
        switch value {
        case nil: return nil
        case "cloud"?: return .openAI(model)
        case "apple"?: return .apple
        case let other?: throw CBError("unknown engine \(other): use cloud or apple")
        }
    }

    /// Part of every cache key. Apple's model changes with the OS, so its
    /// build is part of the name.
    var id: String {
        switch self {
        case .openAI(let model): return model
        case .apple: return "apple-intelligence " + ProcessInfo.processInfo.operatingSystemVersionString
        }
    }

    var label: String {
        switch self {
        case .openAI(let model): return model
        case .apple: return "Apple Intelligence"
        }
    }

    var isApple: Bool { self == .apple }
}

/// Automatic context's second request, as the Dev app makes it after a paste:
/// the app's prompt, the app's model call and the app's reading of the answer.
/// Cached like polish.
enum CBUpdate {
    struct Record: Codable {
        let tag: String?
        let seconds: Double
        var reply: String? = nil
    }

    static func run(
        engine: CBEngine, key: String, seed: Int?, sample: Int, cache: CBCache,
        topics: [AutoContext.Topic], take: String, target: String?, now: Date
    ) async -> Record {
        guard case .openAI(let model) = engine else {
            return await apple(engine: engine, cache: cache, topics: topics.map(\.text), take: take)
        }
        let cacheKey = CBCache.key([
            "update", ContextBench.harnessVersion, model, seed.map(String.init) ?? "-", String(sample),
            CleanupPrompt.autoContextSystem,
            CleanupPrompt.autoContextMessage(topics: topics, take: take, targetApp: target, now: now),
        ])
        if let cached = cache.load(cacheKey, as: Record.self) { return cached }
        var asker = OpenAIPolisher(apiKey: key, model: model)
        asker.seed = seed
        let started = Date()
        // A failed request is the network's word, not the model's: not cached.
        guard let answer = try? await CloudContextUpdater(model: asker)
            .answer(topics: topics, take: take, targetApp: target, now: now) else {
            return Record(tag: nil, seconds: Date().timeIntervalSince(started))
        }
        let record = Record(
            tag: CleanupPrompt.lastContextTag(in: answer.raw), seconds: Date().timeIntervalSince(started), reply: answer.raw
        )
        cache.save(record, key: cacheKey)
        return record
    }

    private struct Names: Codable {
        let names: [String]
        let seconds: Double
    }

    /// Apple Intelligence sees only the take and is greedy, so what it said is
    /// cached per take, and the app's rule for where names go runs every time:
    /// a change to that rule costs nothing to see.
    private static func apple(engine: CBEngine, cache: CBCache, topics: [String], take: String) async -> Record {
        let cacheKey = CBCache.key([
            "names", ContextBench.harnessVersion, engine.id,
            CleanupPrompt.appleAutoContextInstructions, CleanupPrompt.appleAutoContextMessage(take: take),
        ])
        let said: Names
        if let cached = cache.load(cacheKey, as: Names.self) {
            said = cached
        } else {
            let started = Date()
            guard let names = try? await AppleIntelligenceContextUpdater.names(in: take) else {
                return Record(tag: nil, seconds: Date().timeIntervalSince(started))
            }
            said = Names(names: names, seconds: Date().timeIntervalSince(started))
            cache.save(said, key: cacheKey)
        }
        let change = AutoContext.change(names: said.names, in: take, topics: topics)
        return Record(tag: change.tag, seconds: said.seconds, reply: change.tag + "\nnames: " + said.names.joined(separator: " | "))
    }
}

/// Runs one session through one arm, take by take, the way the app would: each
/// take's examples are this run's own earlier outputs, and the kept topics
/// carry forward.
struct CBSessionRunner: Sendable {
    let persona: CBPersona
    let key: String
    let polish: CBEngine
    let updater: CBEngine
    let seed: Int?
    let cache: CBCache

    func run(_ session: CBSession, arm: CBArm, sample: Int) async -> [CBStep] {
        var context = AutoContext()
        var history: [RecentDictationExample] = []
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var steps: [CBStep] = []

        for (index, take) in session.takes.enumerated() {
            let now = start.addingTimeInterval(take.minute * 60)
            let target = Self.target(take.app)
            var intent = ""
            let shown: [String]
            switch arm {
            case .plain:
                shown = []
            case .oracle:
                let oracle = session.oracleTopics(before: index, start: start)
                shown = oracle.map(\.text)
                intent = Self.intent(oracle, polish: polish, now: now)
            case .single:
                preconditionFailure("the single call was retired; SessionsCommand refuses it")
            case .separate:
                shown = context.topicTexts
                intent = Self.intent(context.topics, polish: polish, now: now)
            }
            let (polished, failed) = await CBPolish.run(
                engine: polish, key: key, seed: seed, sample: sample, cache: cache,
                personalContext: persona.personalContext, dictionary: persona.dictionary,
                raw: take.raw, target: target, examples: CBPolish.examples(history, engine: polish), intent: intent
            )

            var update: CBUpdate.Record?
            var change: String?
            if arm == .separate {
                update = await CBUpdate.run(
                    engine: updater, key: key, seed: seed, sample: sample, cache: cache,
                    topics: context.topics, take: polished.text, target: target, now: now
                )
                change = context.record(AutoContext.change(fromTag: update?.tag), app: take.app, now: now)
            }

            steps.append(CBStep(
                session: session.id, take: take.id, arm: arm, sample: sample,
                output: polished.text, seconds: polished.seconds, cleanupFailed: failed,
                topicsShown: shown, tag: update?.tag, change: change,
                topicsAfter: arm == .separate ? context.topicTexts : shown,
                updaterSeconds: update?.seconds,
                updaterReply: update?.reply
            ))
            history.append(RecentDictationExample(raw: take.raw, polished: polished.text, appName: take.app))
        }
        return steps
    }

    /// The topics as the app shows them to this engine's polish.
    static func intent(_ topics: [AutoContext.Topic], polish: CBEngine, now: Date) -> String {
        polish.isApple
            ? AutoContext.onDevicePolishIntent(session: "", topics: topics)
            : AutoContext.polishIntent(session: "", topics: topics, now: now)
    }

    static func target(_ app: String) -> String {
        TargetAppContext(name: app, bundleID: nil, kind: TargetAppContext.kind(bundleID: nil, name: app)).promptLine
    }
}

/// One take through the app's own pipeline and polisher. Cached by everything
/// that goes into the request, so two arms sending the same prompt share one
/// answer and differ only where their inputs do.
enum CBPolish {
    static func run(
        engine: CBEngine, key: String, seed: Int?, sample: Int, cache: CBCache,
        personalContext: String, dictionary: [String],
        raw: String, target: String?, examples: String, intent: String
    ) async -> (CBPolishRecord, Bool) {
        let cacheKey = CBCache.key([
            // Greedy on this Mac, so Apple's samples share one answer.
            "polish", ContextBench.harnessVersion, engine.id,
            engine.isApple ? "-" : seed.map(String.init) ?? "-", engine.isApple ? "0" : String(sample),
            personalContext, dictionary.joined(separator: ","),
            // The empty last part held the single call's block; kept so answers
            // cached before it went are still found.
            raw, target ?? "", examples, intent, "",
        ])
        if let cached = cache.load(cacheKey, as: CBPolishRecord.self) { return (cached, false) }

        let pipeline: PolishPipeline
        switch engine {
        case .openAI(let model):
            var polisher = OpenAIPolisher(apiKey: key, model: model)
            polisher.seed = seed
            pipeline = PolishPipeline(
                localLLM: nil, cloud: polisher, useLocalLLM: false, enableTextCleanup: true, language: .english,
                dictionary: CleanupPrompt.mergedDictionary(dictionary), personalContext: personalContext,
                recentDictations: examples, sessionIntent: intent
            )
        case .apple:
            pipeline = PolishPipeline(
                localLLM: LocalLLMPolisher.shared, cloud: nil, useLocalLLM: true, enableTextCleanup: true, language: .english,
                dictionary: CleanupPrompt.mergedDictionary(dictionary), personalContext: personalContext,
                recentDictations: examples, sessionIntent: intent
            )
        }
        let started = Date()
        let result = await pipeline.runChunked(raw, targetApp: target)
        let record = CBPolishRecord(text: result.text, seconds: Date().timeIntervalSince(started))
        // A failed request is the network's word, not the model's: not cached,
        // so a rerun asks again.
        if !result.cleanupFailed { cache.save(record, key: cacheKey) }
        return (record, result.cleanupFailed)
    }

    /// The earlier takes polish sees as examples, formatted as the app does
    /// for each engine: eight for the cloud, three shorter ones on this Mac.
    static func examples(_ history: [RecentDictationExample], engine: CBEngine) -> String {
        let recent = Array(history.suffix(CBSession.recentWindow).reversed())
        switch engine {
        case .openAI:
            return CleanupPrompt.formatRecentDictations(recent, maxCharsPerSide: CleanupPrompt.cloudRecentMaxCharsPerSide)
        case .apple:
            return CleanupPrompt.formatRecentDictations(
                Array(recent.prefix(CleanupPrompt.onDeviceRecentExampleLimit)),
                maxCharsPerSide: CleanupPrompt.onDeviceRecentMaxCharsPerSide
            )
        }
    }
}

/// Runs work with a bounded number in flight, returning results in input order.
func cbBounded<Input: Sendable, Output: Sendable>(
    _ inputs: [Input], width: Int, _ work: @escaping @Sendable (Input) async -> Output
) async -> [Output] {
    await withTaskGroup(of: (Int, Output).self) { group in
        var results = [Output?](repeating: nil, count: inputs.count)
        var next = 0
        func launch() {
            guard next < inputs.count else { return }
            let index = next
            let input = inputs[index]
            next += 1
            group.addTask { (index, await work(input)) }
        }
        for _ in 0..<max(1, width) { launch() }
        while let (index, output) = await group.next() {
            results[index] = output
            launch()
        }
        return results.compactMap { $0 }
    }
}

enum SessionsCommand {
    static func run(_ options: CBOptions, paths: CBPaths) async throws {
        let file = try CBSessionFile.load(paths.cases)
        let model = options.values["model"] ?? CBDevSettings.model
        let polish = try CBEngine.parse(options.values["polish"], model: model) ?? .openAI(model)
        let updater = try CBEngine.parse(options.values["updater"], model: model) ?? polish
        if (polish.isApple || updater.isApple) && !LocalLLMPolisher.isAvailable {
            throw CBError(LocalLLMPolisher.statusMessage)
        }
        // Only asked for when something runs in the cloud.
        let key = polish.isApple && updater.isApple
            ? "" : try CBKeys.openAI(allowKeychain: options.flags.contains("keychain"))
        let seed = options.values["seed"].flatMap(Int.init)
        // Apple Intelligence polish is greedy: a second sample would repeat the first.
        let samples = options.int("samples", seed == nil && !polish.isApple ? 3 : 1)
        let arms = try (options.values["arms"]?.split(separator: ",").map(String.init) ?? CBArm.runnable.map(\.rawValue))
            .map { name in
                guard let arm = CBArm(rawValue: name) else { throw CBError("unknown arm \(name)") }
                guard CBArm.runnable.contains(arm) else {
                    throw CBError("the \(name) arm was retired: the app no longer asks polish for the context line")
                }
                return arm
            }
        let runner = CBSessionRunner(
            persona: file.persona, key: key, polish: polish, updater: updater, seed: seed,
            cache: CBCache(directory: paths.cache, fresh: options.flags.contains("fresh"))
        )
        let name = options.runName
        let directory = paths.run(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let only = options.values["sessions"].map { Set($0.split(separator: ",").map(String.init)) }
        let sessions = file.sessions.filter { only?.contains($0.id) ?? true }
        guard !sessions.isEmpty else { throw CBError("no session matches --sessions") }
        struct Job: Sendable { let session: CBSession; let arm: CBArm; let sample: Int }
        let jobs = sessions.flatMap { session in
            arms.flatMap { arm in (0..<samples).map { Job(session: session, arm: arm, sample: $0) } }
        }
        let meta = CBRunMeta(polish: polish.label, updater: updater.label, seed: seed, samples: samples)
        print("polish \(polish.label) · update \(updater.label) · seed \(seed.map(String.init) ?? "none") · \(samples) sample(s) · arms \(arms.map(\.rawValue).joined(separator: ", "))")
        print("\(jobs.count) session runs of \(file.sessions.first?.takes.count ?? 0) takes")
        let counter = CBCounter()
        let runs = await cbBounded(jobs, width: options.int("parallel", 6)) { job in
            let steps = await runner.run(job.session, arm: job.arm, sample: job.sample)
            let done = await counter.next()
            print("  \(done)/\(jobs.count)  \(job.session.id) \(job.arm.rawValue) #\(job.sample + 1)")
            return steps
        }
        let steps = runs.flatMap { $0 }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(steps).write(to: directory.appending(path: "steps.json"))
        try encoder.encode(meta).write(to: directory.appending(path: "meta.json"))
        let report = CBReport.sessions(steps, file: file, arms: arms, meta: meta)
        try report.write(to: directory.appending(path: "report.md"), atomically: true, encoding: .utf8)
        print("\n" + report)
        print("wrote \(directory.path)")
    }
}

extension SessionsCommand {
    /// Scores a finished run again from its saved steps: no requests, so a
    /// change to the checks or the report costs nothing to see.
    static func report(_ options: CBOptions, paths: CBPaths) throws {
        guard let name = options.values["name"] else { throw CBError("report needs --name <run>") }
        let file = try CBSessionFile.load(paths.cases)
        let directory = paths.run(name)
        let steps = try JSONDecoder().decode([CBStep].self, from: Data(contentsOf: directory.appending(path: "steps.json")))
        let arms = CBArm.allCases.filter { arm in steps.contains { $0.arm == arm } }
        // Runs from before meta.json were all one OpenAI model.
        let model = options.values["model"] ?? CBDevSettings.model
        let meta = (try? JSONDecoder().decode(CBRunMeta.self, from: Data(contentsOf: directory.appending(path: "meta.json"))))
            ?? CBRunMeta(polish: model, updater: model, seed: options.values["seed"].flatMap(Int.init),
                         samples: (steps.map(\.sample).max() ?? 0) + 1)
        let report = CBReport.sessions(steps, file: file, arms: arms, meta: meta)
        try report.write(to: directory.appending(path: "report.md"), atomically: true, encoding: .utf8)
        print(report)
    }
}

/// What a run was, for rebuilding its report later.
struct CBRunMeta: Codable {
    let polish: String
    let updater: String
    let seed: Int?
    let samples: Int
}

actor CBCounter {
    private var value = 0
    func next() -> Int { value += 1; return value }
}

/// `seed-check`: whether the model gives the same answer twice when asked to.
/// Without it, half of a run's differences are the model's own variation.
enum SeedCheck {
    static func run(_ options: CBOptions, paths: CBPaths) async throws {
        let file = try CBSessionFile.load(paths.cases)
        let key = try CBKeys.openAI(allowKeychain: options.flags.contains("keychain"))
        let model = options.values["model"] ?? CBDevSettings.model
        let seed = options.values["seed"].flatMap(Int.init) ?? 7
        let takes = file.sessions.prefix(6).map { ($0, $0.takes[10]) }
        print("model \(model): six takes, three requests each, with and without seed \(seed)")
        var repeatable = (with: 0, without: 0)
        for (session, take) in takes {
            for useSeed in [true, false] {
                var outputs = Set<String>()
                for _ in 0..<3 {
                    var polisher = OpenAIPolisher(apiKey: key, model: model)
                    polisher.seed = useSeed ? seed : nil
                    let pipeline = PolishPipeline(
                        localLLM: nil, cloud: polisher, useLocalLLM: false, enableTextCleanup: true,
                        language: .english, dictionary: file.persona.dictionary,
                        personalContext: file.persona.personalContext
                    )
                    outputs.insert(await pipeline.runChunked(take.raw, targetApp: CBSessionRunner.target(take.app)).text)
                }
                if outputs.count == 1 {
                    if useSeed { repeatable.with += 1 } else { repeatable.without += 1 }
                }
                print("  \(session.id) \(useSeed ? "seed   " : "no seed"): \(outputs.count) different answer(s) of 3")
            }
        }
        print("repeatable: \(repeatable.with) of \(takes.count) with the seed, \(repeatable.without) of \(takes.count) without")
    }
}
