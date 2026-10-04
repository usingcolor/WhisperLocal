import Foundation

enum CBReport {
    private struct Scored {
        let step: CBStep
        let take: CBTake
        let session: CBSession
        let index: Int
        let score: CBScore
    }

    static func sessions(_ steps: [CBStep], file: CBSessionFile, arms: [CBArm], meta: CBRunMeta) -> String {
        var lookup: [String: (CBSession, Int)] = [:]
        for session in file.sessions {
            for (index, take) in session.takes.enumerated() { lookup[take.id] = (session, index) }
        }
        let scored: [Scored] = steps.compactMap { step in
            guard let (session, index) = lookup[step.take] else { return nil }
            let take = session.takes[index]
            return Scored(step: step, take: take, session: session, index: index,
                          score: CBChecks.score(take, output: step.output, dictionary: file.persona.dictionary))
        }
        let byArm = Dictionary(grouping: scored, by: \.step.arm)
        let sessionIDs = file.sessions.map(\.id)

        func probes(_ rows: [Scored], near: Bool?) -> [Scored] {
            rows.filter { $0.take.role == .probe && (near == nil || $0.session.isNear($0.index) == near) }
        }
        func rate(_ rows: [Scored], _ ok: (Scored) -> Bool) -> Double {
            rows.isEmpty ? .nan : Double(rows.filter(ok).count) / Double(rows.count)
        }
        func fixed(_ rows: [Scored]) -> Double { rate(rows) { $0.score.probeFixed == true } }

        var out: [String] = []
        out.append("# Context benchmark")
        out.append("")
        let setup = meta.polish == meta.updater ? "model \(meta.polish)" : "polish \(meta.polish) · update \(meta.updater)"
        out.append("\(file.sessions.count) scripted sessions, \(file.sessions.reduce(0) { $0 + $1.takes.count }) takes · \(setup) · seed \(meta.seed.map(String.init) ?? "none") · \(meta.samples) run(s) per take per arm.")
        out.append("Ranges are 95% bootstrap intervals over sessions.")
        if meta.polish == CBEngine.apple.label {
            out.append("Apple Intelligence polish sees the last three takes, not eight, so some near probes are out of its sight too.")
        }
        out.append("")
        out.append("## Polish")
        out.append("")
        out.append("| Arm | Probes fixed | near | far | Far vs plain | Controls harmed | Language changed | Invented terms | Line leaked | Edit rate | Wait p50 / p95 |")
        out.append("|---|---|---|---|---|---|---|---|---|---|---|")
        var farGain: [CBArm: (point: Double, low: Double, high: Double)] = [:]
        for arm in arms {
            let rows = byArm[arm] ?? []
            let allProbes = probes(rows, near: nil), near = probes(rows, near: true), far = probes(rows, near: false)
            let controls = rows.filter { $0.take.role == .control }
            let gain = arm == .plain ? nil : bootstrapGain(byArm, arm: arm, sessions: sessionIDs) { probes($0, near: false) }
            if let gain { farGain[arm] = gain }
            let waits = rows.map(\.step.seconds).sorted()
            out.append("| \(arm.rawValue) | \(pct(fixed(allProbes))) (\(count(allProbes) { $0.score.probeFixed == true })) | \(pct(fixed(near))) | \(pct(fixed(far))) | "
                + (gain.map { "\(signed($0.point)) [\(signed($0.low)), \(signed($0.high))]" } ?? "—")
                + " | \(count(controls) { $0.score.harmed }) of \(controls.count) | \(count(rows) { !$0.score.languageKept }) | \(count(rows) { !$0.score.invented.isEmpty }) | \(count(rows) { $0.score.leaked }) | "
                + String(format: "%.3f", mean(rows.map(\.score.editRate)))
                + " | " + String(format: "%.2f / %.2f s", quantile(waits, 0.5), quantile(waits, 0.95)) + " |")
        }
        out.append("")
        out.append("A near probe's name was said in the last eight takes, which polish already sees as examples; a far probe's was not, so only context can recover it. Controls are harmed by a changed language, a leaked context line, or an invented name or number.")

        let kept = arms.filter { $0 == .single || $0 == .separate }
        if !kept.isEmpty {
            out.append("")
            out.append("## Keeping topics")
            out.append("")
            out.append("| Arm | Thread covered after its takes | Name captured before a far probe | Merged topics | Topics over 8 words | Answers over 8 words | Changed on small talk | No answer | Updater p50 |")
            out.append("|---|---|---|---|---|---|---|---|---|")
            for arm in kept {
                let rows = byArm[arm] ?? []
                let threadRows = rows.filter { $0.take.thread != nil }
                let covered = count(threadRows) { row in row.step.topicsAfter.contains { row.session.threads(of: $0).contains(row.take.thread ?? "") } }
                let far = probes(rows, near: false)
                let captured = count(far) { row in
                    let names = (row.take.required ?? []).map { $0.lowercased() }
                    return row.step.topicsShown.contains { topic in names.contains { topic.lowercased().contains($0) } }
                }
                let merged = count(rows) { row in row.step.topicsAfter.contains { row.session.threads(of: $0).count > 1 } }
                let topics = Set(rows.flatMap(\.step.topicsAfter))
                let long = topics.filter { $0.split(separator: " ").count > 8 }.count
                // What the model wrote before the app cut it: whether the prompt
                // alone keeps topics short.
                let written = rows.compactMap { row -> String? in
                    switch AutoContext.change(fromTag: row.step.tag) {
                    case .refine(_, let text)?, .add(let text)?: return text
                    default: return nil
                    }
                }
                let wordy = written.filter { $0.split(separator: " ").count > 8 }.count
                let smalltalk = rows.filter { $0.take.role == .smalltalk }
                let churned = count(smalltalk) { row in
                    let change = row.step.change ?? ""
                    return change.hasPrefix("added") || change.hasPrefix("refined") || change.hasPrefix("too big")
                }
                let silent = count(rows) { $0.step.change == "no answer" }
                let updater = rows.compactMap(\.step.updaterSeconds).sorted()
                out.append("| \(arm.rawValue) | \(covered) of \(threadRows.count) | \(captured) of \(far.count) | \(merged) takes | \(long) of \(topics.count) | \(wordy) of \(written.count) | \(churned) of \(smalltalk.count) | \(silent) of \(rows.count) | "
                    + (updater.isEmpty ? "—" : String(format: "%.2f s", quantile(updater, 0.5))) + " |")
            }
        }

        out.append("")
        out.append("## What went wrong, take by take")
        out.append("")
        for arm in arms {
            let rows = byArm[arm] ?? []
            let harmed = rows.filter { $0.take.role == .control && $0.score.harmed }
            let missed = probes(rows, near: false).filter { $0.score.probeFixed != true }
            out.append("**\(arm.rawValue)** — \(harmed.count) harmed control(s), \(missed.count) far probe(s) missed")
            for row in harmed {
                out.append("- \(row.take.id) #\(row.step.sample + 1) control, \(row.score.summary): \(row.step.output)")
            }
            let missedByTake = Dictionary(grouping: missed, by: \.take.id).sorted { $0.key < $1.key }
            for (id, group) in missedByTake {
                let outputs = Set(group.map(\.step.output)).sorted().joined(separator: " / ")
                out.append("- \(id) far probe missed \(group.count)×: \(outputs)")
            }
            out.append("")
        }
        out.append("## Decision")
        out.append("")
        if let oracle = farGain[.oracle] {
            let helps = oracle.low > 0
            out.append("- Context can help polish at all (correct topics fix more far probes than plain, interval above zero): **\(helps ? "yes" : "no")** — \(signed(oracle.point)) [\(signed(oracle.low)), \(signed(oracle.high))]")
            let plainWait = quantile((byArm[.plain] ?? []).map(\.step.seconds).sorted(), 0.5)
            let plainHarm = count(byArm[.plain] ?? []) { $0.take.role == .control && $0.score.harmed }
            for arm in kept {
                guard let gain = farGain[arm] else { continue }
                let share = oracle.point > 0 ? gain.point / oracle.point : .nan
                let harm = count(byArm[arm] ?? []) { $0.take.role == .control && $0.score.harmed }
                let wait = quantile((byArm[arm] ?? []).map(\.step.seconds).sorted(), 0.5) - plainWait
                let keeps = helps && share >= 0.5
                let safe = harm <= plainHarm
                let quick = arm == .separate || wait <= 0.2
                out.append("- \(arm.rawValue): keeps \(share.isNaN ? "—" : pct(share)) of what correct topics gain (needs 50%) · controls harmed \(harm) against plain's \(plainHarm) · wait \(signed(wait, unit: "s")) (needs +0.2 s or less on the paste) → **\(keeps && safe && quick ? "passes" : "does not pass")**")
            }
        } else {
            out.append("- Run the oracle arm to decide: it is the yardstick the others are measured against.")
        }
        return out.joined(separator: "\n")
    }

