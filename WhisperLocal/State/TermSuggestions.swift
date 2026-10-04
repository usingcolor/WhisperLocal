import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Dictionary words suggested from the dictation log, for the person to add,
/// respell or dismiss. Dev-only while it is tried.
///
/// The on-device model runs when the Dictionary page is opened, never during a
/// take, and is asked about each word once: its answers are kept, so opening
/// the page again costs nothing until new words turn up.
@MainActor
final class TermSuggestionStore: ObservableObject {
    static let shared = TermSuggestionStore()

    static var isEnabled: Bool { AppIdentity.isDevBuild }

    enum Status: Equatable {
        case idle
        case checking(Int)
        case ready
        case unavailable(String)
        case failed(String)
    }

    @Published private(set) var suggestions: [TermCandidate] = []
    @Published private(set) var status: Status = .idle

    /// The model's answer for each word it has been asked about.
    private var verdicts: [String: Bool]
    /// Words added or dismissed from here. Kept because a word added under a
    /// corrected spelling would otherwise come straight back.
    private var handled: Set<String>
    private var isRefreshing = false

    private static let verdictsKey = "termSuggestionVerdicts"
    private static let handledKey = "termSuggestionsHandled"
    /// Words per question. 35 took 2.8 s on an M2 Air.
    private static let batchSize = 40

    private init() {
        let defaults = UserDefaults.standard
        verdicts = defaults.dictionary(forKey: Self.verdictsKey) as? [String: Bool] ?? [:]
        handled = Set(defaults.stringArray(forKey: Self.handledKey) ?? [])
    }

    func refresh() async {
        guard Self.isEnabled, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let candidates = TermCandidates.collect(
            from: DictationLogStore.shared.entries,
            knownText: Self.knownText(SettingsStore.shared),
            handled: handled
        )
        let unjudged = candidates.filter { verdicts[$0.id] == nil }
        if !unjudged.isEmpty {
            guard TermJudge.isAvailable else {
                publish(candidates)
                status = .unavailable(LocalLLMPolisher.statusMessage)
                return
            }
            status = .checking(unjudged.count)
            var start = 0
            while start < unjudged.count {
                let batch = Array(unjudged[start..<min(start + Self.batchSize, unjudged.count)])
                start += Self.batchSize
                do {
                    let kept = try await TermJudge.pick(from: batch)
                    for candidate in batch {
                        verdicts[candidate.id] = kept.contains(candidate.id)
                    }
                    UserDefaults.standard.set(verdicts, forKey: Self.verdictsKey)
                } catch {
                    publish(candidates)
                    status = .failed(error.localizedDescription)
                    return
                }
            }
        }
        publish(candidates)
        status = .ready
    }

    /// Adds the word under the spelling given, to every app or to one.
    func add(_ candidate: TermCandidate, spelling: String, toApp appName: String?) {
        let word = spelling.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return }
        let settings = SettingsStore.shared
        if let appName {
            let key = appName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let entry = settings.appDictionaries.first(where: {
                $0.appName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == key
            }) {
                settings.addAppDictionaryTerm(id: entry.id, raw: word)
            } else {
                settings.addAppDictionary(AppDictionaryEntry(appName: appName, terms: [word]))
            }
        } else {
            settings.addDictionaryWord(word)
        }
        markHandled(candidate)
    }

    func dismiss(_ candidate: TermCandidate) {
        markHandled(candidate)
    }

    private func markHandled(_ candidate: TermCandidate) {
        handled.insert(candidate.id)
        UserDefaults.standard.set(Array(handled).sorted(), forKey: Self.handledKey)
        suggestions.removeAll { $0.id == candidate.id }
    }

    private func publish(_ candidates: [TermCandidate]) {
        suggestions = candidates.filter { verdicts[$0.id] == true }
    }

    /// Everything the app already knows how to spell: both dictionaries and the
    /// system prompt.
    private static func knownText(_ settings: SettingsStore) -> String {
        ([settings.cleanupPersonalContext] + settings.dictionaryWords + settings.appDictionaries.flatMap(\.terms))
            .joined(separator: " ")
    }
}

/// Asks the on-device model which candidates are worth teaching a recogniser.
///
/// Asked for the words to keep, not a yes or no per word: individual verdicts
/// tended to accept ordinary capitalised words during evaluation, while asking
/// for a list was more selective. It
/// cannot tell a real term from a mishearing that looks like one, and is not
/// asked to; that is what respelling in Settings is for.
enum TermJudge {
    static var isAvailable: Bool { LocalLLMPolisher.isAvailable }

    private static let deadline = DeadlineExecutor()

    static func pick(from candidates: [TermCandidate]) async throws -> Set<String> {
        guard !candidates.isEmpty else { return [] }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return try await deadline.run(seconds: 30) {
                try await AppleTermJudge.pick(from: candidates)
            }
        }
        #endif
        throw PolisherError.notAvailable(LocalLLMPolisher.statusMessage)
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable
private struct TermPicks {
    @Guide(description: "Only the listed terms that a general-purpose speech recogniser would probably misspell. Usually a small minority of the list, often none.")
    var terms: [String]
}

@available(macOS 26.0, *)
private enum AppleTermJudge {
    static let instructions = """
        You pick words for a speech recogniser's custom vocabulary from someone's dictated notes. \
        A word belongs there only if a general-purpose recogniser would probably misspell it: \
        uncommon personal names, niche project, paper, product or model names, unusual acronyms. \
        Ordinary English words do not, even when capitalised, and neither do names and acronyms \
        everyone knows. Return only the terms that belong there.
        """

    static func pick(from candidates: [TermCandidate]) async throws -> Set<String> {
        let listing = candidates
            .map { "- \($0.form): \"\($0.example)\"" }
            .joined(separator: "\n")
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(
            to: "Terms, each with a sentence it appeared in:\n\(listing)",
            generating: TermPicks.self,
            options: GenerationOptions(sampling: .greedy)
        )
        // It sometimes names a word from an example sentence that was never
        // listed. Only listed words count.
        let listed = Set(candidates.map(\.id))
        return Set(response.content.terms.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }).intersection(listed)
    }
}
#endif
