import Foundation
import os

struct AnthropicPolisher: TextPolisher {
    let name = "Anthropic"
    let apiKey: String
    let model: String

    private static let logger = Logger(subsystem: AppIdentity.keychainService, category: "anthropic")

    func polish(
        _ text: String,
        dictionary: [String],
        personalContext: String = "",
        targetApp: String? = nil,
        recentDictations: String = "",
        sessionIntent: String = "",
        task: PolishTask = .dictation,
        part: CleanupPrompt.TranscriptPart? = nil,
        language: SpokenLanguage? = nil
    ) async throws -> PolishedText {
        guard !apiKey.isEmpty else { throw PolisherError.missingAPIKey("Anthropic") }

        let system = CleanupPrompt.system(
            for: task,
            dictionary: dictionary,
            personalContext: personalContext
        )

        // Explicit breakpoint on the system prompt only. Top-level automatic cache_control
        // would mark the unique transcript and miss on every take.
        var body: [String: Any] = [
            "model": model,
            "max_tokens": PolishOutput.maxOutputTokens(for: text),
            "system": [
                [
                    "type": "text",
                    "text": system,
                    "cache_control": ["type": "ephemeral"]
                ]
            ],
            "messages": [
                ["role": "user", "content": CleanupPrompt.userMessage(
                    for: task,
                    text: text,
                    targetApp: targetApp,
                    recentDictations: recentDictations,
                    sessionIntent: sessionIntent,
                    part: part,
                    language: language
                )]
            ]
        ]
        if CloudModelCatalog.supportsMessagesTemperature(model) {
            body["temperature"] = 0.2
        }
        if CloudModelCatalog.thinksByDefault(model) {
            body["thinking"] = ["type": "disabled"]
        }

        var (data, code) = try await send(body)
        // Claude 5 answers "`temperature` is deprecated for this model" with a 400.
        // The catalog knows which families reject what, but a model released after
        // this build would otherwise fail every take, so drop the field the error
        // names and ask once more.
        if code == 400, let field = Self.rejectedField(data), body[field] != nil {
            Self.logger.info("Retrying \(self.model, privacy: .public) without \(field, privacy: .public)")
            body.removeValue(forKey: field)
            (data, code) = try await send(body)
        }
        guard (200..<300).contains(code) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw PolisherError.http(code, bodyText)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if PolishOutput.anthropicHitTokenCap(json?["stop_reason"] as? String) {
            throw PolisherError.truncated
        }
        logCacheUsage(json?["usage"] as? [String: Any])
        let contentBlocks = json?["content"] as? [[String: Any]]
        let textBlock = contentBlocks?.first(where: { ($0["type"] as? String) == "text" })
        let content = (textBlock?["text"] as? String).map(PolishOutput.sanitize)
        guard let content, !content.isEmpty else { throw PolisherError.emptyResponse }
        return PolishedText(text: content, usage: PolishUsage.anthropic(json?["usage"] as? [String: Any]))
    }

    private func send(_ body: [String: Any]) async throws -> (Data, Int) {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = PolishTimeouts.cloud
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? -1)
    }

    /// The field a 400 complained about, when it is one the request can simply drop
    /// and still get a cleaned transcript back. Nil for every other bad request.
    static func rejectedField(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8)?.lowercased() else { return nil }
        let complaint = text.contains("deprecated") || text.contains("not supported")
            || text.contains("unsupported") || text.contains("unexpected")
        guard complaint else { return nil }
        if text.contains("temperature") { return "temperature" }
        if text.contains("thinking") { return "thinking" }
        return nil
    }

    private func logCacheUsage(_ usage: [String: Any]?) {
        let created = PolishUsage.intValue(usage?["cache_creation_input_tokens"])
        let read = PolishUsage.intValue(usage?["cache_read_input_tokens"])
        let input = PolishUsage.intValue(usage?["input_tokens"])
        Self.logger.info(
            "Anthropic cache write=\(created, privacy: .public) read=\(read, privacy: .public) input=\(input, privacy: .public) model=\(self.model, privacy: .public)"
        )
    }
}
