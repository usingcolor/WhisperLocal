import Foundation

protocol TextPolisher: Sendable {
    var name: String { get }
    func polish(
        _ text: String,
        dictionary: [String],
        personalContext: String,
        targetApp: String?,
        recentDictations: String
    ) async throws -> String
}

extension TextPolisher {
    func polish(_ text: String, dictionary: [String]) async throws -> String {
        try await polish(text, dictionary: dictionary, personalContext: "", targetApp: nil, recentDictations: "")
    }

    func polish(_ text: String, dictionary: [String], personalContext: String) async throws -> String {
        try await polish(text, dictionary: dictionary, personalContext: personalContext, targetApp: nil, recentDictations: "")
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

struct PolishResult: Sendable {
    let text: String
    let stages: [String]
    /// True when an LLM cleanup step was expected but failed — caller should still paste.
    let cleanupFailed: Bool
    let cleanupNote: String?
}

/// Chains polishers: filler strip, then either one on-device LLM or cloud polish.
/// Cloud replaces the on-device LLM so dictation is not delayed by both.
/// Failures never drop the transcript — OpenWhispr-style paste-on-cleanup-failure.
struct PolishPipeline: Sendable {
    let localLLM: (any TextPolisher)?
    let cloud: (any TextPolisher)?
    let useLocalLLM: Bool
    let enableTextCleanup: Bool
    let dictionary: [String]
    var personalContext: String = ""
    /// Request-time style examples from the dictation log. Empty unless the user opted in.
    var recentDictations: String = ""

    func run(_ raw: String, targetApp: String? = nil) async -> PolishResult {
        guard enableTextCleanup else {
            return PolishResult(
                text: raw.trimmingCharacters(in: .whitespacesAndNewlines),
                stages: ["Raw"],
                cleanupFailed: false,
                cleanupNote: nil
            )
        }

        var text = raw
        var stages: [String] = []
        var cleanupFailed = false
        var cleanupNote: String?

        text = applyFillerFilter(text, stages: &stages)

        var llmAttempted = false

        // Cloud polish replaces the on-device LLM so we do not wait for both.
        if useLocalLLM, let localLLM, cloud == nil {
            llmAttempted = true
            do {
                text = try await localLLM.polish(
                    text,
                    dictionary: dictionary,
                    personalContext: personalContext,
                    targetApp: targetApp,
                    recentDictations: recentDictations
                )
                stages.append(localLLM.name)
            } catch {
                stages.append("\(localLLM.name) failed")
                cleanupFailed = true
                cleanupNote = (error as? PolisherError)?.pasteNote ?? "Pasted without AI cleanup"
            }
        }

        if let cloud {
            llmAttempted = true
            do {
                text = try await cloud.polish(
                    text,
                    dictionary: dictionary,
                    personalContext: personalContext,
                    targetApp: targetApp,
                    recentDictations: recentDictations
                )
                stages.append(cloud.name)
                // Cloud success clears earlier local-LLM failure note
                cleanupFailed = false
                cleanupNote = nil
            } catch {
                stages.append("\(cloud.name) failed")
                cleanupFailed = true
                cleanupNote = (error as? PolisherError)?.pasteNote ?? "Pasted without AI cleanup"
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
            cleanupNote: cleanupNote
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
