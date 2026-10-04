import Foundation

struct OpenAIPolisher: TextPolisher, CloudAsking {
    let name = "OpenAI"
    let apiKey: String
    let model: String
    /// Asks OpenAI for repeatable sampling. The app never sets it; the context
    /// benchmark does, so a difference between two runs is the change being
    /// tested rather than the model's own variation.
    var seed: Int? = nil

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
        let (reply, json) = try await complete(
            system: CleanupPrompt.system(
                for: task,
                dictionary: dictionary,
                personalContext: personalContext
            ),
            user: CleanupPrompt.userMessage(
                for: task,
                text: text,
                targetApp: targetApp,
                recentDictations: recentDictations,
                sessionIntent: sessionIntent,
                part: part,
                language: language
            )
        )
        let content = reply.map(PolishOutput.sanitize)
        guard let content, !content.isEmpty else { throw PolisherError.emptyResponse }
        return PolishedText(text: content, usage: PolishUsage.openAI(json?["usage"] as? [String: Any]))
    }

    func ask(system: String, user: String) async throws -> String {
        let reply = try await complete(system: system, user: user).reply?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let reply, !reply.isEmpty else { throw PolisherError.emptyResponse }
        return reply
    }

    /// One Chat Completions request with this key and model.
    private func complete(system: String, user: String) async throws -> (reply: String?, json: [String: Any]?) {
        guard !apiKey.isEmpty else { throw PolisherError.missingAPIKey("OpenAI") }

        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ]
        ]
        if CloudModelCatalog.supportsChatTemperature(model) {
            body["temperature"] = 0.2
        }
        if let seed {
            body["seed"] = seed
        }

        var (data, code) = try await send(body)
        // A model released after this build may reject what the catalog still
        // sends, which would fail every take. Drop the field the error names and
        // ask once more, as AnthropicPolisher does.
        if code == 400, let field = CloudModelCatalog.rejectedField(data), body[field] != nil {
            body.removeValue(forKey: field)
            (data, code) = try await send(body)
        }
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
        return (message?["content"] as? String, json)
    }

    private func send(_ body: [String: Any]) async throws -> (Data, Int) {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = PolishTimeouts.cloud
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? -1)
    }
}
