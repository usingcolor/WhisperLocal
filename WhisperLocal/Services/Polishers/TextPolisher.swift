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
            return "Polish request failed (\(code)): \(body)"
        case .notAvailable(let reason):
            return reason
        }
    }
}

struct PolishResult: Sendable {
    let text: String
    let stages: [String]
    /// True when an LLM cleanup step was expected but failed — caller should still paste.
    let cleanupFailed: Bool
    let cleanupNote: String?
}

/// Chains polishers: heuristic first, then optional local/cloud LLM upgrades.
/// Failures never drop the transcript — OpenWhispr-style paste-on-cleanup-failure.
struct PolishPipeline: Sendable {
    let heuristic: HeuristicPolisher
    let localLLM: (any TextPolisher)?
    let cloud: (any TextPolisher)?
    let useLocalLLM: Bool
    let enableTextCleanup: Bool
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

        if let polished = try? await heuristic.polish(text, dictionary: dictionary, personalContext: personalContext) {
            text = polished
            stages.append(heuristic.name)
        }

        var llmAttempted = false

        if useLocalLLM, let localLLM {
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

        return PolishResult(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            stages: stages,
            cleanupFailed: cleanupFailed,
            cleanupNote: cleanupNote
        )
    }
}
