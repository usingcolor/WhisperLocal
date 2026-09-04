import Foundation

enum PolishTask: Equatable, Sendable {
    /// Clean a take to paste into the focused app.
    case dictation
    /// Distill a spoken take into a short session-context phrase. Never pasted.
    case sessionContext
}

/// One polish step. `contextRelevant` is set only by Apple Intelligence structured output.
struct PolishedText: Sendable {
    var text: String
    var contextRelevant: Bool? = nil
}

protocol TextPolisher: Sendable {
    var name: String { get }
    func polish(
        _ text: String,
        dictionary: [String],
        personalContext: String,
        targetApp: String?,
        recentDictations: String,
        sessionIntent: String,
        task: PolishTask
    ) async throws -> PolishedText
}

extension TextPolisher {
    func polish(_ text: String, dictionary: [String]) async throws -> PolishedText {
        try await polish(
            text,
            dictionary: dictionary,
            personalContext: "",
            targetApp: nil,
            recentDictations: "",
            sessionIntent: "",
            task: .dictation
        )
    }

    func polish(_ text: String, dictionary: [String], personalContext: String) async throws -> PolishedText {
        try await polish(
            text,
            dictionary: dictionary,
            personalContext: personalContext,
            targetApp: nil,
            recentDictations: "",
            sessionIntent: "",
            task: .dictation
        )
    }
}

/// Wall-clock caps. Apple Intelligence used to be 8s and fail-opened on long takes.
enum PolishTimeouts {
    static let appleIntelligence: TimeInterval = 20
    static let gemma: TimeInterval = 20
    static let cloud: TimeInterval = 30
}

enum PolisherError: LocalizedError {
    case missingAPIKey(String)
    case emptyResponse
    case http(Int, String)
    case notAvailable(String)
    /// Model hit its output cap. Pipeline fail-opens to the previous stage.
    case truncated

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider):
            return "Missing \(provider) API key. Add it in Settings."
        case .emptyResponse:
            return "The polish model returned an empty response."
        case .http(let code, let body):
            return "Polish request failed (\(code)): \(Self.clipErrorBody(body))"
        case .notAvailable(let reason):
            return reason
        case .truncated:
            return "Cleanup was cut short. Pasted without AI cleanup."
        }
    }

    /// HUD / log note when an LLM step fails and the previous text is pasted.
    var pasteNote: String {
        switch self {
        case .truncated:
            return "Cleanup was cut short. Pasted without AI cleanup."
        default:
            return "Pasted without AI cleanup"
        }
    }

    private static func clipErrorBody(_ body: String) -> String {
        var text = body.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "see Console" }
        if text.count > 180 {
            return String(text.prefix(180)) + "…"
        }
        return text
    }
}

