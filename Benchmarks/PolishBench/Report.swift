import Foundation

/// Published list prices, USD per million tokens. Kept in a file with the date
/// they were checked, because they change more often than the code does.
struct Prices: Codable {
    struct Rate: Codable {
        let input: Double
        var cachedInput: Double?
        var cacheWrite: Double?
        let output: Double
    }

    var checked: String?
    var models: [String: Rate]

    static func load(_ url: URL) -> Prices {
        guard let data = try? Data(contentsOf: url),
              let prices = try? JSONDecoder().decode(Prices.self, from: data)
        else { return Prices(checked: nil, models: [:]) }
        return prices
    }

    func dollars(_ usage: PolishUsage, model: String) -> Double? {
        guard let rate = models[model] else { return nil }
        let uncached = max(0, usage.inputTokens - usage.cachedInputTokens - usage.cacheWriteTokens)
        let total = Double(uncached) * rate.input
            + Double(usage.cachedInputTokens) * (rate.cachedInput ?? rate.input)
            + Double(usage.cacheWriteTokens) * (rate.cacheWrite ?? rate.input)
            + Double(usage.outputTokens) * rate.output
        return total / 1_000_000
    }
}

struct Report: Codable {
    struct Row: Codable {
        let engine: String
        let takes: Int
        let cases: Int
        /// The model call failed and the app would have pasted uncleaned text.
        let errors: Int
        /// Takes, among those that got an answer, with at least one hard failure.
        let failedTakes: Int
        let failures: [String: Int]
        let exact: Double
        let editRate: Double
        let editRange: [Double]
        /// Share of head-to-heads won against the anchor, ties counting half.
        let winRate: Double?
        let winRange: [Double]?
        let perJudge: [String: Double]
        let medianSeconds: Double
        let slowSeconds: Double
        let inputTokens: Double
        let outputTokens: Double
        let reasoningTokens: Double
        let cachedShare: Double
        let dollarsPer1000: Double?
    }

    struct Cell: Codable {
        let takes: Int
        let failed: Int
        let editRate: Double
    }

    struct FailedTake: Codable {
        let engine: String
        let caseID: String
        let repeatIndex: Int
        let failures: [Failure]
        let error: String?
        let output: String
    }

    let generated: Date
    let caseCount: Int
    let anchor: String?
    let judges: [String]
    let judgeAgreement: Double?
    let judgeDollars: Double?
    let pricesChecked: String?
    let rows: [Row]
    let categories: [String: [String: Cell]]
    let failedTakes: [FailedTake]

    // MARK: - Build