    /// Far-probe fix rate of `arm` minus plain's, resampling whole sessions.
    private static func bootstrapGain(
        _ byArm: [CBArm: [Scored]], arm: CBArm, sessions: [String], rows select: ([Scored]) -> [Scored]
    ) -> (point: Double, low: Double, high: Double)? {
        guard let armRows = byArm[arm], let plainRows = byArm[.plain] else { return nil }
        let armBySession = Dictionary(grouping: select(armRows), by: \.session.id)
        let plainBySession = Dictionary(grouping: select(plainRows), by: \.session.id)
        func gain(_ ids: [String]) -> Double {
            let a = ids.flatMap { armBySession[$0] ?? [] }, p = ids.flatMap { plainBySession[$0] ?? [] }
            guard !a.isEmpty, !p.isEmpty else { return .nan }
            return Double(a.filter { $0.score.probeFixed == true }.count) / Double(a.count)
                - Double(p.filter { $0.score.probeFixed == true }.count) / Double(p.count)
        }
        var generator = CBRandom(seed: 20260928)
        var draws: [Double] = []
        for _ in 0..<2000 {
            let resample = sessions.map { _ in sessions[Int(generator.next() % UInt64(sessions.count))] }
            let value = gain(resample)
            if !value.isNaN { draws.append(value) }
        }
        draws.sort()
        guard !draws.isEmpty else { return nil }
        return (gain(sessions), quantile(draws, 0.025), quantile(draws, 0.975))
    }

    static func quantile(_ sorted: [Double], _ q: Double) -> Double {
        guard !sorted.isEmpty else { return .nan }
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * q + 0.5))]
    }

    private static func mean(_ values: [Double]) -> Double {
        values.isEmpty ? .nan : values.reduce(0, +) / Double(values.count)
    }

    private static func count<T>(_ rows: [T], _ ok: (T) -> Bool) -> Int { rows.filter(ok).count }

    static func pct(_ value: Double) -> String { value.isNaN ? "—" : String(format: "%.0f%%", value * 100) }

    private static func signed(_ value: Double, unit: String = "") -> String {
        if value.isNaN { return "—" }
        if unit.isEmpty { return String(format: "%+.0f pts", value * 100) }
        return String(format: "%+.2f %@", value, unit)
    }
}

/// SplitMix64: a fixed stream, so the same run gives the same intervals.
struct CBRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
