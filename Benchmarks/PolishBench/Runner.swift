import Foundation

/// What one engine pasted for one case, and what it took to get there.
struct TakeOutput: Codable, Sendable {
    let caseID: String
    let engine: String
    let repeatIndex: Int
    let fingerprint: String
    let text: String
    let stages: [String]
    /// The model was asked and could not deliver; the app would have pasted this
    /// text without cleanup.
    let cleanupFailed: Bool
    let note: String?
    /// Wall time for the whole take, every piece of a long one included.
    let seconds: Double
    let calls: [CallRecord]
    let date: Date
    let transient: Bool
}

struct Runner {
    let cases: [BenchCase]
    let engines: [Engine]
    let repeats: Int
    let keys: APIKeys
    let cacheDir: URL
    let fresh: Bool
    let parallel: Int

    /// Each cloud engine runs in its own lane, a few requests at a time. The
    /// on-device engines share one lane and run strictly one take at a time:
    /// Apple Intelligence and Gemma share the chip, so running them together
    /// would slow both and make their wait times meaningless.
    func run() async -> [TakeOutput] {
        let cloud = engines.filter(\.isCloud)
        let onDevice = engines.filter { !$0.isCloud }
        return await withTaskGroup(of: [TakeOutput].self) { group in
            for engine in cloud {
                group.addTask { await self.runLane(engine, width: self.parallel) }
            }
            if !onDevice.isEmpty {
                group.addTask {
                    var all: [TakeOutput] = []
                    for engine in onDevice {
                        all += await self.runLane(engine, width: 1)
                    }
                    return all
                }
            }
            var all: [TakeOutput] = []
            for await chunk in group { all += chunk }
            return all
        }
    }

    private func jobs(for engine: Engine) -> [(BenchCase, Int)] {
        let count = engine.runsOnce ? 1 : repeats
        return cases.flatMap { item in (0..<count).map { (item, $0) } }
    }

    private func runLane(_ engine: Engine, width: Int) async -> [TakeOutput] {
        let jobs = jobs(for: engine)
        if jobs.contains(where: { cached(engine, $0.0, $0.1) == nil }) {
            await warmUp(engine)
        }
        var results: [TakeOutput] = []
        await withTaskGroup(of: TakeOutput.self) { group in
            var pending = jobs.makeIterator()
            for _ in 0..<width {
                guard let job = pending.next() else { break }
                group.addTask { await self.take(engine, job.0, job.1) }
            }
            while let result = await group.next() {
                results.append(result)
                if let job = pending.next() {
                    group.addTask { await self.take(engine, job.0, job.1) }
                }
            }
        }
        return results
    }

    /// The app loads its on-device model and keeps it warm between takes; the
    /// first take here should not pay a cold start the app never shows.
    private func warmUp(_ engine: Engine) async {
        switch engine.kind {
        case .apple:
            Progress.note("warming Apple Intelligence…")
            _ = try? await LocalLLMPolisher.shared.polish("okay thanks", dictionary: [])
        case .gemma:
            Progress.note("loading Gemma 4 E2B…")
            _ = try? await GemmaMLXPolisher.shared.polish("okay thanks", dictionary: [])
        default:
            break
        }
    }

    private func cacheFile(_ engine: Engine, _ item: BenchCase, _ index: Int, fingerprint: String) -> URL {
        cacheDir
            .appendingPathComponent(engine.id)
            .appendingPathComponent("\(item.id).\(fingerprint).r\(index).json")
    }

    private func cached(_ engine: Engine, _ item: BenchCase, _ index: Int) -> TakeOutput? {
        guard !fresh else { return nil }
        let setup = EngineSetup(engine: engine, keys: keys)
        let file = cacheFile(engine, item, index, fingerprint: setup.fingerprint(for: item))
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONCoding.decoder.decode(TakeOutput.self, from: data)
    }

