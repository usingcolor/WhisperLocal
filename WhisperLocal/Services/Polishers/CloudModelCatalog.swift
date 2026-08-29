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
    /// IDs match OpenAI’s API (`gpt-5.6-luna` / `-terra` / `-sol`).
    static let openAIRecommended: [CloudModelOption] = [
        CloudModelOption(id: "gpt-5.6-luna", displayName: "GPT-5.6 Luna", note: "fast / cheap"),
        CloudModelOption(id: "gpt-5.6-terra", displayName: "GPT-5.6 Terra", note: "balanced"),
        CloudModelOption(id: "gpt-5.6-sol", displayName: "GPT-5.6 Sol", note: "highest quality"),
        CloudModelOption(id: "gpt-4.1-mini", displayName: "GPT-4.1 Mini", note: "fast"),
        CloudModelOption(id: "gpt-4.1", displayName: "GPT-4.1", note: "quality"),
        CloudModelOption(id: "gpt-4o-mini", displayName: "GPT-4o Mini", note: "fast"),
        CloudModelOption(id: "gpt-4o", displayName: "GPT-4o", note: "quality")
    ]

    static let anthropicRecommended: [CloudModelOption] = [
        CloudModelOption(id: "claude-haiku-4-5", displayName: "Claude Haiku 4.5", note: "fast / cheap"),
        CloudModelOption(id: "claude-sonnet-5", displayName: "Claude Sonnet 5", note: "balanced"),
        CloudModelOption(id: "claude-opus-5", displayName: "Claude Opus 5", note: "highest quality"),
        CloudModelOption(id: "claude-sonnet-4-5", displayName: "Claude Sonnet 4.5"),
        CloudModelOption(id: "claude-3-5-haiku-latest", displayName: "Claude 3.5 Haiku", note: "legacy")
    ]

    static let openAIDefault = "gpt-4o-mini"
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

    /// Reasoning / GPT-5 snapshots often reject `temperature` on chat completions.
    nonisolated static func supportsChatTemperature(_ model: String) -> Bool {
        let model = model.lowercased()
        if model.hasPrefix("o1") || model.hasPrefix("o3") || model.hasPrefix("o4") { return false }
        if model.hasPrefix("gpt-5") { return false }
        return true
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
