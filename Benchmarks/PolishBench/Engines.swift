import CryptoKit
import Foundation
import Security

enum Provider: String, Codable, Sendable, CaseIterable {
    case openAI = "OpenAI"
    case anthropic = "Anthropic"

    var envName: String {
        switch self {
        case .openAI: return "OPENAI_API_KEY"
        case .anthropic: return "ANTHROPIC_API_KEY"
        }
    }

    /// Account names WhisperLocal saves its keys under.
    var keychainAccount: String {
        switch self {
        case .openAI: return "openai_api_key"
        case .anthropic: return "anthropic_api_key"
        }
    }

    static func of(model: String) -> Provider {
        model.hasPrefix("claude") ? .anthropic : .openAI
    }
}

enum EngineKind: Sendable, Hashable {
    /// The speech model's text, untouched: the floor.
    case raw
    /// The app with no LLM selected: filler stripping only.
    case fillers
    case apple
    case gemma
    case cloud(Provider, String)
}

/// Something that turns a raw transcript into pasted text.
struct Engine: Sendable, Hashable {
    let id: String
    let kind: EngineKind

    var provider: Provider? {
        if case .cloud(let provider, _) = kind { return provider }
        return nil
    }

    var isCloud: Bool { provider != nil }

    /// On-device models decode greedily, so a second run would give the same text
    /// and only re-measure the wait.
    var runsOnce: Bool { !isCloud }

    static func named(_ id: String) -> Engine {
        switch id {
        case "raw": return Engine(id: id, kind: .raw)
        case "fillers": return Engine(id: id, kind: .fillers)
        case "apple": return Engine(id: id, kind: .apple)
        case "gemma": return Engine(id: id, kind: .gemma)
        default: return Engine(id: id, kind: .cloud(Provider.of(model: id), id))
        }
    }

    /// Every model the app offers, straight from its catalog, so a model added to
    /// the app is benchmarked without anyone editing this list.
    @MainActor
    static func list(_ spec: String) -> [Engine] {
        let local = ["raw", "fillers", "apple", "gemma"]
        let openAI = CloudModelCatalog.openAIRecommended.map(\.id)
        let anthropic = CloudModelCatalog.anthropicRecommended.map(\.id)
        var ids: [String] = []
        for token in spec.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !token.isEmpty {
            switch token {
            case "all": ids += local + openAI + anthropic
            case "local": ids += local
            case "cloud": ids += openAI + anthropic
            case "openai": ids += openAI
            case "anthropic": ids += anthropic
            default: ids.append(token)
            }
        }
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }.map(named)
    }
}

struct APIKeys: Sendable {
    var openAI: String?
    var anthropic: String?
    /// Where each key came from, for the log line. Never the key itself.
    var sources: [Provider: String] = [:]

    func key(for provider: Provider) -> String? {
        switch provider {
        case .openAI: return openAI
        case .anthropic: return anthropic
        }
    }

    /// Environment first. The Keychain only when asked for, because reading the
    /// keys WhisperLocal saved makes macOS ask whoever is at the Mac to allow it.
    static func load(allowKeychain: Bool) -> APIKeys {
        var keys = APIKeys()
        let environment = ProcessInfo.processInfo.environment
        for provider in Provider.allCases {
            var value = environment[provider.envName]?.trimmingCharacters(in: .whitespacesAndNewlines)
            if value?.isEmpty == false {
                keys.sources[provider] = "environment"
            } else if allowKeychain, let saved = keychain(account: provider.keychainAccount), !saved.isEmpty {
                value = saved
                keys.sources[provider] = "WhisperLocal's Keychain item"
            } else {
                value = nil
            }
            switch provider {
            case .openAI: keys.openAI = value
            case .anthropic: keys.anthropic = value
            }
        }
        return keys
    }

    private static func keychain(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AppIdentity.publicBundleID,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// One request to a model within a take. A long take makes several.
struct CallRecord: Codable, Sendable {
    var seconds: Double
    var usage: PolishUsage?
    var error: String?
    /// A rate limit or a dropped connection says nothing about the model, so a take
    /// that hit one is run again next time instead of being cached.
    var transient: Bool = false
}

final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [CallRecord] = []

    func add(_ record: CallRecord) {
        lock.lock()
        records.append(record)
        lock.unlock()
    }

    var all: [CallRecord] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }
}

/// Wraps the app's own polisher to time each request and keep its token counts.
/// The pipeline around it — filler stripping, splitting, fallbacks — is untouched.
struct RecordingPolisher: TextPolisher {
    let inner: any TextPolisher
    let log: CallLog

    var name: String { inner.name }

