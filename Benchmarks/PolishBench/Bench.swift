import Foundation

struct BenchError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Command-line entry. Everything runs from the repository root.
@MainActor
enum Bench {
    /// Bump when the harness changes how a take is run, so cached outputs from the
    /// old behaviour are not mixed with new ones.
    nonisolated static let harnessVersion = "1"

    nonisolated static let usage = """
    usage: polish-bench <command> [options]

    commands
      run      Polish every case with every engine and score it with the code checks.
      judge    Compare each engine with the anchor, using judge models.
      report   Rebuild the summary from a run's outputs and verdicts.
      prompt   Print what an engine is sent for one case.
      validate Check the case file against itself before spending money on it.
      engines  List engine names.

    run options
      --engines   raw,fillers,apple,gemma,<model id>… or all / local / cloud / openai / anthropic
      --cases     path to a case file (default Benchmarks/cases/transcripts.json)
      --pilot     only the cases marked for the pilot
      --half      tune | test
      --category  comma-separated categories
      --only      comma-separated case ids
      --repeats   runs per cloud case (default 1; on-device engines always run once)
      --parallel  requests in flight per cloud engine (default 3)
      --name      run name (default: today's date)
      --fresh     ignore cached outputs
      --keychain  read API keys saved by WhisperLocal when they are not in the environment

    judge options
      --name      run to judge
      --judges     judge model ids (default claude-opus-5,gpt-5.6-sol)
      --anchor     engine every candidate is compared with (default gpt-4o-mini)
      --candidates engines to judge (default: every engine in the run)
      --half / --category / --only  judge a subset of the cases
      --keychain  as above

    API keys come from OPENAI_API_KEY and ANTHROPIC_API_KEY.
    """

    static func main(_ arguments: [String]) async throws {
        let options = try Options(arguments)
        let paths = Paths(root: URL(fileURLWithPath: options.values["root"] ?? FileManager.default.currentDirectoryPath))
        switch options.command {
        case "run": try await runCommand(options, paths: paths)
        case "judge": try await judgeCommand(options, paths: paths)
        case "report": try reportCommand(options, paths: paths)
        case "prompt": try promptCommand(options, paths: paths)
        case "probe": try await probeCommand(options, paths: paths)
        case "validate": try validateCommand(options, paths: paths)
        case "engines": print(Engine.list("all").map(\.id).joined(separator: "\n"))
        case "help", "-h", "--help": print(usage)
        default: throw BenchError("unknown command \(options.command)\n\n\(usage)")
        }
    }

    // MARK: - Commands

    private static func runCommand(_ options: Options, paths: Paths) async throws {
        let cases = try selectCases(options, paths: paths)
        guard !cases.isEmpty else { throw BenchError("no cases matched") }
        let keys = APIKeys.load(allowKeychain: options.flags.contains("keychain"))
        var engines = Engine.list(options.values["engines"] ?? "raw,fillers,apple")
        engines = engines.filter { engine in
            guard let provider = engine.provider else { return true }
            if keys.key(for: provider) == nil {
                Progress.note("skipping \(engine.id): no \(provider.rawValue) key (set \(provider.envName), or pass --keychain)")
                return false
            }
            return true
        }
        guard !engines.isEmpty else { throw BenchError("no engine can run") }
        for provider in Provider.allCases {
            if let source = keys.sources[provider] { Progress.note("\(provider.rawValue) key: from \(source)") }
        }

        let name = options.values["name"] ?? Self.today()
        let repeats = max(1, Int(options.values["repeats"] ?? "1") ?? 1)
        let runner = Runner(
            cases: cases,
            engines: engines,
            repeats: repeats,
            keys: keys,
            cacheDir: paths.cache,
            fresh: options.flags.contains("fresh"),
            parallel: max(1, Int(options.values["parallel"] ?? "3") ?? 3)
        )
        Progress.note("\(cases.count) cases × \(engines.count) engines, \(repeats) repeat(s) per cloud case → run \(name)")
        let outputs = await runner.run()

        let store = RunStore(directory: paths.run(name))
        try store.merge(outputs: outputs, cases: cases)
        let report = try Report.build(store: store, prices: Prices.load(paths.prices))
        try report.write(to: store.directory)
        print(report.table())
        print("\nSaved to \(store.directory.path)")
    }

