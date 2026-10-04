import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Keeps automatic context: asked after each paste how the take changes the
/// topics. See `AutoContext` for the rules its answer is held to.
protocol AutoContextUpdater: Sendable {
    /// `now` is when the take was pasted, which says how long ago each topic
    /// was last used.
    func answer(topics: [AutoContext.Topic], take: String, targetApp: String?, now: Date) async throws -> AutoContextAnswer
}

struct AutoContextAnswer: Sendable {
    /// Nil when the answer said nothing usable.
    let change: AutoContext.Change?
    /// The model's own words — its reply, or a fixed-shape answer written as
    /// the tag it stands for — for the context benchmark to show.
    let raw: String
}

/// The cloud model that polishes, asked in a request of its own.
struct CloudContextUpdater: AutoContextUpdater {
    let model: any CloudAsking

    func answer(topics: [AutoContext.Topic], take: String, targetApp: String?, now: Date) async throws -> AutoContextAnswer {
        let reply = try await model.ask(
            system: CleanupPrompt.autoContextSystem,
            user: CleanupPrompt.autoContextMessage(topics: topics, take: take, targetApp: targetApp, now: now)
        )
        return AutoContextAnswer(
            change: AutoContext.change(fromTag: CleanupPrompt.lastContextTag(in: reply)),
            raw: reply
        )
    }
}

/// Apple Intelligence on this Mac, with a prompt of its own. It fills in a
/// fixed shape instead of writing a line, so the ~3B model cannot leave the
/// answer out or garble it; see `AutoContext.change(names:in:topics:)` for
/// what it is asked and what the app makes of the answer.
struct AppleIntelligenceContextUpdater: AutoContextUpdater {
    static var isAvailable: Bool { LocalLLMPolisher.isAvailable }

    func answer(topics: [AutoContext.Topic], take: String, targetApp: String?, now: Date) async throws -> AutoContextAnswer {
        let names = try await Self.names(in: take)
        let change = AutoContext.change(names: names, in: take, topics: topics.map(\.text))
        // The tag first, as a cloud reply would have it; what it said after.
        return AutoContextAnswer(change: change, raw: change.tag + "\nnames: " + names.joined(separator: " | "))
    }

    /// All the model is asked: the names in the take, as it gives them.
    static func names(in take: String) async throws -> [String] {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return try await AppleContextKeeper.names(in: take)
        }
        #endif
        throw PolisherError.notAvailable(LocalLLMPolisher.statusMessage)
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable
private struct TakeNames {
    @Guide(description: "Names in the take, spelled exactly as in the take: people, projects, products, papers, documents and places called by their own names. Often none.", .maximumCount(4))
    var names: [String]
}

@available(macOS 26.0, *)
private enum AppleContextKeeper {
    private static let deadline = DeadlineExecutor()
    static func names(in take: String) async throws -> [String] {
        guard SystemLanguageModel.default.isAvailable else {
            throw PolisherError.notAvailable(LocalLLMPolisher.statusMessage)
        }
        let session = LanguageModelSession(
            model: SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations),
            instructions: CleanupPrompt.appleAutoContextInstructions
        )
        let prompt = CleanupPrompt.appleAutoContextMessage(take: take)
        return try await firstOf(seconds: PolishTimeouts.appleIntelligence) {
            try await session.respond(
                to: prompt,
                generating: TakeNames.self,
                options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 120)
            ).content.names
        }
    }

    /// The answer, or an error once `seconds` pass — whichever comes first. A
    /// task group would wait for the call it gave up on, and an on-device call
    /// has been seen to ignore cancellation for ten minutes; every update queued
    /// behind it would wait that long too.
    private static func firstOf<T: Sendable>(
        seconds: TimeInterval, _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await deadline.run(seconds: seconds, operation: work)
    }
}

#endif
