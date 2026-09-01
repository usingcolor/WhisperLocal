import Foundation

struct OpenAIPolisher: TextPolisher {
    let name = "OpenAI"
    let apiKey: String
    let model: String

    func polish(
        _ text: String,
        dictionary: [String],
        personalContext: String = "",
        targetApp: String? = nil,
        recentDictations: String = "",
        sessionIntent: String = "",
        task: PolishTask = .dictation
    ) async throws -> PolishedText {
        guard !apiKey.isEmpty else { throw PolisherError.missingAPIKey("OpenAI") }

        let system = CleanupPrompt.system(
            for: task,
            dictionary: dictionary,
            personalContext: personalContext
        )

        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": CleanupPrompt.userMessage(
                    for: task,
                    text: text,
                    targetApp: targetApp,
                    recentDictations: recentDictations,
                    sessionIntent: sessionIntent
                )]
            ]
        ]
        if CloudModelCatalog.supportsChatTemperature(model) {
            body["temperature"] = 0.2
        }

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
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
        let choices = json?["choices"] as? [[String: Any]]
        if PolishOutput.openaiHitLengthCap(choices?.first?["finish_reason"] as? String) {
            throw PolisherError.truncated
        }
        let message = choices?.first?["message"] as? [String: Any]
        let content = (message?["content"] as? String).map(PolishOutput.sanitize)
        guard let content, !content.isEmpty else { throw PolisherError.emptyResponse }
        return PolishedText(text: content)
    }
}
