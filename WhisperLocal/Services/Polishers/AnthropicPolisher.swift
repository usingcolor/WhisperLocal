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
        task: PolishTask = .dictation
    ) async throws -> PolishedText {
        guard !apiKey.isEmpty else { throw PolisherError.missingAPIKey("Anthropic") }

        let system = CleanupPrompt.system(
            for: task,
            dictionary: dictionary,
            personalContext: personalContext
        )

        // Explicit breakpoint on the system prompt only. Top-level automatic cache_control
        // would mark the unique transcript and miss on every take.
        let body: [String: Any] = [
            "model": model,
            "max_tokens": PolishOutput.maxOutputTokens(for: text),
            "temperature": 0.2,
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
                    sessionIntent: sessionIntent
                )]
            ]
        ]

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = PolishTimeouts.cloud

        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
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
        return PolishedText(text: content)
    }

    private func logCacheUsage(_ usage: [String: Any]?) {
        let created = intValue(usage?["cache_creation_input_tokens"])
        let read = intValue(usage?["cache_read_input_tokens"])
        let input = intValue(usage?["input_tokens"])
        Self.logger.info(
            "Anthropic cache write=\(created, privacy: .public) read=\(read, privacy: .public) input=\(input, privacy: .public) model=\(self.model, privacy: .public)"
        )
    }

    private func intValue(_ value: Any?) -> Int {
        if let number = value as? Int { return number }
        if let number = value as? NSNumber { return number.intValue }
        return 0
    }
}