    private func take(_ engine: Engine, _ item: BenchCase, _ index: Int) async -> TakeOutput {
        if let hit = cached(engine, item, index) { return hit }

        let setup = EngineSetup(engine: engine, keys: keys)
        let fingerprint = setup.fingerprint(for: item)
        let log = CallLog()
        let pipeline = setup.pipeline(for: item, log: log)
        let clock = ContinuousClock()
        let start = clock.now
        // The app's own entry points: a dictation goes through the splitter, a
        // session-context take does not.
        let result = item.polishTask == .sessionContext
            ? await pipeline.run(item.raw, targetApp: nil)
            : await pipeline.runChunked(item.raw, targetApp: item.app)
        let seconds = (clock.now - start).seconds
        let calls = log.all
        let output = TakeOutput(
            caseID: item.id,
            engine: engine.id,
            repeatIndex: index,
            fingerprint: fingerprint,
            text: result.text,
            stages: result.stages,
            cleanupFailed: result.cleanupFailed,
            note: result.cleanupNote,
            seconds: seconds,
            calls: calls,
            date: Date(),
            transient: calls.contains(where: \.transient)
        )

        // Only successful takes are kept. A failure costs nothing to repeat, and
        // caching one hides the fix when the reason for it is fixed.
        if !output.transient, !output.cleanupFailed, output.calls.allSatisfy({ $0.error == nil }) {
            let file = cacheFile(engine, item, index, fingerprint: fingerprint)
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONCoding.encoder.encode(output).write(to: file, options: .atomic)
        }

        let status: String
        if let error = calls.compactMap(\.error).first {
            status = "FAILED \(error.prefix(120))"
        } else {
            status = "ok"
        }
        Progress.note(String(format: "  %-22@ %-26@ r%d %6.2fs  %@", engine.id as NSString, item.id as NSString, index + 1, seconds, status as NSString))
        return output
    }
}

enum JSONCoding {
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// A run's folder: the cases it used, every output, and the judges' verdicts.
/// Running again under the same name adds to it rather than starting over, so
/// engines can be added one at a time.
struct RunStore {
    let directory: URL

    private var outputsFile: URL { directory.appendingPathComponent("outputs.json") }
    private var casesFile: URL { directory.appendingPathComponent("cases.json") }
    private var verdictsFile: URL { directory.appendingPathComponent("verdicts.json") }

    func merge(outputs: [TakeOutput], cases: [BenchCase]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var byKey: [String: TakeOutput] = [:]
        for output in (try? loadOutputs()) ?? [] { byKey[key(output)] = output }
        for output in outputs { byKey[key(output)] = output }
        let merged = byKey.values.sorted { ($0.engine, $0.caseID, $0.repeatIndex) < ($1.engine, $1.caseID, $1.repeatIndex) }
        try JSONCoding.encoder.encode(merged).write(to: outputsFile, options: .atomic)

        var caseByID: [String: BenchCase] = [:]
        for item in (try? loadCases()) ?? [] { caseByID[item.id] = item }
        for item in cases { caseByID[item.id] = item }
        let allCases = caseByID.values.sorted { $0.id < $1.id }
        try JSONCoding.encoder.encode(CaseSet(cases: allCases)).write(to: casesFile, options: .atomic)
    }

    func loadOutputs() throws -> [TakeOutput] {
        try JSONCoding.decoder.decode([TakeOutput].self, from: Data(contentsOf: outputsFile))
    }

    func loadCases() throws -> [BenchCase] {
        try JSONCoding.decoder.decode(CaseSet.self, from: Data(contentsOf: casesFile)).cases
    }

    func loadVerdicts() -> [Verdict] {
        guard let data = try? Data(contentsOf: verdictsFile) else { return [] }
        return (try? JSONCoding.decoder.decode([Verdict].self, from: data)) ?? []
    }

    func saveVerdicts(_ verdicts: [Verdict]) throws {
        var byKey: [String: Verdict] = [:]
        for verdict in loadVerdicts() { byKey[verdict.key] = verdict }
        for verdict in verdicts { byKey[verdict.key] = verdict }
        let merged = byKey.values.sorted { $0.key < $1.key }
        try JSONCoding.encoder.encode(merged).write(to: verdictsFile, options: .atomic)
    }

    private func key(_ output: TakeOutput) -> String {
        "\(output.engine)|\(output.caseID)|\(output.repeatIndex)"
    }
}
