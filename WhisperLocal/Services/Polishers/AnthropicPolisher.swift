import Foundation

struct AnthropicPolisher: TextPolisher {
    let name = "Anthropic"
    let apiKey: String
    let model: String

    func polish(
        _ text: String,
        dictionary: [String],
        personalContext: String = "",
        targetApp: String? = nil
    ) async throws -> String {
        guard !apiKey.isEmpty else { throw PolisherError.missingAPIKey("Anthropic") }

        let system = CleanupPrompt.system(dictionary: dictionary, personalContext: personalContext)

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "temperature": 0.2,
            "system": system,
            "messages": [
                ["role": "user", "content": CleanupPrompt.wrapTranscript(text, targetApp: targetApp)]
            ]
        ]

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(code) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw PolisherError.http(code, bodyText)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let contentBlocks = json?["content"] as? [[String: Any]]
        let textBlock = contentBlocks?.first(where: { ($0["type"] as? String) == "text" })
        let content = (textBlock?["text"] as? String).map(PolishOutput.sanitize)
        guard let content, !content.isEmpty else { throw PolisherError.emptyResponse }
        return content
    }
}