    func polish(
        _ text: String,
        dictionary: [String],
        personalContext: String,
        targetApp: String?,
        recentDictations: String,
        sessionIntent: String,
        task: PolishTask,
        part: CleanupPrompt.TranscriptPart?,
        language: SpokenLanguage?
    ) async throws -> PolishedText {
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let result = try await inner.polish(
                text,
                dictionary: dictionary,
                personalContext: personalContext,
                targetApp: targetApp,
                recentDictations: recentDictations,
                sessionIntent: sessionIntent,
                task: task,
                part: part,
                language: language
            )
            log.add(CallRecord(seconds: (clock.now - start).seconds, usage: result.usage))
            return result
        } catch {
            let (message, transient) = Self.describe(error)
            log.add(CallRecord(seconds: (clock.now - start).seconds, error: message, transient: transient))
            throw error
        }
    }

    static func describe(_ error: Error) -> (String, Bool) {
        if let urlError = error as? URLError {
            // A timeout is the model being slow, which is exactly what is measured.
            return ("network: \(urlError.localizedDescription)", urlError.code != .timedOut)
        }
        if let polisher = error as? PolisherError {
            if case .http(let code, _) = polisher {
                return (polisher.localizedDescription, code == 429 || code >= 500)
            }
            return (polisher.localizedDescription, false)
        }
        return (String(describing: error), false)
    }
}

/// Builds the same pipeline the app builds for a take, with one engine in it.
struct EngineSetup {
    let engine: Engine
    let keys: APIKeys

    func pipeline(for item: BenchCase, log: CallLog) -> PolishPipeline {
        var local: (any TextPolisher)?
        var cloud: (any TextPolisher)?
        var cleanup = true
        var useLocal = false
        switch engine.kind {
        case .raw:
            cleanup = false
        case .fillers:
            break
        case .apple:
            local = RecordingPolisher(inner: LocalLLMPolisher.shared, log: log)
            useLocal = true
        case .gemma:
            local = RecordingPolisher(inner: GemmaMLXPolisher.shared, log: log)
            useLocal = true
        case .cloud(let provider, let model):
            let key = keys.key(for: provider) ?? ""
            let polisher: any TextPolisher = provider == .openAI
                ? OpenAIPolisher(apiKey: key, model: model)
                : AnthropicPolisher(apiKey: key, model: model)
            cloud = RecordingPolisher(inner: polisher, log: log)
        }
        return PolishPipeline(
            localLLM: local,
            cloud: cloud,
            useLocalLLM: useLocal,
            // No on-device fallback behind a cloud model: a failure has to show up
            // as a failure, not as Apple Intelligence quietly doing the work.
            localIsReady: false,
            enableTextCleanup: cleanup,
            language: item.spokenLanguage,
            dictionary: item.promptDictionary,
            personalContext: item.promptPersonalContext,
            sessionIntent: item.sessionIntent ?? "",
            task: item.polishTask
        )
    }

    /// The system prompt and user message this engine is sent, built by the app's
    /// own prompt code. Filler stripping runs before any model sees the text.
    func promptParts(for item: BenchCase) -> [String] {
        let text = VocalFillerFilter.strip(item.raw)
        let language = item.spokenLanguage
        let task = item.polishTask
        let app = task == .sessionContext ? nil : item.app
        let intent = task == .sessionContext ? "" : (item.sessionIntent ?? "")
        switch engine.kind {
        case .raw:
            return [item.raw]
        case .fillers:
            return [text]
        case .cloud, .gemma:
            let onDevice = engine.kind == .gemma
            return [
                CleanupPrompt.system(
                    for: task,
                    dictionary: item.promptDictionary,
                    personalContext: item.promptPersonalContext,
                    onDevice: onDevice
                ),
                CleanupPrompt.userMessage(
                    for: task,
                    text: text,
                    targetApp: app,
                    personalContext: item.promptPersonalContext,
                    sessionIntent: intent,
                    onDevice: onDevice,
                    language: language
                )
            ]
        case .apple:
            if task == .sessionContext {
                return [
                    CleanupPrompt.contextSystem(dictionary: item.promptDictionary, personalContext: item.promptPersonalContext),
                    CleanupPrompt.wrapContextTranscript(text, language: language)
                ]
            }
            return [
                CleanupPrompt.onDeviceSystem(dictionary: item.promptDictionary, personalContext: item.promptPersonalContext),
                CleanupPrompt.wrapOnDeviceTranscript(
                    text,
                    targetApp: app,
                    personalContext: item.promptPersonalContext,
                    sessionIntent: intent,
                    language: language
                )
            ]
        }
    }

    /// Hash of everything that decides the output. A change to the app's prompts
    /// changes it, so stale cached outputs are never reused by accident.
    func fingerprint(for item: BenchCase) -> String {
        let parts = [Bench.harnessVersion, engine.id, item.raw, item.app ?? "", item.language ?? "en"]
            + promptParts(for: item)
        let digest = SHA256.hash(data: Data(parts.joined(separator: "\u{1F}").utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
