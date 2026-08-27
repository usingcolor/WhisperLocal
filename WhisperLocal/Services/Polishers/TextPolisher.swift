import Foundation

protocol TextPolisher: Sendable {
    var name: String { get }
    func polish(_ text: String, dictionary: [String], personalContext: String) async throws -> String
}

extension TextPolisher {
    func polish(_ text: String, dictionary: [String]) async throws -> String {
        try await polish(text, dictionary: dictionary, personalContext: "")
    }
}

enum PolisherError: LocalizedError {
    case missingAPIKey(String)
    case emptyResponse
    case http(Int, String)
    case notAvailable(String)

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
}

struct PolishResult: Sendable {
    let text: String
    let stages: [String]
    /// True when an LLM cleanup step was expected but failed — caller should still paste.
    let cleanupFailed: Bool
    let cleanupNote: String?
}

/// Chains polishers: optional heuristic first, then either one on-device LLM or cloud polish.
/// Cloud replaces the on-device LLM so dictation is not delayed by both.
/// Failures never drop the transcript — OpenWhispr-style paste-on-cleanup-failure.
struct PolishPipeline: Sendable {
    let heuristic: HeuristicPolisher
    let localLLM: (any TextPolisher)?
    let cloud: (any TextPolisher)?
    let useLocalLLM: Bool
    let enableTextCleanup: Bool
    var enableHeuristicCleanup: Bool = true
    let dictionary: [String]
    var personalContext: String = ""

    func run(_ raw: String) async -> PolishResult {
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

        if enableHeuristicCleanup,
           let polished = try? await heuristic.polish(text, dictionary: dictionary, personalContext: personalContext) {
            text = polished
            stages.append(heuristic.name)
        }

        var llmAttempted = false

        // Cloud polish replaces the on-device LLM so we do not wait for both.
        if useLocalLLM, let localLLM, cloud == nil {
            llmAttempted = true
            do {
                text = try await localLLM.polish(text, dictionary: dictionary, personalContext: personalContext)
                stages.append(localLLM.name)
            } catch {
                stages.append("\(localLLM.name) failed")
                cleanupFailed = true
                cleanupNote = "Pasted without AI cleanup"
            }
        }

        if let cloud {
            llmAttempted = true
            do {
                text = try await cloud.polish(text, dictionary: dictionary, personalContext: personalContext)
                stages.append(cloud.name)
                // Cloud success clears earlier local-LLM failure note
                cleanupFailed = false
                cleanupNote = nil
            } catch {
                stages.append("\(cloud.name) failed")
                cleanupFailed = true
                cleanupNote = "Pasted without AI cleanup"
            }
        }

        // Heuristic-only path is still "cleaned" — only flag when an LLM step was expected.
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
}
