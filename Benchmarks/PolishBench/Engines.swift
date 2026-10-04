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
    /// An open-weight model that runs on this Mac but is not shipped in the app.
    /// Held by engine id; the weights it names are in `OpenWeightModels`.
    case openWeight(String)
    case cloud(Provider, String)
}

/// Open-weight models the benchmark can run on the Mac it is running on, none of
/// which the app ships. They go through the app's own MLX polisher, so the only
/// thing separating them from the `gemma` engine is the weights.
///
/// Each one is a 4-bit MLX conversion whose `model_type` mlx-swift-lm can build.
/// Sizes are the download; the first run of an engine pays for it once.
enum OpenWeightModels {
    static let all: [MLXTextModel] = [qwen3, ministral, granite, llama]

    /// Apache-2.0, ungated, and deliberately the non-thinking half of the Qwen3
    /// split: the hybrid opens a `<think>` block unless the template is told not
    /// to, and reasoning is the one thing a polisher must never paste.
    static let qwen3 = MLXTextModel(
        name: "Qwen3 4B",
        huggingFaceID: "mlx-community/Qwen3-4B-Instruct-2507-4bit",
        sizeOnDisk: "~2.3 GB",
        extraEOSTokens: ["<|im_end|>", "<|endoftext|>"],
        endOfTurn: "<|im_end|>"
    )

    /// Apache-2.0, ungated. `model_type` is `mistral3`, whose configuration reads
    /// `text_config` when there is one, so the vision tower is never built.
    static let ministral = MLXTextModel(
        name: "Ministral 3B",
        huggingFaceID: "mlx-community/Ministral-3-3B-Instruct-2512-4bit",
        sizeOnDisk: "~2.8 GB",
        extraEOSTokens: ["</s>"],
        endOfTurn: "</s>"
    )

    /// Apache-2.0, ungated. The smallest of the three, and the only one whose card
    /// claims no Korean — which the Korean cases are there to find out about.
    static let granite = MLXTextModel(
        name: "Granite 4 Micro",
        huggingFaceID: "mlx-community/granite-4.0-h-micro-4bit",
        sizeOnDisk: "~1.8 GB",
        extraEOSTokens: ["<|end_of_text|>"],
        endOfTurn: "<|end_of_text|>"
    )

    /// Ungated, but the Llama 3.2 Community Licence rather than an OSI one, and its
    /// card claims no Korean. Here because it is the obvious open-weight baseline to
    /// compare against, not because the app could ship it without a licence review.
    static let llama = MLXTextModel(
        name: "Llama 3.2 3B",
        huggingFaceID: "mlx-community/Llama-3.2-3B-Instruct-4bit",
        sizeOnDisk: "~1.8 GB",
        extraEOSTokens: ["<|eot_id|>", "<|end_of_text|>", "<|eom_id|>"],
        endOfTurn: "<|eot_id|>"
    )

    static func spec(_ id: String) -> MLXTextModel? {
        all.first { engineID(for: $0) == id }
    }

    /// The engine name on the command line and in the report.
    static func engineID(for model: MLXTextModel) -> String {
        model.name.lowercased().replacingOccurrences(of: " ", with: "-")
    }

    static var ids: [String] { all.map(engineID) }

    /// One polisher per model for the whole run. Each holds its own loaded weights,
    /// so building a fresh one per take would re-read gigabytes for every case.
    static func polisher(_ id: String) -> GemmaMLXPolisher? {
        lock.lock()
        defer { lock.unlock() }
        if let made = loaded[id] { return made }
        guard let spec = spec(id) else { return nil }
        let made = GemmaMLXPolisher(model: spec)
        loaded[id] = made
        return made
    }

    private static let lock = NSLock()
    private static var loaded: [String: GemmaMLXPolisher] = [:]
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

    /// True for every engine that sends an LLM the on-device prompt: the app's own
    /// Gemma and the open-weight models measured beside it.
    var isOnDeviceLLM: Bool {
        switch kind {
        case .gemma, .openWeight: return true
        default: return false
        }
    }

    /// On-device models decode greedily, so a second run would give the same text
    /// and only re-measure the wait.
    var runsOnce: Bool { !isCloud }

    static func named(_ id: String) -> Engine {
        switch id {
        case "raw": return Engine(id: id, kind: .raw)
        case "fillers": return Engine(id: id, kind: .fillers)
        case "apple": return Engine(id: id, kind: .apple)
        case "gemma": return Engine(id: id, kind: .gemma)
        default:
            if OpenWeightModels.spec(id) != nil { return Engine(id: id, kind: .openWeight(id)) }
            return Engine(id: id, kind: .cloud(Provider.of(model: id), id))
        }
    }

    /// Every model the app offers, straight from its catalog, so a model added to
    /// the app is benchmarked without anyone editing this list.
    @MainActor
    static func list(_ spec: String) -> [Engine] {
        let local = ["raw", "fillers", "apple", "gemma"]
        let openWeight = OpenWeightModels.ids
        let openAI = CloudModelCatalog.openAIRecommended.map(\.id)
        let anthropic = CloudModelCatalog.anthropicRecommended.map(\.id)
        var ids: [String] = []
        for token in spec.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !token.isEmpty {
            switch token {
            // `all` stays what it was: the app's own engines plus the cloud
            // shortlist. The open-weight models are gigabytes to fetch, so they
            // are asked for by name or as `oss`.
            case "all": ids += local + openAI + anthropic
            case "oss": ids += openWeight
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
        case .openWeight(let id):
            guard let polisher = OpenWeightModels.polisher(id) else { break }
            local = RecordingPolisher(inner: polisher, log: log)
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
        case .cloud, .gemma, .openWeight:
            let onDevice = engine.isOnDeviceLLM
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
