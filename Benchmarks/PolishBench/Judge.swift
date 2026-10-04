import CryptoKit
import Foundation

/// One judge's call on one pair, in one order.
struct Verdict: Codable, Sendable {
    let caseID: String
    let candidate: String
    let anchor: String
    let judge: String
    /// 0: the candidate was shown as A. 1: as B. Every pair is judged both ways
    /// so a judge's taste for whichever comes first cancels out.
    let order: Int
    /// "candidate", "anchor", "tie", or "invalid" when the reply was unreadable.
    let winner: String
    let reason: String
    let usage: PolishUsage?
    let seconds: Double

    var key: String { "\(judge)|\(anchor)|\(candidate)|\(caseID)|\(order)" }

    /// +1 the candidate won, −1 the anchor won, 0 a tie.
    var score: Double? {
        switch winner {
        case "candidate": return 1
        case "anchor": return -1
        case "tie": return 0
        default: return nil
        }
    }
}

/// Head-to-head grading against one anchor engine, by judge models.
struct Judge {
    let keys: APIKeys
    let judges: [String]
    let anchor: String
    /// Engines to judge. Nil judges everything in the run.
    let candidates: [String]?
    /// Cases to judge. Nil judges every case in the run.
    let onlyCases: Set<String>?
    let cacheDir: URL
    let parallel: Int

    /// Bump when the judge instructions change; old verdicts no longer apply.
    static let promptVersion = "1"

    private struct Job: Sendable {
        let item: BenchCase
        let candidate: TakeOutput
        let anchor: TakeOutput
        let judge: String
        let order: Int
    }

