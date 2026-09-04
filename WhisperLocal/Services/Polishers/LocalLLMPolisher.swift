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

    func polish(
        _ text: String,
        dictionary: [String],
        personalContext: String = "",
        targetApp: String? = nil,
        recentDictations: String = "",
        sessionIntent: String = "",
        task: PolishTask = .dictation,
        part: CleanupPrompt.TranscriptPart? = nil
    ) async throws -> PolishedText {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return PolishedText(text: trimmed) }

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return try await AppleIntelligenceBackend.shared.polish(
                trimmed,
                dictionary: dictionary,
                personalContext: personalContext,
                targetApp: targetApp,
                recentDictations: recentDictations,
                sessionIntent: sessionIntent,
                task: task,
                part: part
            )
        }
        #endif
        throw PolisherError.notAvailable("Local LLM polish requires macOS 26 and Apple Intelligence.")
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable
private struct PolishedSessionContext {
    @Guide(description: "The session context phrase only. One or two short sentences. No greeting, labels, or quotes.")
    var text: String
}

@available(macOS 26.0, *)
@Generable
private struct PolishedDictation {
    @Guide(description: "Exactly the cleaned transcript and nothing else. Same speaker voice. No greeting, labels, or answers.")
    var text: String
    @Guide(description: "True if this transcript plausibly belongs to the stated session context. False only when it is clearly about something else.")
    var matchesSessionContext: Bool
}

@available(macOS 26.0, *)
private final class AppleIntelligenceBackend: @unchecked Sendable {
    static let shared = AppleIntelligenceBackend()

    private let lock = NSLock()
    private var warmSessions: [LanguageModelSession] = []
    private var warmFingerprint = ""
    private let poolSize = 2
    private let timeoutSeconds: TimeInterval = PolishTimeouts.appleIntelligence

    func prewarm(personalContext: String = "", dictionary: [String] = []) {
        guard SystemLanguageModel.default.isAvailable else { return }
        let fp = fingerprint(dictionary: dictionary, personalContext: personalContext)
        Task.detached { [fp, dictionary, personalContext] in
            AppleIntelligenceBackend.shared.fillPool(
                fingerprint: fp,
                dictionary: dictionary,
                personalContext: personalContext
            )
        }
    }

    func polish(
        _ text: String,
        dictionary: [String],
        personalContext: String = "",
        targetApp: String? = nil,
        recentDictations: String = "",
        sessionIntent: String = "",
        task: PolishTask = .dictation,
        part: CleanupPrompt.TranscriptPart? = nil
    ) async throws -> PolishedText {
        guard SystemLanguageModel.default.isAvailable else {
            throw PolisherError.notAvailable(LocalLLMPolisher.statusMessage)
        }

        if task == .sessionContext {
            return try await polishSessionContext(
                text,
                dictionary: dictionary,
                personalContext: personalContext
            )
        }

        let fp = fingerprint(dictionary: dictionary, personalContext: personalContext)
        let session = takeSession(fingerprint: fp, dictionary: dictionary, personalContext: personalContext)
        let prompt = CleanupPrompt.wrapOnDeviceTranscript(
            text,
            targetApp: targetApp,
            personalContext: personalContext,
            recentDictations: recentDictations,
            sessionIntent: sessionIntent,
            part: part
        )
        let options = GenerationOptions(
            sampling: .greedy,
            maximumResponseTokens: PolishOutput.maxOutputTokens(for: text)
        )

        defer {
            Task.detached { [fp, dictionary, personalContext] in
                AppleIntelligenceBackend.shared.fillPool(
                    fingerprint: fp,
                    dictionary: dictionary,
                    personalContext: personalContext
                )
            }
        }

        do {
            let generated = try await withTimeout(timeoutSeconds) { () -> (String, Bool) in
                let response = try await session.respond(
                    to: prompt,
                    generating: PolishedDictation.self,
                    options: options
                )
                return (response.content.text, response.content.matchesSessionContext)
            }
            let sanitized = PolishOutput.sanitize(generated.0)
            guard !sanitized.isEmpty else { throw PolisherError.emptyResponse }
            let judged = !sessionIntent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return PolishedText(
                text: sanitized,
                contextRelevant: judged ? generated.1 : nil
            )
        } catch is CancellationError {
            throw PolisherError.notAvailable("On-device polish timed out.")
        } catch let error as PolisherError {
            throw error
        } catch {
            if Self.looksLikeTruncation(error) {
                throw PolisherError.truncated
            }
            throw PolisherError.notAvailable(error.localizedDescription)
        }
    }

