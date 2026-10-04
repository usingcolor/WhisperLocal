import Foundation

struct CloudModelOption: Identifiable, Hashable, Sendable, Codable {
    let id: String
    let displayName: String
    var note: String?

    var pickerLabel: String {
        if let note, !note.isEmpty {
            return "\(displayName) — \(note)"
        }
        return displayName
    }
}

/// Chat models for cloud polish. The picker is list-only; **Update models** fetches from the API.
@MainActor
final class CloudModelCatalog: ObservableObject {
    static let shared = CloudModelCatalog()

    @Published private(set) var openAIModels: [CloudModelOption]
    @Published private(set) var anthropicModels: [CloudModelOption]
    @Published private(set) var openAIStatus: String?
    @Published private(set) var anthropicStatus: String?
    @Published private(set) var isLoadingOpenAI = false
    @Published private(set) var isLoadingAnthropic = false

    /// Fast models first — dictation polish does not need a frontier model.
    /// IDs match OpenAI’s API (`gpt-6-luna`, `gpt-5.6-luna` / `-terra` / `-sol`).
    /// Only GPT-6 Luna of its family is here: it is the one the benchmark has
    /// measured, and **Update models** offers the rest of what the account has.
    static let openAIRecommended: [CloudModelOption] = [
        CloudModelOption(id: "gpt-6-luna", displayName: "GPT-6 Luna", note: "fast / cheap"),
        CloudModelOption(id: "gpt-5.6-luna", displayName: "GPT-5.6 Luna", note: "fast"),
        CloudModelOption(id: "gpt-5.6-terra", displayName: "GPT-5.6 Terra", note: "balanced"),
        CloudModelOption(id: "gpt-5.6-sol", displayName: "GPT-5.6 Sol", note: "highest quality"),
        CloudModelOption(id: "gpt-4.1-mini", displayName: "GPT-4.1 Mini", note: "fast"),
        CloudModelOption(id: "gpt-4.1", displayName: "GPT-4.1", note: "quality"),
        CloudModelOption(id: "gpt-4o-mini", displayName: "GPT-4o Mini", note: "fast"),
        CloudModelOption(id: "gpt-4o", displayName: "GPT-4o", note: "quality")
    ]

    /// Claude 3.5 Haiku used to be here as the legacy option. The API now answers
    /// 404 for it, so picking it failed every take — a model that cannot run is
    /// worse than no entry at all. **Update models** still offers whatever the
    /// account actually has.
    static let anthropicRecommended: [CloudModelOption] = [
        CloudModelOption(id: "claude-haiku-4-5", displayName: "Claude Haiku 4.5", note: "fast / cheap"),
        CloudModelOption(id: "claude-sonnet-5", displayName: "Claude Sonnet 5", note: "balanced"),
        CloudModelOption(id: "claude-opus-5", displayName: "Claude Opus 5", note: "highest quality"),
        CloudModelOption(id: "claude-sonnet-4-5", displayName: "Claude Sonnet 4.5")
    ]

    /// The polish benchmark settled this one. On the same 125 dictations, run on
    /// 26 September 2026, GPT-6 Luna left a hard failure in 2 takes against
    /// GPT-5.6 Luna's 6 and GPT-4o Mini's 14, and the judge preferred both Lunas
    /// over GPT-4o Mini in 55% of head-to-head pairs. It costs $0.12 per thousand
    /// takes, the same as GPT-4o Mini and a little over half of GPT-5.6 Luna's
    /// $0.21, and answers in about 1.3 s against 5.6 Luna's 1.1 s. Both of its
    /// failures were borderline — "stand-up" for "standup" is one.
    ///
    /// Only people who never picked a model get this; a model someone chose
    /// stays chosen. GPT-6 also needs the temperature rule that treats GPT-5 and
    /// later alike, or every take fails — releases before it must not default here.
    static let openAIDefault = "gpt-6-luna"
    static let anthropicDefault = "claude-haiku-4-5"

    private static let openAICacheKey = "openAIFetchedModelsJSON"
    private static let anthropicCacheKey = "anthropicFetchedModelsJSON"

    private init() {
        openAIModels = Self.loadCache(key: Self.openAICacheKey) ?? Self.openAIRecommended
        anthropicModels = Self.loadCache(key: Self.anthropicCacheKey) ?? Self.anthropicRecommended
    }

    func fetchOpenAI(apiKey: String) async {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            openAIStatus = "Save an API key first, then Update models."
            return
        }

        isLoadingOpenAI = true
        openAIStatus = nil
        defer { isLoadingOpenAI = false }

