import Foundation
#if os(macOS)
import AppKit
#endif

#if canImport(FoundationModels)
import FoundationModels
#endif

/// On-device polish via Apple Intelligence (`SystemLanguageModel`, ~3B).
/// Chosen for this Mac: M2 / macOS 26, no extra download, Neural Engine, stays offline.
final class LocalLLMPolisher: TextPolisher, @unchecked Sendable {
    static let shared = LocalLLMPolisher()

    let name = "Apple Intelligence"

    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }

    static var statusMessage: String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return "On-device Apple Intelligence (~3B). Audio and text stay on this Mac."
            case .unavailable(.appleIntelligenceNotEnabled):
                return "Turn on Apple Intelligence in System Settings → Apple Intelligence & Siri."
            case .unavailable(.modelNotReady):
                return "Apple Intelligence is downloading or preparing the on-device model."
            case .unavailable(.deviceNotEligible):
                return "This Mac isn’t eligible for Apple Intelligence."
            @unknown default:
                return "Apple Intelligence is unavailable."
            }
        }
        #endif
        return "Requires macOS 26 and Apple Intelligence."
    }

    static var needsSystemSettings: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if case .unavailable(.appleIntelligenceNotEnabled) = SystemLanguageModel.default.availability {
                return true
            }
        }
        #endif
        return false
    }

    static func openAppleIntelligenceSettings() {
        #if os(macOS)
        if let url = URL(string: "x-apple.systempreferences:com.apple.Siri-Settings") {
            NSWorkspace.shared.open(url)
        }
        #endif
    }

    func prewarm(personalContext: String = "", dictionary: [String] = []) {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            AppleIntelligenceBackend.shared.prewarm(personalContext: personalContext, dictionary: dictionary)
        }
        #endif
    }

    func polish(_ text: String, dictionary: [String], personalContext: String = "") async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return try await AppleIntelligenceBackend.shared.polish(
                trimmed,
                dictionary: dictionary,
                personalContext: personalContext
            )
        }
        #endif
        throw PolisherError.notAvailable("Local LLM polish requires macOS 26 and Apple Intelligence.")
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable
private struct PolishedDictation {
    @Guide(description: "Exactly the cleaned transcript and nothing else. Same speaker voice. No greeting, labels, or answers.")
    var text: String
}

@available(macOS 26.0, *)
private final class AppleIntelligenceBackend: @unchecked Sendable {
    static let shared = AppleIntelligenceBackend()

    private let lock = NSLock()
    private var warmSession: LanguageModelSession?
    private var warmFingerprint = ""
    private let timeoutSeconds: TimeInterval = 8

    func prewarm(personalContext: String = "", dictionary: [String] = []) {
        guard SystemLanguageModel.default.isAvailable else { return }
        let session = makeSession(dictionary: dictionary, personalContext: personalContext)
        session.prewarm()
        lock.lock()
        warmSession = session
        warmFingerprint = fingerprint(dictionary: dictionary, personalContext: personalContext)
        lock.unlock()
    }

    func polish(_ text: String, dictionary: [String], personalContext: String = "") async throws -> String {
        guard SystemLanguageModel.default.isAvailable else {
            throw PolisherError.notAvailable(LocalLLMPolisher.statusMessage)
        }

        let fp = fingerprint(dictionary: dictionary, personalContext: personalContext)
        let session: LanguageModelSession
        lock.lock()
        if let warmSession, warmFingerprint == fp {
            self.warmSession = nil
            lock.unlock()
            session = warmSession
            replenishWarmSession(dictionary: dictionary, personalContext: personalContext)
        } else {
            lock.unlock()
            session = makeSession(dictionary: dictionary, personalContext: personalContext)
        }

        let prompt = CleanupPrompt.wrapTranscript(text)
        let options = GenerationOptions(
            sampling: .greedy,
            maximumResponseTokens: min(max(text.count / 2, 128), 1024)
        )

        do {
            let cleaned = try await withTimeout(timeoutSeconds) {
                let response = try await session.respond(
                    to: prompt,
                    generating: PolishedDictation.self,
                    options: options
                )
                return response.content.text
            }
            let sanitized = sanitize(cleaned)
            guard !sanitized.isEmpty else { throw PolisherError.emptyResponse }
            return sanitized
        } catch is CancellationError {
            throw PolisherError.notAvailable("On-device polish timed out.")
        } catch let error as PolisherError {
            throw error
        } catch {
            throw PolisherError.notAvailable(error.localizedDescription)
        }
    }

    private func makeSession(dictionary: [String] = [], personalContext: String = "") -> LanguageModelSession {
        let model = SystemLanguageModel(
            useCase: .general,
            guardrails: .permissiveContentTransformations
        )
        return LanguageModelSession(
            model: model,
            instructions: CleanupPrompt.system(dictionary: dictionary, personalContext: personalContext)
        )
    }

    private func replenishWarmSession(dictionary: [String], personalContext: String) {
        guard SystemLanguageModel.default.isAvailable else { return }
        let next = makeSession(dictionary: dictionary, personalContext: personalContext)
        next.prewarm()
        lock.lock()
        warmSession = next
        warmFingerprint = fingerprint(dictionary: dictionary, personalContext: personalContext)
        lock.unlock()
    }

    private func fingerprint(dictionary: [String], personalContext: String) -> String {
        personalContext + "\u{1e}" + dictionary.joined(separator: "\u{1f}")
    }

    private func sanitize(_ raw: String) -> String {
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
        return text
    }

    private func withTimeout<T: Sendable>(
        _ seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw CancellationError()
            }
            guard let result = try await group.next() else {
                throw PolisherError.emptyResponse
            }
            group.cancelAll()
            return result
        }
    }
}
#endif