    private func polishSessionContext(
        _ text: String,
        dictionary: [String],
        personalContext: String
    ) async throws -> PolishedText {
        let session = LanguageModelSession(
            model: SystemLanguageModel(
                useCase: .general,
                guardrails: .permissiveContentTransformations
            ),
            instructions: CleanupPrompt.contextSystem(
                dictionary: dictionary,
                personalContext: personalContext
            )
        )
        let prompt = CleanupPrompt.wrapContextTranscript(text)
        let options = GenerationOptions(
            sampling: .greedy,
            maximumResponseTokens: min(PolishOutput.maxOutputTokens(for: text), 128)
        )
        do {
            let generated = try await withTimeout(timeoutSeconds) { () -> String in
                let response = try await session.respond(
                    to: prompt,
                    generating: PolishedSessionContext.self,
                    options: options
                )
                return response.content.text
            }
            let sanitized = PolishOutput.sanitize(generated)
            guard !sanitized.isEmpty else { throw PolisherError.emptyResponse }
            return PolishedText(text: sanitized, contextRelevant: nil)
        } catch is CancellationError {
            throw PolisherError.notAvailable("On-device polish timed out.")
        } catch let error as PolisherError {
            throw error
        } catch {
            if Self.looksLikeTruncation(error) {
                throw PolisherError.truncated
            }
            throw PolisherError.notAvailable(error.localizedDescription)
        }
    }

    private func takeSession(
        fingerprint fp: String,
        dictionary: [String],
        personalContext: String
    ) -> LanguageModelSession {
        lock.lock()
        if warmFingerprint == fp, !warmSessions.isEmpty {
            let session = warmSessions.removeFirst()
            lock.unlock()
            return session
        }
        lock.unlock()
        return makeSession(dictionary: dictionary, personalContext: personalContext)
    }

    private func fillPool(fingerprint fp: String, dictionary: [String], personalContext: String) {
        guard SystemLanguageModel.default.isAvailable else { return }
        lock.lock()
        if warmFingerprint != fp {
            warmSessions.removeAll()
            warmFingerprint = fp
        }
        lock.unlock()

        while true {
            lock.lock()
            let hasRoom = warmFingerprint == fp && warmSessions.count < poolSize
            lock.unlock()
            guard hasRoom else { return }

            let session = makeSession(dictionary: dictionary, personalContext: personalContext)
            session.prewarm()

            lock.lock()
            if warmFingerprint == fp, warmSessions.count < poolSize {
                warmSessions.append(session)
            }
            let done = warmFingerprint != fp || warmSessions.count >= poolSize
            lock.unlock()
            if done { return }
        }
    }

    private func makeSession(dictionary: [String] = [], personalContext: String = "") -> LanguageModelSession {
        let model = SystemLanguageModel(
            useCase: .general,
            guardrails: .permissiveContentTransformations
        )
        return LanguageModelSession(
            model: model,
            instructions: CleanupPrompt.onDeviceSystem(
                dictionary: dictionary,
                personalContext: personalContext
            )
        )
    }

    private func fingerprint(dictionary: [String], personalContext: String) -> String {
        CleanupPrompt.onDeviceSystem(dictionary: dictionary, personalContext: personalContext)
    }

    private static func looksLikeTruncation(_ error: Error) -> Bool {
        let text = error.localizedDescription.lowercased()
        if text.contains("exceeded context") { return true }
        return text.contains("maximum") && (text.contains("token") || text.contains("response"))
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