        do {
            var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<300).contains(code) else {
                throw PolisherError.http(code, String(data: data, encoding: .utf8) ?? "")
            }
            let ids = try Self.parseOpenAIModelIDs(from: data)
            let fetched = ids
                .filter { Self.isOpenAIChatModel($0) }
                .map { id in
                    Self.openAIRecommended.first(where: { $0.id == id })
                        ?? CloudModelOption(id: id, displayName: Self.prettyDisplayName(for: id))
                }
            let merged = Self.mergeForPicker(recommended: Self.openAIRecommended, fetched: fetched)
            if merged.isEmpty {
                openAIStatus = "No chat models on this key. Showing recommended list."
                return
            }
            openAIModels = merged
            Self.saveCache(merged, key: Self.openAICacheKey)
            openAIStatus = "Updated \(merged.count) models from OpenAI."
        } catch {
            openAIStatus = "Could not update OpenAI models: \(error.localizedDescription)"
        }
    }

    func fetchAnthropic(apiKey: String) async {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            anthropicStatus = "Save an API key first, then Update models."
            return
        }

        isLoadingAnthropic = true
        anthropicStatus = nil
        defer { isLoadingAnthropic = false }

        do {
            var fetched: [CloudModelOption] = []
            var after: String?
            for _ in 0..<5 {
                var components = URLComponents(string: "https://api.anthropic.com/v1/models")!
                var items = [URLQueryItem(name: "limit", value: "100")]
                if let after {
                    items.append(URLQueryItem(name: "after_id", value: after))
                }
                components.queryItems = items

                var request = URLRequest(url: components.url!)
                request.setValue(key, forHTTPHeaderField: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                request.timeoutInterval = 20
                let (data, response) = try await URLSession.shared.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                guard (200..<300).contains(code) else {
                    throw PolisherError.http(code, String(data: data, encoding: .utf8) ?? "")
                }
                let page = try Self.parseAnthropicModelsPage(from: data)
                fetched.append(contentsOf: page.models)
                guard page.hasMore, let last = page.lastID, last != after else { break }
                after = last
            }

            let unique = fetched.uniquedByID()
            let labeled = unique.map { option in
                Self.anthropicRecommended.first(where: { $0.id == option.id }) ?? option
            }
            let merged = Self.mergeForPicker(recommended: Self.anthropicRecommended, fetched: labeled)
            if merged.isEmpty {
                anthropicStatus = "No models on this key. Showing recommended list."
                return
            }
            anthropicModels = merged
            Self.saveCache(merged, key: Self.anthropicCacheKey)
            anthropicStatus = "Updated \(merged.count) models from Anthropic."
        } catch {
            anthropicStatus = "Could not update Anthropic models: \(error.localizedDescription)"
        }
    }

    // MARK: - Parsing / filters (unit-tested)

    nonisolated static func isOpenAIChatModel(_ id: String) -> Bool {
        let model = id.lowercased()
        let blocked = [
            "whisper", "tts", "dall-e", "dalle", "embedding", "moderation",
            "transcribe", "realtime", "sora", "image", "audio", "computer-use",
            "babbage", "davinci", "codex", "search", "gpt-realtime"
        ]
        if blocked.contains(where: { model.contains($0) }) { return false }
        return model.hasPrefix("gpt-")
            || model.hasPrefix("o1")
            || model.hasPrefix("o3")
            || model.hasPrefix("o4")
            || model.hasPrefix("chatgpt-")
    }

    /// Reasoning models and GPT-5 onwards answer `temperature` with a 400 — "Only
    /// the default (1) value is supported". The rule was once `hasPrefix("gpt-5")`,
    /// so GPT-6 Luna failed every take for anyone who picked it from the fetched
    /// list. Newer families are assumed to be the same, as with Claude, and
    /// anything this rule gets wrong is caught by the retry in OpenAIPolisher.
    nonisolated static func supportsChatTemperature(_ model: String) -> Bool {
        let model = model.lowercased()
        if model.hasPrefix("o1") || model.hasPrefix("o3") || model.hasPrefix("o4") { return false }
        return (gptMajorVersion(model) ?? 0) < 5
    }

    /// 6 for gpt-6-luna, 5 for gpt-5.6-luna, 4 for gpt-4o and gpt-4.1-mini, nil for
    /// anything that does not name its family that way.
    nonisolated static func gptMajorVersion(_ model: String) -> Int? {
        let model = model.lowercased()
        guard model.hasPrefix("gpt-") else { return nil }
        return Int(model.dropFirst(4).prefix { $0.isNumber })
    }

    /// The field a 400 complained about, when it is one the request can simply drop
    /// and still get a cleaned transcript back. Nil for every other bad request.
    /// Both providers use it: each names the field in its own words.
    nonisolated static func rejectedField(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8)?.lowercased() else { return nil }
        let complaint = text.contains("deprecated") || text.contains("not supported")
            || text.contains("unsupported") || text.contains("unexpected")
        guard complaint else { return nil }
        if text.contains("temperature") { return "temperature" }
        if text.contains("thinking") { return "thinking" }
        if text.contains("seed") { return "seed" }
        return nil
    }

    /// Claude 5 rejects `temperature` outright — "`temperature` is deprecated for
    /// this model" — so sending it failed every single take for anyone who picked
    /// Sonnet 5 or Opus 5. Newer families are assumed to be the same; anything
    /// this rule gets wrong is caught by the retry in AnthropicPolisher.
    nonisolated static func supportsMessagesTemperature(_ model: String) -> Bool {
        (claudeMajorVersion(model) ?? 0) < 5
    }

    /// Claude 5 thinks before answering unless told not to. Cleaning a transcript
    /// is not a reasoning task, and thinking tokens count against `max_tokens`,
    /// so a long take could spend its whole budget thinking and come back cut
    /// short — the cleanup lost, the raw text pasted instead.
    nonisolated static func thinksByDefault(_ model: String) -> Bool {
        (claudeMajorVersion(model) ?? 0) >= 5
    }

    /// 5 for claude-sonnet-5, 4 for claude-haiku-4-5, nil for anything that does
    /// not name its family that way — including claude-3-5-haiku, where the
    /// version comes first.
    nonisolated static func claudeMajorVersion(_ model: String) -> Int? {
        let model = model.lowercased()
        guard let name = model.range(of: #"^claude-(?:opus|sonnet|haiku)-"#, options: .regularExpression) else {
            return nil
        }
        return Int(model[name.upperBound...].prefix { $0.isNumber })
    }

    nonisolated static func prettyDisplayName(for id: String) -> String {
        id.split(separator: "-")
            .map { part -> String in
                let token = String(part)
                if token.allSatisfy(\.isNumber) || token.contains(".") { return token.uppercased() }
                if token.lowercased() == "gpt" { return "GPT" }
                return token.prefix(1).uppercased() + token.dropFirst()
            }
            .joined(separator: " ")
    }

    /// Recommended IDs that the account actually has, then the rest of the fetched list.
    nonisolated static func mergeForPicker(
        recommended: [CloudModelOption],
        fetched: [CloudModelOption]
    ) -> [CloudModelOption] {
        let fetchedByID = Dictionary(fetched.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        var result: [CloudModelOption] = []
        for rec in recommended {
            guard fetchedByID[rec.id] != nil else { continue }
            if seen.insert(rec.id).inserted {
                result.append(rec)
            }
        }
        for option in fetched.sorted(by: { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }) {
            if seen.insert(option.id).inserted {
                result.append(option)
            }
        }
        return result
    }

    nonisolated static func parseOpenAIModelIDs(from data: Data) throws -> [String] {
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let list = json["data"] as? [[String: Any]]
        else {
            throw PolisherError.emptyResponse
        }
        return list.compactMap { $0["id"] as? String }
    }

    nonisolated static func parseAnthropicModelsPage(from data: Data) throws -> AnthropicModelsPage {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PolisherError.emptyResponse
        }
        let list = json["data"] as? [[String: Any]] ?? []
        let models: [CloudModelOption] = list.compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            let name = (item["display_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let display = (name?.isEmpty == false) ? name! : prettyDisplayName(for: id)
            return CloudModelOption(id: id, displayName: display)
        }
        let hasMore = json["has_more"] as? Bool ?? false
        let lastID = json["last_id"] as? String ?? models.last?.id
        return AnthropicModelsPage(models: models, hasMore: hasMore, lastID: lastID)
    }

    func displayName(for id: String, in options: [CloudModelOption]) -> String {
        options.first(where: { $0.id == id })?.displayName ?? id
    }

    private static func loadCache(key: String) -> [CloudModelOption]? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode([CloudModelOption].self, from: data)
    }

    private static func saveCache(_ models: [CloudModelOption], key: String) {
        if let data = try? JSONEncoder().encode(models) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

struct AnthropicModelsPage: Sendable {
    let models: [CloudModelOption]
    let hasMore: Bool
    let lastID: String?

    var ids: [String] { models.map(\.id) }
}

private extension Array where Element == CloudModelOption {
    func uniquedByID() -> [CloudModelOption] {
        var seen = Set<String>()
        return filter { seen.insert($0.id).inserted }
    }
}