    private static func judgeCommand(_ options: Options, paths: Paths) async throws {
        guard let name = options.values["name"] else { throw BenchError("judge needs --name <run>") }
        let store = RunStore(directory: paths.run(name))
        let keys = APIKeys.load(allowKeychain: options.flags.contains("keychain"))
        let judges = (options.values["judges"] ?? "claude-opus-5,gpt-5.6-sol")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let anchor = options.values["anchor"] ?? "gpt-4o-mini"
        let judge = Judge(
            keys: keys,
            judges: judges,
            anchor: anchor,
            candidates: options.list("candidates"),
            onlyCases: try judgedCases(options, store: store),
            cacheDir: paths.judgeCache,
            parallel: max(1, Int(options.values["parallel"] ?? "4") ?? 4)
        )
        let verdicts = try await judge.run(store: store)
        try store.saveVerdicts(verdicts)
        let report = try Report.build(store: store, prices: Prices.load(paths.prices))
        try report.write(to: store.directory)
        print(report.table())
    }

    /// Which cases to judge, when only some of them are worth paying for.
    private static func judgedCases(_ options: Options, store: RunStore) throws -> Set<String>? {
        let filters = ["half", "category", "only"]
        guard filters.contains(where: { options.values[$0] != nil }) else { return nil }
        var cases = try store.loadCases()
        if let half = options.values["half"] { cases = cases.filter { $0.half == half } }
        if let categories = options.list("category") { cases = cases.filter { categories.contains($0.category) } }
        if let ids = options.list("only") { cases = cases.filter { ids.contains($0.id) } }
        return Set(cases.map(\.id))
    }

    private static func reportCommand(_ options: Options, paths: Paths) throws {
        guard let name = options.values["name"] else { throw BenchError("report needs --name <run>") }
        let store = RunStore(directory: paths.run(name))
        let report = try Report.build(store: store, prices: Prices.load(paths.prices))
        try report.write(to: store.directory)
        print(report.table())
        if options.flags.contains("failures") { print(report.failureList()) }
    }

    private static func promptCommand(_ options: Options, paths: Paths) throws {
        let cases = try selectCases(options, paths: paths)
        guard let first = cases.first else { throw BenchError("no case matched") }
        let engine = Engine.named(options.values["engines"] ?? "gpt-4o-mini")
        let sent = EngineSetup(engine: engine, keys: APIKeys()).promptParts(for: first)
        print("== \(engine.id) · \(first.id) ==\n")
        print(sent.joined(separator: "\n\n----\n\n"))
    }

    /// One request, printed as the provider answered it: stop reason, token counts,
    /// and the start of the text. For working out why a model failed.
    private static func probeCommand(_ options: Options, paths: Paths) async throws {
        let cases = try selectCases(options, paths: paths)
        guard let item = cases.first else { throw BenchError("no case matched") }
        let model = options.values["engines"] ?? "claude-sonnet-5"
        let keys = APIKeys.load(allowKeychain: options.flags.contains("keychain"))
        let engine = Engine.named(model)
        let parts = EngineSetup(engine: engine, keys: keys).promptParts(for: item)
        guard parts.count == 2 else { throw BenchError("\(model) builds no prompt") }
        // The piece the app would actually send, when the take is long enough to split.
        let pieces = PolishChunker.split(VocalFillerFilter.strip(item.raw))
        let piece = Int(options.values["piece"] ?? "1").map { max(1, $0) - 1 } ?? 0
        let text = pieces[min(piece, pieces.count - 1)]
        let maxTokens = Int(options.values["max-tokens"] ?? "") ?? PolishOutput.maxOutputTokens(for: text)
        Progress.note("\(model) · \(item.id) piece \(piece + 1)/\(pieces.count) · \(text.count) characters · max_tokens \(maxTokens)")
        // Exactly what the app sends for this piece, position note included.
        let part = pieces.count > 1
            ? CleanupPrompt.TranscriptPart(index: piece + 1, total: pieces.count)
            : nil
        let raw = try await ChatClient(keys: keys).raw(
            model: model,
            system: parts[0],
            user: CleanupPrompt.userMessage(
                for: item.polishTask,
                text: text,
                targetApp: item.app,
                part: part,
                language: item.spokenLanguage
            ),
            maxTokens: maxTokens,
            thinking: options.values["thinking"]
        )
        print(raw)
    }