    static func build(store: RunStore, prices: Prices) throws -> Report {
        let outputs = try store.loadOutputs()
        let cases = Dictionary(try store.loadCases().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let verdicts = store.loadVerdicts()
        let anchor = verdicts.first?.anchor
        let judges = Array(Set(verdicts.map(\.judge))).sorted()

        var rows: [Row] = []
        var categories: [String: [String: Cell]] = [:]
        var failedTakes: [FailedTake] = []

        for (engine, takes) in Dictionary(grouping: outputs, by: \.engine) {
            let scored = takes.compactMap { take in cases[take.caseID].map { (take, $0) } }
            guard !scored.isEmpty else { continue }

            var failureCounts: [String: Int] = [:]
            var failedCount = 0
            var editByCase: [String: [Double]] = [:]
            var exactCount = 0
            var categoryTakes: [String: (takes: Int, failed: Int, edits: [Double])] = [:]

            for (take, item) in scored {
                let edit = TextDistance.editRate(take.text, reference: item.reference, byCharacter: item.scoresByCharacter)
                editByCase[item.id, default: []].append(edit)
                if Normalize.text(take.text) == Normalize.text(item.reference) { exactCount += 1 }

                var cell = categoryTakes[item.category] ?? (0, 0, [])
                cell.takes += 1
                cell.edits.append(edit)

                let failures = take.cleanupFailed ? [] : HardChecks.run(take, item)
                if !failures.isEmpty {
                    failedCount += 1
                    cell.failed += 1
                    for code in Set(failures.map(\.code)) { failureCounts[code, default: 0] += 1 }
                }
                if !failures.isEmpty || take.cleanupFailed {
                    failedTakes.append(FailedTake(
                        engine: engine,
                        caseID: item.id,
                        repeatIndex: take.repeatIndex,
                        failures: failures,
                        error: take.cleanupFailed ? (take.calls.compactMap(\.error).first ?? take.note) : nil,
                        output: take.text
                    ))
                }
                categoryTakes[item.category] = cell
            }

            let perCaseEdit = editByCase.values.map { $0.reduce(0, +) / Double($0.count) }
            let editRange = Stats.bootstrap(perCaseEdit)

            // Head to head: per case, average the two orders and both judges.
            let mine = verdicts.filter { $0.candidate == engine }
            var perJudge: [String: Double] = [:]
            var caseScores: [String: [Double]] = [:]
            for judge in judges {
                var byCase: [String: [Double]] = [:]
                for verdict in mine where verdict.judge == judge {
                    if let score = verdict.score { byCase[verdict.caseID, default: []].append(score) }
                }
                let scores = byCase.values.map { $0.reduce(0, +) / Double($0.count) }
                if !scores.isEmpty {
                    perJudge[judge] = scores.map { ($0 + 1) / 2 }.reduce(0, +) / Double(scores.count)
                }
                for (id, values) in byCase {
                    caseScores[id, default: []].append(values.reduce(0, +) / Double(values.count))
                }
            }
            let combined = caseScores.values.map { (($0.reduce(0, +) / Double($0.count)) + 1) / 2 }
            let winRate = combined.isEmpty ? nil : combined.reduce(0, +) / Double(combined.count)
            let winRange = combined.isEmpty ? nil : Stats.bootstrap(combined)

            // Cost of use: only takes that actually called a model.
            let seconds = takes.map(\.seconds)
            let usages = takes.map { take in take.calls.compactMap(\.usage) }
            let totals = usages.map { list in
                list.reduce(PolishUsage(inputTokens: 0, outputTokens: 0)) { sum, usage in
                    PolishUsage(
                        inputTokens: sum.inputTokens + usage.inputTokens,
                        outputTokens: sum.outputTokens + usage.outputTokens,
                        cachedInputTokens: sum.cachedInputTokens + usage.cachedInputTokens,
                        cacheWriteTokens: sum.cacheWriteTokens + usage.cacheWriteTokens,
                        reasoningTokens: sum.reasoningTokens + usage.reasoningTokens
                    )
                }
            }
            let billed = totals.filter { $0.inputTokens > 0 }
            let count = Double(max(billed.count, 1))
            let input = Double(billed.map(\.inputTokens).reduce(0, +))
            let dollars: Double? = {
                guard !billed.isEmpty else { return nil }
                let each = billed.compactMap { prices.dollars($0, model: engine) }
                guard each.count == billed.count else { return nil }
                return each.reduce(0, +) / count * 1000
            }()

            rows.append(Row(
                engine: engine,
                takes: takes.count,
                cases: editByCase.count,
                errors: takes.filter(\.cleanupFailed).count,
                failedTakes: failedCount,
                failures: failureCounts,
                exact: Double(exactCount) / Double(scored.count),
                editRate: perCaseEdit.reduce(0, +) / Double(perCaseEdit.count),
                editRange: [editRange.low, editRange.high],
                winRate: winRate,
                winRange: winRange.map { [$0.low, $0.high] },
                perJudge: perJudge,
                medianSeconds: Stats.percentile(seconds, 0.5),
                slowSeconds: Stats.percentile(seconds, 0.95),
                inputTokens: input / count,
                outputTokens: Double(billed.map(\.outputTokens).reduce(0, +)) / count,
                reasoningTokens: Double(billed.map(\.reasoningTokens).reduce(0, +)) / count,
                cachedShare: input > 0 ? Double(billed.map(\.cachedInputTokens).reduce(0, +)) / input : 0,
                dollarsPer1000: dollars
            ))
            categories[engine] = categoryTakes.mapValues { cell in
                Cell(takes: cell.takes, failed: cell.failed, editRate: cell.edits.reduce(0, +) / Double(max(cell.edits.count, 1)))
            }
        }

        rows.sort { a, b in
            switch (a.winRate, b.winRate) {
            case let (x?, y?) where x != y: return x > y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.editRate < b.editRate
            }
        }

        let judgeDollars: Double? = verdicts.isEmpty ? nil : verdicts.reduce(0.0) { sum, verdict in
            sum + (verdict.usage.flatMap { prices.dollars($0, model: verdict.judge) } ?? 0)
        }

        return Report(
            generated: Date(),
            caseCount: cases.count,
            anchor: anchor,
            judges: judges,
            judgeAgreement: agreement(verdicts, judges: judges),
            judgeDollars: judgeDollars,
            pricesChecked: prices.checked,
            rows: rows,
            categories: categories,
            failedTakes: failedTakes.sorted { ($0.engine, $0.caseID, $0.repeatIndex) < ($1.engine, $1.caseID, $1.repeatIndex) }
        )
    }

    /// How often the two judges pick the same side of a pair, ties included.
    private static func agreement(_ verdicts: [Verdict], judges: [String]) -> Double? {
        guard judges.count == 2 else { return nil }
        var sides: [String: [String: Double]] = [:]
        for (key, group) in Dictionary(grouping: verdicts, by: { "\($0.candidate)|\($0.caseID)|\($0.judge)" }) {
            let scores = group.compactMap(\.score)
            guard !scores.isEmpty, let judge = group.first?.judge else { continue }
            let pair = String(key.split(separator: "|").prefix(2).joined(separator: "|"))
            sides[pair, default: [:]][judge] = scores.reduce(0, +) / Double(scores.count)
        }
        let both = sides.values.filter { $0.count == 2 }
        guard !both.isEmpty else { return nil }
        let same = both.filter { pair in
            let values = Array(pair.values)
            return sign(values[0]) == sign(values[1])
        }
        return Double(same.count) / Double(both.count)
    }

    private static func sign(_ value: Double) -> Int {
        value > 0.001 ? 1 : (value < -0.001 ? -1 : 0)
    }

    // MARK: - Output

    func write(to directory: URL) throws {
        try JSONCoding.encoder.encode(self).write(to: directory.appendingPathComponent("report.json"), options: .atomic)
        try (table() + "\n\n" + failureList()).write(
            to: directory.appendingPathComponent("report.md"), atomically: true, encoding: .utf8
        )
    }

    func table() -> String {
        var lines: [String] = []
        lines.append("\(caseCount) cases" + (anchor.map { " · judged against \($0) by \(judges.joined(separator: " + "))" } ?? ""))
        if let judgeAgreement { lines.append(String(format: "Judges agree on %.0f%% of pairs", judgeAgreement * 100)) }
        if let judgeDollars { lines.append(String(format: "Judging cost $%.2f", judgeDollars)) }
        lines.append("")
        lines.append(pad("engine", 24) + pad("takes", 6, right: true) + pad("err", 5, right: true)
            + pad("hard fail", 11, right: true) + pad("exact", 7, right: true)
            + pad("edit rate (95%)", 22, right: true) + pad("vs anchor (95%)", 22, right: true)
            + pad("p50 s", 8, right: true) + pad("p95 s", 8, right: true)
            + pad("in/out tok", 12, right: true) + pad("$/1k", 8, right: true))
        for row in rows {
            let failedShare = Double(row.failedTakes) / Double(max(row.takes - row.errors, 1))
            let edit = String(format: "%.3f [%.3f–%.3f]", row.editRate, row.editRange[0], row.editRange[1])
            let win = row.winRate.map { rate in
                String(format: "%.0f%% [%.0f–%.0f]", rate * 100, (row.winRange?[0] ?? 0) * 100, (row.winRange?[1] ?? 0) * 100)
            } ?? "—"
            let tokens = row.inputTokens > 0 ? String(format: "%.0f/%.0f", row.inputTokens, row.outputTokens) : "—"
            let dollars = row.dollarsPer1000.map { String(format: "%.2f", $0) } ?? "—"
            lines.append(pad(row.engine, 24) + pad("\(row.takes)", 6, right: true) + pad("\(row.errors)", 5, right: true)
                + pad(String(format: "%d (%.0f%%)", row.failedTakes, failedShare * 100), 11, right: true)
                + pad(String(format: "%.0f%%", row.exact * 100), 7, right: true)
                + pad(edit, 22, right: true) + pad(win, 22, right: true)
                + pad(String(format: "%.2f", row.medianSeconds), 8, right: true)
                + pad(String(format: "%.2f", row.slowSeconds), 8, right: true)
                + pad(tokens, 12, right: true) + pad(dollars, 8, right: true))
        }
        lines.append("")
        lines.append("Hard failures by kind")
        for row in rows where row.failedTakes > 0 {
            let parts = HardChecks.kinds.compactMap { kind in
                row.failures[kind.code].map { "\(kind.label) \($0)" }
            }
            lines.append("  " + pad(row.engine, 22) + parts.joined(separator: " · "))
        }
        return lines.joined(separator: "\n")
    }

    func failureList() -> String {
        var lines = ["Failed takes"]
        for take in failedTakes {
            let what = take.error.map { "error: \($0)" }
                ?? take.failures.map { "\($0.code): \($0.detail)" }.joined(separator: "; ")
            lines.append("- \(take.engine) · \(take.caseID) r\(take.repeatIndex + 1) — \(what)")
            lines.append("    \(take.output.replacingOccurrences(of: "\n", with: " ⏎ ").prefix(240))")
        }
        return lines.joined(separator: "\n")
    }

    private func pad(_ text: String, _ width: Int, right: Bool = false) -> String {
        let count = text.count
        guard count < width else { return text + " " }
        let space = String(repeating: " ", count: width - count)
        return right ? space + text : text + space
    }
}

enum Stats {
    /// 95% range of the mean by resampling cases. Seeded, so a report rebuilt
    /// from the same outputs prints the same range.
    static func bootstrap(_ values: [Double], iterations: Int = 2000) -> (low: Double, high: Double) {
        guard values.count > 1 else {
            let only = values.first ?? 0
            return (only, only)
        }
        var generator = SplitMix(seed: 42)
        var means: [Double] = []
        means.reserveCapacity(iterations)
        for _ in 0..<iterations {
            var sum = 0.0
            for _ in values.indices {
                sum += values[Int(generator.next() % UInt64(values.count))]
            }
            means.append(sum / Double(values.count))
        }
        means.sort()
        return (means[Int(Double(iterations) * 0.025)], means[Int(Double(iterations) * 0.975) - 1])
    }

    static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * fraction).rounded())))
        return sorted[index]
    }
}

struct SplitMix {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
