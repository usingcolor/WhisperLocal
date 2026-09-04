import Combine
import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

enum GemmaMLXStatus: Equatable {
    case idle
    case downloading(Double)
    case loading
    case ready
    case failed(String)

    var isWorking: Bool {
        switch self {
        case .downloading, .loading: return true
        default: return false
        }
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// On-device polish via Gemma 4 E2B IT (MLX, 4-bit, ~2.7 GB).
/// Uses the community text-only checkpoint — vision and audio towers are not downloaded.
/// First use downloads from Hugging Face; stays local after that.
final class GemmaMLXPolisher: ObservableObject, TextPolisher, @unchecked Sendable {
    static let shared = GemmaMLXPolisher()

    /// Text-only extract (`model_type: gemma4_text`). Not `mlx-community/gemma-4-e2b-it-4bit`,
    /// which is the multimodal VLM conversion.
    static let huggingFaceID = "mlx-community/Gemma4-E2B-IT-Text-int4"

    let name = "Gemma 4 E2B"

    @Published private(set) var status: GemmaMLXStatus = .idle
    @Published private(set) var statusMessage = GemmaMLXPolisher.idleMessage

    var isReady: Bool {
        if case .ready = status { return true }
        return false
    }

    private let loader = Loader()
    private let generateTimeout: TimeInterval = PolishTimeouts.gemma

    private static let idleMessage =
        "Gemma 4 E2B IT is not loaded. Select it to download ~2.7 GB (MLX, on-device, text-only)."

    private init() {}

    func prewarm() {
        Task { _ = try? await ensureLoaded() }
    }

    func unload() {
        Task {
            await loader.reset()
            await publish(status: .idle, message: Self.idleMessage)
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
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return PolishedText(text: trimmed) }

        let model = try await ensureLoaded()
        let system = CleanupPrompt.system(
            for: task,
            dictionary: dictionary,
            personalContext: personalContext,
            onDevice: true
        )
        let user = CleanupPrompt.userMessage(
            for: task,
            text: trimmed,
            targetApp: targetApp,
            personalContext: personalContext,
            recentDictations: recentDictations,
            sessionIntent: sessionIntent,
            onDevice: true,
            part: part
        )
        let maxTokens = task == .sessionContext
            ? min(Self.tokenBudget(for: trimmed), 128)
            : Self.tokenBudget(for: trimmed)
        let timeout = generateTimeout

        do {
            let raw = try await withTimeout(timeout) {
                let userInput = UserInput(chat: [
                    .system(system),
                    .user(user)
                ])
                let lmInput = try await model.prepare(input: userInput)
                let parameters = GenerateParameters(maxTokens: maxTokens, temperature: 0)
                let stream = try await model.generate(input: lmInput, parameters: parameters)
                let deadline = Date().addingTimeInterval(timeout)
                let charCap = task == .sessionContext
                    ? SessionContext.maxCharacters + 40
                    : trimmed.count * 3 + 80
                var output = ""
                var sawEndOfTurn = false
                var generatedTokens = 0
                for await event in stream {
                    if Date() > deadline {
                        throw PolisherError.notAvailable("On-device polish timed out.")
                    }
                    switch event {
                    case .chunk(let chunk):
                        output += chunk
                        if output.contains("<end_of_turn>") {
                            sawEndOfTurn = true
                            return output
                        }
                        if output.count > charCap {
                            throw PolisherError.truncated
                        }
                    case .info(let info):
                        generatedTokens = info.generationTokenCount
                    case .toolCall:
                        break
                    }
                }
                if !sawEndOfTurn, generatedTokens >= maxTokens {
                    throw PolisherError.truncated
                }
                return output
            }
            let sanitized = PolishOutput.sanitize(raw)
            guard !sanitized.isEmpty else { throw PolisherError.emptyResponse }
            return PolishedText(text: sanitized)
        } catch is CancellationError {
            throw PolisherError.notAvailable("On-device polish timed out.")
        } catch let error as PolisherError {
            throw error
        } catch {
            throw PolisherError.notAvailable(error.localizedDescription)
        }
    }

    // MARK: - Load

    private func ensureLoaded() async throws -> ModelContainer {
        try await loader.get { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.loadModel()
        }
    }

    private func loadModel() async throws -> ModelContainer {
        await publish(status: .downloading(0), message: "Downloading Gemma 4 E2B IT (~2.7 GB)…")

        let configuration = ModelConfiguration(
            id: Self.huggingFaceID,
            extraEOSTokens: ["<end_of_turn>", "<eos>"]
        )

        do {
            let container = try await LLMModelFactory.shared.loadContainer(
                from: #hubDownloader(),
                using: #huggingFaceTokenizerLoader(),
                configuration: configuration
            ) { [weak self] progress in
                let fraction = progress.fractionCompleted
                Task { @MainActor in
                    guard let self else { return }
                    if fraction < 1 {
                        self.status = .downloading(fraction)
                        self.statusMessage = "Downloading Gemma 4 E2B IT… \(Int(fraction * 100))% (~2.7 GB)"
                    } else {
                        self.status = .loading
                        self.statusMessage = "Loading Gemma 4 E2B IT into memory…"
                    }
                }
            }
            try Task.checkCancellation()
            await publish(status: .loading, message: "Compiling Gemma 4 E2B IT (once)…")
            try? await Self.warmup(container)
            try Task.checkCancellation()
            await publish(
                status: .ready,
                message: "Gemma 4 E2B IT ready. Later dictations should take a few seconds."
            )
            return container
        } catch is CancellationError {
            await publish(status: .idle, message: Self.idleMessage)
            throw CancellationError()
        } catch {
            let message = Self.friendlyLoadError(error)
            await publish(status: .failed(message), message: message)
            throw PolisherError.notAvailable(message)
        }
    }

    @MainActor
    private func publish(status: GemmaMLXStatus, message: String) {
        self.status = status
        self.statusMessage = message
    }

    /// Dictation output should stay close to the input length. A high cap lets a missed EOS run for seconds.
    private static func tokenBudget(for text: String) -> Int {
        let words = text.split { $0.isWhitespace || $0.isNewline }.count
        return min(max(words * 2 + 32, 64), 1024)
    }

    /// First generate compiles Metal kernels. Do that at load time, not during a dictation.
    private static func warmup(_ container: ModelContainer) async throws {
        let lmInput = try await container.prepare(input: UserInput(chat: [.user("ok")]))
        let stream = try await container.generate(
            input: lmInput,
            parameters: GenerateParameters(maxTokens: 1, temperature: 0)
        )
        for await _ in stream { break }
    }

    private static func friendlyLoadError(_ error: Error) -> String {
        let raw = error.localizedDescription
        let lower = raw.lowercased()
        if lower.contains("401") || lower.contains("403") || lower.contains("gated")
            || lower.contains("unauthorized") {
            return "Gemma download was denied. Accept Google’s Gemma license at huggingface.co/google/gemma-4-E2B-it, then retry. If the Hub still blocks it, set HF_TOKEN."
        }
        if lower.contains("network") || lower.contains("offline") || lower.contains("internet")
            || lower.contains("timed out") || lower.contains("not connected") {
            return "Couldn’t download Gemma 4 E2B IT. Check the network and retry (~2.7 GB)."
        }
        return "Gemma 4 E2B IT failed to load: \(raw)"
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

private actor Loader {
    private var container: ModelContainer?
    private var inFlight: Task<ModelContainer, Error>?

    func get(load: @escaping @Sendable () async throws -> ModelContainer) async throws -> ModelContainer {
        if let container {
            return container
        }
        if let inFlight {
            return try await inFlight.value
        }
        let task = Task { try await load() }
        inFlight = task
        do {
            let loaded = try await task.value
            container = loaded
            inFlight = nil
            return loaded
        } catch {
            inFlight = nil
            throw error
        }
    }

    func reset() {
        inFlight?.cancel()
        inFlight = nil
        container = nil
    }
}