    /// Scores every answer key against its own case. A rule its own answer breaks
    /// is a broken rule, and would count as a failure against every model.
    private static func validateCommand(_ options: Options, paths: Paths) throws {
        let cases = try selectCases(options, paths: paths)
        var broken = 0
        var unchanged = 0
        for item in cases {
            let asOutput = TakeOutput(
                caseID: item.id, engine: "reference", repeatIndex: 0, fingerprint: "",
                text: item.reference, stages: [], cleanupFailed: false, note: nil,
                seconds: 0, calls: [], date: Date(), transient: false
            )
            let failures = HardChecks.run(asOutput, item)
            if !failures.isEmpty {
                broken += 1
                print("\(item.id): " + failures.map { "\($0.code) — \($0.detail)" }.joined(separator: "; "))
            }
            if Normalize.text(item.raw) == Normalize.text(item.reference), item.checks?.verbatim != true {
                unchanged += 1
                print("\(item.id): answer key is identical to the raw text but is not marked verbatim")
            }
        }
        var byCategory: [String: Int] = [:]
        var halves: [String: Int] = [:]
        var pieces = 0
        for item in cases {
            byCategory[item.category, default: 0] += 1
            halves[item.half, default: 0] += 1
            if PolishChunker.split(VocalFillerFilter.strip(item.raw)).count > 1 { pieces += 1 }
        }
        print("\n\(cases.count) cases · " + byCategory.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        print("halves: tune \(halves["tune"] ?? 0), test \(halves["test"] ?? 0) · \(pieces) split into pieces")
        print(broken == 0 ? "every answer key passes its own rules" : "\(broken) cases have rules their own answer key breaks")
    }

    private static func selectCases(_ options: Options, paths: Paths) throws -> [BenchCase] {
        let file = options.values["cases"].map { URL(fileURLWithPath: $0) } ?? paths.defaultCases
        var cases = try CaseSet.load(file)
        if options.flags.contains("pilot") { cases = cases.filter { $0.pilot == true } }
        if let half = options.values["half"] { cases = cases.filter { $0.half == half } }
        if let categories = options.list("category") { cases = cases.filter { categories.contains($0.category) } }
        if let ids = options.list("only") { cases = cases.filter { ids.contains($0.id) } }
        return cases
    }

    private static func today() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}

struct Options {
    let command: String
    var values: [String: String] = [:]
    var flags: Set<String> = []

    init(_ arguments: [String]) throws {
        guard let first = arguments.first else { throw BenchError(Bench.usage) }
        command = first
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            guard argument.hasPrefix("--") else { throw BenchError("unexpected argument \(argument)") }
            let key = String(argument.dropFirst(2))
            if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
                values[key] = arguments[index + 1]
                index += 2
            } else {
                flags.insert(key)
                index += 1
            }
        }
    }

    func list(_ key: String) -> [String]? {
        values[key]?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

struct Paths {
    let root: URL
    var benchmarks: URL { root.appendingPathComponent("Benchmarks") }
    var defaultCases: URL { benchmarks.appendingPathComponent("cases/transcripts.json") }
    var prices: URL { benchmarks.appendingPathComponent("prices.json") }
    /// Git-ignored: outputs contain whatever the cases contain, and cost money to make.
    var results: URL { benchmarks.appendingPathComponent("results") }
    var cache: URL { results.appendingPathComponent("cache") }
    var judgeCache: URL { results.appendingPathComponent("judge-cache") }
    func run(_ name: String) -> URL { results.appendingPathComponent("runs").appendingPathComponent(name) }
}

/// Progress goes to stderr so a report can be piped on its own.
enum Progress {
    private static let lock = NSLock()

    static func note(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        FileHandle.standardError.write(Data("\(line)\n".utf8))
    }
}

extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