enum PolishOutput {
    /// Strip markdown fences and wrapping quotes some models add around a clean transcript.
    static func sanitize(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            if let firstNewline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: firstNewline)...])
            }
            if let fence = text.range(of: "```", options: .backwards) {
                text = String(text[..<fence.lowerBound])
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if text.count >= 2, let first = text.first, let last = text.last {
            let quoted = (first == "\"" && last == "\"")
                || (first == "'" && last == "'")
                || (first == "“" && last == "”")
            if quoted {
                let inner = String(text.dropFirst().dropLast())
                let hasInnerQuotes = inner.contains("\"") || inner.contains("'")
                    || inner.contains("“") || inner.contains("”")
                if !hasInnerQuotes {
                    text = inner.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        if let eos = text.range(of: "<end_of_turn>") {
            text = String(text[..<eos.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    /// Scale cloud / on-device output caps with the input. Dictation should not hit a 1k floor.
    static func maxOutputTokens(for text: String) -> Int {
        min(max(text.count / 2, 256), 4096)
    }

    static func openaiHitLengthCap(_ finishReason: String?) -> Bool {
        finishReason == "length"
    }

    static func anthropicHitTokenCap(_ stopReason: String?) -> Bool {
        stopReason == "max_tokens"
    }
}

/// Why a polish attempt failed, to the resolution the caller actually needs.
///
/// The distinction that matters is whether the *provider* is unusable for the rest
/// of this take, or whether this one request was bad. The first justifies falling
/// back to the on-device model and not asking the cloud again; the second does not.
enum PolishFailureKind: Sendable, Equatable {
    /// No route to the network at all.
    case offline
    /// Reached the provider, or tried to, and it cannot serve this take: transport
    /// error, 5xx, rate limit, or a key problem.
    case providerUnavailable
    /// The provider answered and this particular request failed — a truncated or
    /// empty completion. Another piece of the same take may still succeed.
    case requestFailed

    init(_ error: Error) {
        if error is URLError {
            self = (error as! URLError).code == .notConnectedToInternet ? .offline : .providerUnavailable
            return
        }
        guard let polisher = error as? PolisherError else {
            self = .requestFailed
            return
        }
        switch polisher {
        case .missingAPIKey, .notAvailable:
            self = .providerUnavailable
        case .http(let code, _):
            // 401/403 (key) and 429 (rate limit) will not resolve inside one take,
            // so they are provider-level even though they are 4xx.
            self = (code >= 500 || code == 429 || code == 401 || code == 403)
                ? .providerUnavailable
                : .requestFailed
        case .truncated, .emptyResponse:
            self = .requestFailed
        }
    }

    /// True when there is no point asking this provider again for this take.
    var stopsFurtherCloudAttempts: Bool {
        switch self {
        case .offline, .providerUnavailable: return true
        case .requestFailed: return false
        }
    }

    /// Shown when the on-device model picked the work up instead.
    var fallbackNote: String {
        switch self {
        case .offline: return "Offline — polished on this Mac"
        case .providerUnavailable, .requestFailed: return "Cloud failed — polished on this Mac"
        }
    }

    /// Shown when nothing could clean the text.
    var rawNote: String {
        switch self {
        case .offline: return "Offline — pasted without cleanup"
        case .providerUnavailable: return "Cloud unavailable — pasted without cleanup"
        case .requestFailed: return "Pasted without AI cleanup"
        }
    }
}

struct PolishResult: Sendable {
    let text: String
    let stages: [String]
    /// True when an LLM cleanup step was expected but failed — caller should still paste.
    let cleanupFailed: Bool
    let cleanupNote: String?
    /// Apple Intelligence judgment against `<session-intent>`. Nil if not judged.
    let contextRelevant: Bool?
    /// Set when the cloud provider looked unusable for the rest of this take, so a
    /// chunked run can stop paying its timeout on every remaining piece.
    var cloudUnavailable: Bool = false
}

/// Chains polishers: filler strip, then either one on-device LLM or cloud polish.
/// Cloud replaces the on-device LLM so dictation is not delayed by both.
/// Failures never drop the transcript — OpenWhispr-style paste-on-cleanup-failure.
struct PolishPipeline: Sendable {
    let localLLM: (any TextPolisher)?
    let cloud: (any TextPolisher)?
    let useLocalLLM: Bool
    /// The on-device model is loaded and can run *now*. Gemma is unloaded whenever
    /// cloud is selected, and letting it cold-start mid-dictation (2.7 GB plus
    /// kernel compilation) is worse than pasting without cleanup — so a fallback
    /// only happens when this is true.
    var localIsReady: Bool = false
    /// Injected by the caller. Defaults to "online" so the pipeline carries no
    /// dependency on the Network framework and stays in the test target.
    var isOnline: @Sendable () -> Bool = { true }
    let enableTextCleanup: Bool
    let dictionary: [String]
    var personalContext: String = ""
    /// Request-time style examples from the dictation log. Empty unless the user opted in.
    var recentDictations: String = ""
    /// Spoken, temporary context. User message only — never the system prefill.
    var sessionIntent: String = ""
    /// Dictation paste vs spoken session-context distillation.
    var task: PolishTask = .dictation

    /// Polishes a long transcript in pieces. One 20s/30s timeout and one output
    /// cap used to govern the whole take, so a long one lost all its cleanup at
    /// once; per piece, a failure costs that piece and the rest still comes back
    /// polished. Pieces are rejoined in order — nothing is dropped.
    func runChunked(
        _ raw: String,
        targetApp: String? = nil,
        onProgress: ((Int, Int) -> Void)? = nil
    ) async -> PolishResult {
        let pieces = PolishChunker.split(raw)
        guard pieces.count > 1 else {
            return await run(raw, targetApp: targetApp)
        }

        var texts: [String] = []
        var stages: [String] = []
        var failures = 0
        // Circuit breaker. Without it an outage costs the full request timeout on
        // every piece — a ten-minute take is ~10 pieces, so up to five minutes of
        // waiting to arrive at the same answer the first piece already gave us.
        var cloudDown = false

        for (index, piece) in pieces.enumerated() {
            onProgress?(index + 1, pieces.count)
            let result = await run(piece, targetApp: targetApp, cloudDisabled: cloudDown)
            if result.cloudUnavailable { cloudDown = true }
            // run() already falls back to the raw piece when cleanup fails, so the
            // text is never empty here — but be explicit rather than trust it.
            texts.append(result.text.isEmpty ? piece : result.text)
            if result.cleanupFailed { failures += 1 }
            for stage in result.stages where !stages.contains(stage) {
                stages.append(stage)
            }
        }

        let joined = texts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let note: String?
        if failures == pieces.count {
            note = cloudDown ? "Cloud unavailable — pasted without cleanup" : "Pasted without AI cleanup"
        } else if failures > 0 {
            note = "Cleaned \(pieces.count - failures) of \(pieces.count) parts"
        } else if cloudDown {
            // Every piece is cleaned, just not by the cloud.
            note = "Cloud unavailable — polished on this Mac"
        } else {
            note = nil
        }
        return PolishResult(
            text: joined.isEmpty ? raw : joined,
            stages: stages.isEmpty ? ["Raw"] : stages,
            cleanupFailed: failures == pieces.count,
            cleanupNote: note,
            contextRelevant: nil,
            cloudUnavailable: cloudDown
        )
    }

    func run(_ raw: String, targetApp: String? = nil) async -> PolishResult {
        await run(raw, targetApp: targetApp, cloudDisabled: false)
    }

    func run(_ raw: String, targetApp: String?, cloudDisabled: Bool) async -> PolishResult {
        guard enableTextCleanup else {
            return PolishResult(
                text: raw.trimmingCharacters(in: .whitespacesAndNewlines),
                stages: ["Raw"],
                cleanupFailed: false,
                cleanupNote: nil,
                contextRelevant: nil
            )
        }

        var text = raw
        var stages: [String] = []
        var cleanupFailed = false
        var cleanupNote: String?
        var contextRelevant: Bool?

        text = applyFillerFilter(text, stages: &stages)

        var llmAttempted = false
        let polishApp = task == .sessionContext ? nil : targetApp
        let polishRecent = task == .sessionContext ? "" : recentDictations
        let polishIntent = task == .sessionContext ? "" : sessionIntent

        // Cloud first when configured, then the on-device model, then the raw text.
        // The on-device step used to be gated on `cloud == nil`, so a cloud outage
        // dropped straight to no cleanup while a capable local model sat idle.
        var cloudFailure: PolishFailureKind?
        // The polisher's own reason is more specific than the kind for per-request
        // failures ("Cleanup was cut short"), so keep both and pick per case.
        var cloudPasteNote: String?
        var localPasteNote: String?
        var polished = false

        if let cloud, !cloudDisabled {
            if !isOnline() {
                cloudFailure = .offline
                stages.append("\(cloud.name) offline")
            } else {
                llmAttempted = true
                do {
                    let result = try await cloud.polish(
                        text,
                        dictionary: dictionary,
                        personalContext: personalContext,
                        targetApp: polishApp,
                        recentDictations: polishRecent,
                        sessionIntent: polishIntent,
                        task: task
                    )
                    text = result.text
                    // Cloud does not judge session context (plain-text output).
                    contextRelevant = nil
                    stages.append(cloud.name)
                    polished = true
                } catch {
                    cloudFailure = PolishFailureKind(error)
                    cloudPasteNote = (error as? PolisherError)?.pasteNote
                    stages.append("\(cloud.name) failed")
                }
            }
        }

        // On-device: primary when no cloud is configured, fallback when cloud could
        // not deliver. Falling back this direction only ever sends less data out.
        let wantsLocal = cloud == nil || cloudDisabled ? useLocalLLM : (cloudFailure != nil && localIsReady)
        if !polished, wantsLocal, let localLLM {
            llmAttempted = true
            do {
                let result = try await localLLM.polish(
                    text,
                    dictionary: dictionary,
                    personalContext: personalContext,
                    targetApp: polishApp,
                    recentDictations: polishRecent,
                    sessionIntent: polishIntent,
                    task: task
                )
                text = result.text
                contextRelevant = task == .sessionContext ? nil : result.contextRelevant
                stages.append(localLLM.name)
                polished = true
                // The take *is* cleaned — just not by the cloud. Say which, rather
                // than reporting a failure the user cannot see the effect of.
                cleanupNote = cloudFailure?.fallbackNote
            } catch {
                stages.append("\(localLLM.name) failed")
                localPasteNote = (error as? PolisherError)?.pasteNote
            }
        }

        if !polished, llmAttempted || cloudFailure != nil {
            cleanupFailed = true
            if let cloudFailure {
                // For an outage the outage is the useful message; for a one-off bad
                // response the polisher's own reason says more.
                cleanupNote = cloudFailure == .requestFailed
                    ? (cloudPasteNote ?? cloudFailure.rawNote)
                    : cloudFailure.rawNote
            } else {
                cleanupNote = localPasteNote ?? "Pasted without AI cleanup"
            }
        }

        text = applyFillerFilter(text, stages: &stages)

        // Filler-only path is still cleaned — only flag when an LLM step was expected.
        if !llmAttempted {
            cleanupFailed = false
            cleanupNote = nil
        }

        if stages.isEmpty {
            stages = ["Raw"]
        }

        return PolishResult(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            stages: stages,
            cleanupFailed: cleanupFailed,
            cleanupNote: cleanupNote,
            contextRelevant: contextRelevant,
            cloudUnavailable: cloudFailure?.stopsFurtherCloudAttempts ?? false
        )
    }

    private func applyFillerFilter(_ text: String, stages: inout [String]) -> String {
        let cleaned = VocalFillerFilter.strip(text)
        if cleaned != text, stages.last != "Fillers" {
            stages.append("Fillers")
        }
        return cleaned
    }
}

/// Drops vocalized pauses / sound effects that ASR writes as words.
/// Runs with text cleanup even when no LLM is selected, and again after the model.
enum VocalFillerFilter {
    static func strip(_ text: String) -> String {
        var result = text
        // "mm" doubles as the millimetre unit. Keep it after a number ("5 mm", "3.5 mm",
        // "50mm"); strip it only where it reads as a vocalized pause.
        result = result.replacingOccurrences(
            of: #"\b(?:um+|uh+|uhm|er|erm|ah+|eh+|hm+|mhm)\b[.,!?…]*"#
                + #"|(?<!\d)(?<!\d )(?<!\d\t)\bmm+\b[.,!?…]*"#,
            with: " ",
            options: [.regularExpression, .caseInsensitive]
        )
        result = result.replacingOccurrences(of: #",[ \t]*,+"#, with: ",", options: .regularExpression)
        result = result.replacingOccurrences(of: #"^[ \t,;:]+"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"[ \t,;:]+$"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\s+([,.;!?])"#, with: "$1", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