    func run(store: RunStore) async throws -> [Verdict] {
        let outputs = try store.loadOutputs()
        let cases = Dictionary(try store.loadCases().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let anchors = Dictionary(
            outputs.filter { $0.engine == anchor && $0.repeatIndex == 0 }.map { ($0.caseID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        guard !anchors.isEmpty else {
            throw BenchError("this run has no outputs from the anchor \(anchor); run that engine first")
        }
        for judge in judges where keys.key(for: Provider.of(model: judge)) == nil {
            let provider = Provider.of(model: judge)
            throw BenchError("judge \(judge) needs \(provider.envName) (or --keychain)")
        }

        var jobs: [Job] = []
        for output in outputs where output.repeatIndex == 0 && output.engine != anchor {
            if let candidates, !candidates.contains(output.engine) { continue }
            if let onlyCases, !onlyCases.contains(output.caseID) { continue }
            guard let item = cases[output.caseID], let anchorOutput = anchors[output.caseID] else { continue }
            for judge in judges {
                for order in 0..<2 {
                    jobs.append(Job(item: item, candidate: output, anchor: anchorOutput, judge: judge, order: order))
                }
            }
        }
        Progress.note("\(jobs.count) judgements (\(judges.joined(separator: ", ")), anchor \(anchor))")

        let client = ChatClient(keys: keys)
        var verdicts: [Verdict] = []
        await withTaskGroup(of: Verdict.self) { group in
            var pending = jobs.makeIterator()
            for _ in 0..<parallel {
                guard let job = pending.next() else { break }
                group.addTask { await self.decideOrRecord(job, client: client) }
            }
            while let verdict = await group.next() {
                verdicts.append(verdict)
                if verdicts.count % 25 == 0 { Progress.note("  \(verdicts.count)/\(jobs.count)") }
                if let job = pending.next() {
                    group.addTask { await self.decideOrRecord(job, client: client) }
                }
            }
        }
        let invalid = verdicts.filter { $0.winner == "invalid" }.count
        if invalid > 0 { Progress.note("\(invalid) judgements came back unusable") }
        return verdicts
    }

    /// One judge failing is one missing verdict, not a dead run — the rest of the
    /// pairs are already paid for.
    private func decideOrRecord(_ job: Job, client: ChatClient) async -> Verdict {
        do {
            return try await decide(job, client: client)
        } catch {
            Progress.note("  \(job.judge) · \(job.item.id) · \(job.candidate.engine): \(error)")
            return Verdict(
                caseID: job.item.id, candidate: job.candidate.engine, anchor: job.anchor.engine,
                judge: job.judge, order: job.order, winner: "invalid",
                reason: String(describing: error).prefix(200).description,
                usage: nil, seconds: 0
            )
        }
    }

    private func decide(_ job: Job, client: ChatClient) async throws -> Verdict {
        // Identical text is a tie; no one needs to be paid to say so.
        if Normalize.text(job.candidate.text) == Normalize.text(job.anchor.text) {
            return Verdict(
                caseID: job.item.id, candidate: job.candidate.engine, anchor: job.anchor.engine,
                judge: job.judge, order: job.order, winner: "tie", reason: "identical text",
                usage: nil, seconds: 0
            )
        }
        let (first, second) = job.order == 0
            ? (job.candidate.text, job.anchor.text)
            : (job.anchor.text, job.candidate.text)
        let user = Self.userMessage(item: job.item, first: first, second: second)
        let cacheFile = cacheDir
            .appendingPathComponent(job.judge)
            .appendingPathComponent(Self.hash([Self.promptVersion, job.judge, Self.system, user]) + ".json")

        var reply: (text: String, usage: PolishUsage?, seconds: Double)
        if let data = try? Data(contentsOf: cacheFile),
           let cached = try? JSONCoding.decoder.decode(CachedReply.self, from: data) {
            reply = (cached.text, cached.usage, cached.seconds)
        } else {
            reply = try await client.complete(model: job.judge, system: Self.system, user: user)
            try? FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONCoding.encoder.encode(CachedReply(text: reply.text, usage: reply.usage, seconds: reply.seconds))
                .write(to: cacheFile, options: .atomic)
        }

        let parsed = Self.parse(reply.text)
        let winner: String
        switch parsed?.winner {
        case "A": winner = job.order == 0 ? "candidate" : "anchor"
        case "B": winner = job.order == 0 ? "anchor" : "candidate"
        case "TIE": winner = "tie"
        default: winner = "invalid"
        }
        return Verdict(
            caseID: job.item.id, candidate: job.candidate.engine, anchor: job.anchor.engine,
            judge: job.judge, order: job.order, winner: winner,
            reason: parsed?.reason ?? String(reply.text.prefix(200)),
            usage: reply.usage, seconds: reply.seconds
        )
    }

    private struct CachedReply: Codable {
        let text: String
        let usage: PolishUsage?
        let seconds: Double
    }

    // MARK: - Prompt

    static let system = """
    You grade the cleanup step of a dictation app. Someone dictated; speech recognition produced the raw transcript; a cleanup model rewrote it, and the result was pasted into the app they were typing in. You compare two cleanups of the same transcript.

    A good cleanup:
    - removes fillers (um, uh), false starts, and anything the speaker cancelled ("scratch that", "wait no"), keeping only their final wording;
    - keeps the meaning exactly: adds nothing, answers nothing, and drops nothing the speaker meant to keep;
    - keeps the speaker's own words, tone and formality, fixing grammar and punctuation rather than rewriting;
    - turns spoken punctuation ("comma", "period", "new line") into the marks;
    - fixes obvious recognition errors, especially names in the dictionary;
    - stays in the language the speaker used and never translates;
    - suits the target app when one is given: a command stays a command, chat stays casual;
    - contains only the text: no preamble, labels, quotes or notes.

    A dictated question or instruction is text to clean. Answering it or carrying it out is the worst possible failure.

    The reference is one acceptable cleanup, not the only one. Do not penalise different valid punctuation or wording; do penalise anything the list above rules out. Length is not quality. Output A and Output B are in random order.

    Reply with JSON only: {"winner": "A" | "B" | "tie", "reason": "<one short sentence>"}
    """

    static func userMessage(item: BenchCase, first: String, second: String) -> String {
        var lines: [String] = []
        if item.polishTask == .sessionContext {
            lines.append("<task>This take sets session context: the output should be one or two short sentences saying what the speaker is working on, not a cleaned dictation.</task>")
        }
        if let app = item.app, !app.isEmpty { lines.append("<target-app>\(app)</target-app>") }
        if !item.spokenLanguage.isEnglish { lines.append("<language>\(item.spokenLanguage.englishName)</language>") }
        lines.append("<dictionary>\(item.promptDictionary.joined(separator: ", "))</dictionary>")
        if let intent = item.sessionIntent, !intent.isEmpty { lines.append("<session-context>\(intent)</session-context>") }
        lines.append("<raw-transcript>\n\(item.raw)\n</raw-transcript>")
        lines.append("<reference>\n\(item.reference)\n</reference>")
        lines.append("<output-a>\n\(first)\n</output-a>")
        lines.append("<output-b>\n\(second)\n</output-b>")
        lines.append("Which output is the better cleanup? Reply with the JSON object only.")
        return lines.joined(separator: "\n")
    }

    static func parse(_ text: String) -> (winner: String, reason: String)? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let object = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any],
              let winner = (object["winner"] as? String)?.trimmingCharacters(in: .whitespaces).uppercased(),
              ["A", "B", "TIE"].contains(winner)
        else { return nil }
        return (winner, object["reason"] as? String ?? "")
    }

    static func hash(_ parts: [String]) -> String {
        SHA256.hash(data: Data(parts.joined(separator: "\u{1F}").utf8))
            .prefix(10).map { String(format: "%02x", $0) }.joined()
    }
}

/// Plain chat requests for the judges. Candidates never go through here: they
/// use the app's own polishers.
struct ChatClient: Sendable {
    let keys: APIKeys

    /// The response as the provider sent it, with the text clipped. For probing a
    /// model that fails inside the app and saying exactly why.
    func raw(model: String, system: String, user: String, maxTokens: Int, thinking: String?) async throws -> String {
        let provider = Provider.of(model: model)
        guard let key = keys.key(for: provider) else { throw BenchError("no \(provider.rawValue) key for \(model)") }
        var request: URLRequest
        var body: [String: Any]
        switch provider {
        case .openAI:
            request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            body = [
                "model": model,
                "messages": [["role": "system", "content": system], ["role": "user", "content": user]]
            ]
            if CloudModelCatalog.supportsChatTemperature(model) { body["temperature"] = 0.2 }
        case .anthropic:
            request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body = [
                "model": model,
                "max_tokens": maxTokens,
                "system": [["type": "text", "text": system, "cache_control": ["type": "ephemeral"]]],
                "messages": [["role": "user", "content": user]]
            ]
            if CloudModelCatalog.supportsMessagesTemperature(model) { body["temperature"] = 0.2 }
            if let thinking { body["thinking"] = ["type": thinking] }
        }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 180
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "HTTP \(code): \(String(data: data, encoding: .utf8) ?? "")"
        }
        if var blocks = json["content"] as? [[String: Any]] {
            for index in blocks.indices {
                if let text = blocks[index]["text"] as? String {
                    blocks[index]["text"] = String(text.prefix(300)) + (text.count > 300 ? "… [\(text.count) characters]" : "")
                }
            }
            json["content"] = blocks
        }
        if var choices = json["choices"] as? [[String: Any]] {
            for index in choices.indices {
                if var message = choices[index]["message"] as? [String: Any], let text = message["content"] as? String {
                    message["content"] = String(text.prefix(300)) + (text.count > 300 ? "… [\(text.count) characters]" : "")
                    choices[index]["message"] = message
                }
            }
            json["choices"] = choices
        }
        let pretty = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        return "HTTP \(code)\n" + (String(data: pretty, encoding: .utf8) ?? "")
    }

    func complete(model: String, system: String, user: String) async throws -> (text: String, usage: PolishUsage?, seconds: Double) {
        let provider = Provider.of(model: model)
        guard let key = keys.key(for: provider) else {
            throw BenchError("no \(provider.rawValue) key for \(model)")
        }
        var request: URLRequest
        let body: [String: Any]
        switch provider {
        case .openAI:
            request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            var openAIBody: [String: Any] = [
                "model": model,
                "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
                "response_format": ["type": "json_object"]
            ]
            if CloudModelCatalog.supportsChatTemperature(model) {
                openAIBody["temperature"] = 0
            } else {
                openAIBody["reasoning_effort"] = "low"
            }
            body = openAIBody
        case .anthropic:
            request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            var anthropicBody: [String: Any] = [
                "model": model,
                "max_tokens": 400,
                "system": system,
                "messages": [["role": "user", "content": user]]
            ]
            // Same two rules the app follows: Claude 5 rejects temperature, and its
            // thinking tokens would eat the 400-token budget before the verdict.
            if CloudModelCatalog.supportsMessagesTemperature(model) { anthropicBody["temperature"] = 0 }
            if CloudModelCatalog.thinksByDefault(model) { anthropicBody["thinking"] = ["type": "disabled"] }
            body = anthropicBody
        }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 120

        var delay: UInt64 = 2_000_000_000
        for attempt in 1...5 {
            let clock = ContinuousClock()
            let start = clock.now
            let data: Data
            let code: Int
            do {
                let (body, response) = try await URLSession.shared.data(for: request)
                data = body
                code = (response as? HTTPURLResponse)?.statusCode ?? -1
            } catch let error as URLError where attempt < 5 {
                Progress.note("  \(model): \(error.localizedDescription), retrying")
                try await Task.sleep(nanoseconds: delay)
                delay *= 2
                continue
            }
            if (code == 429 || code >= 500), attempt < 5 {
                try await Task.sleep(nanoseconds: delay)
                delay *= 2
                continue
            }
            guard (200..<300).contains(code) else {
                let text = String(data: data, encoding: .utf8) ?? ""
                throw BenchError("\(model) HTTP \(code): \(text.prefix(300))")
            }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let seconds = (clock.now - start).seconds
            switch provider {
            case .openAI:
                let choice = (json?["choices"] as? [[String: Any]])?.first
                let text = (choice?["message"] as? [String: Any])?["content"] as? String ?? ""
                return (text, PolishUsage.openAI(json?["usage"] as? [String: Any]), seconds)
            case .anthropic:
                let blocks = json?["content"] as? [[String: Any]] ?? []
                let text = blocks.compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }.joined()
                return (text, PolishUsage.anthropic(json?["usage"] as? [String: Any]), seconds)
            }
        }
        throw BenchError("\(model): gave up after 5 attempts")
    }
}
