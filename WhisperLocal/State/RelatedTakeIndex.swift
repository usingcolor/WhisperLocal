import Accelerate
import Foundation
import NaturalLanguage

/// The dictation log, indexed for `RelatedTakeScoring`: each take's words and,
/// for a take in Latin script, its contextual embedding.
///
/// `NLContextualEmbedding`, not `NLEmbedding.sentenceEmbedding`. The contextual
/// model ranked related terms more reliably during evaluation, ships with
/// macOS, and costs about 13 MB. A larger multilingual model costs about 390 MB.
///
/// Korean, Japanese and Chinese take a separate contextual model whose scores
/// sit on a different scale, and there are too few evaluated takes to set
/// thresholds for it. So those takes are
/// matched on words alone for now, and never through the Latin model.
///
/// Dev-only while it is tried. Built in memory from the log at launch and kept
/// in step as takes are added — about 11 ms a take, off the main thread, so
/// 5,000 takes is about a minute of background work per launch. Worth a file on
/// disk if the trial is kept; not before.
actor RelatedTakeIndex {
    static let shared = RelatedTakeIndex()

    static var isEnabled: Bool { AppIdentity.isDevBuild }

    private struct Item {
        let id: UUID
        let date: Date
        let words: Set<String>
        let terms: Set<String>
        let vector: [Float]?
        let norm: Float
        /// Latin script, and indexed while the model could not be used. Embedded
        /// once it can be, rather than going without for the rest of the launch.
        let awaitingVector: Bool
        let appName: String?
        let language: String
    }

    private var items: [UUID: Item] = [:]
    private var documentFrequency: [String: Int] = [:]
    /// Bumped by every refresh, so one still indexing an older log gives up
    /// rather than putting back takes a newer one removed.
    private var generation = 0
    private var latinModel: NLContextualEmbedding?
    private var modelState = ModelState.unknown

    private enum ModelState {
        case unknown
        /// macOS is fetching the model's files; takes go without vectors until then.
        case downloading
        case ready
        case unavailable
    }

    /// Brings the index in line with the log as it is now. Reads the log itself
    /// rather than taking a copy, so refreshes that finish out of order still
    /// leave the latest state behind.
    func refresh() async {
        generation += 1
        let mine = generation
        let entries = await MainActor.run { DictationLogStore.shared.entries }
        guard mine == generation else { return }

        let wasReady = modelState == .ready
        await prepareModel()
        guard mine == generation else { return }

        let usable = entries.filter(Self.isUsable)
        let keep = Set(usable.map(\.id))
        for id in items.keys where !keep.contains(id) {
            remove(id)
        }
        if !wasReady, modelState == .ready {
            for (id, item) in items where item.awaitingVector {
                remove(id)
            }
        }
        for entry in usable {
            guard mine == generation else { return }
            guard items[entry.id] == nil else { continue }
            add(entry)
            // Lets a take being polished ask for matches between two of these,
            // instead of waiting out a whole launch's worth of indexing.
            await Task.yield()
        }
    }

    func related(
        to raw: String,
        language: String,
        appName: String?,
        excluding: Set<UUID>,
        limit: Int
    ) -> [RelatedTakeScoring.Match] {
        guard limit > 0 else { return [] }
        let query = RelatedTakeScoring.words(in: raw)
        let queryVector = embed(raw)
        let queryNorm = queryVector.map(Self.norm) ?? 0

        let candidates = items.values
            .filter { $0.language == language && !excluding.contains($0.id) }
            .map { item in
                RelatedTakeScoring.Candidate(
                    id: item.id,
                    date: item.date,
                    words: item.words,
                    terms: item.terms,
                    cosine: Self.cosine(queryVector, queryNorm, item.vector, item.norm),
                    sameApp: appName != nil && item.appName == appName
                )
            }
        return RelatedTakeScoring.rank(
            query: query,
            candidates: candidates,
            documentFrequency: documentFrequency,
            takeCount: items.count,
            limit: limit
        )
    }

    // MARK: - Index

    private static let englishName = SpokenLanguage.english.englishName

    /// What an earlier take can teach is how something said came out cleaned, so
    /// only takes that were polished and inserted.
    private static func isUsable(_ entry: DictationLogEntry) -> Bool {
        entry.outcome == .success
            && !entry.raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !entry.polished.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func add(_ entry: DictationLogEntry) {
        // Both sides: the raw is how a name was heard, the polished how it came
        // out, and the next take may arrive either way.
        let words = RelatedTakeScoring.words(in: entry.raw)
            .union(RelatedTakeScoring.words(in: entry.polished))
        // Takes logged before the language was recorded were English.
        let language = entry.language ?? Self.englishName
        let vector = embed(entry.raw)
        items[entry.id] = Item(
            id: entry.id,
            date: entry.date,
            words: words,
            terms: RelatedTakeScoring.terms(in: entry.polished),
            vector: vector,
            norm: vector.map(Self.norm) ?? 0,
            awaitingVector: vector == nil && modelState != .ready && Self.isLatinScript(entry.raw),
            appName: entry.appName,
            language: language
        )
        for word in words {
            documentFrequency[word, default: 0] += 1
        }
    }

    private func remove(_ id: UUID) {
        guard let item = items.removeValue(forKey: id) else { return }
        for word in item.words {
            let count = (documentFrequency[word] ?? 1) - 1
            documentFrequency[word] = count > 0 ? count : nil
        }
    }

    /// The model ships with macOS, but its files can be missing until asked for.
    /// Asked once; macOS fetches them, and until then takes match on words.
    private func prepareModel() async {
        switch modelState {
        case .ready, .unavailable:
            return
        case .unknown, .downloading:
            break
        }
        guard let model = latinModel ?? NLContextualEmbedding(language: .english) else {
            modelState = .unavailable
            return
        }
        latinModel = model
        if !model.hasAvailableAssets {
            guard modelState == .unknown else { return }
            modelState = .downloading
            Task { [weak self] in
                let result = try? await model.requestAssets()
                await self?.assetsArrived(result == .available)
            }
            return
        }
        do {
            try model.load()
            modelState = .ready
        } catch {
            modelState = .unavailable
        }
    }

    private func assetsArrived(_ available: Bool) async {
        modelState = available ? .unknown : .unavailable
        if available { await refresh() }
    }

    /// One vector per take: the mean of its token vectors. Nil for text mostly
    /// in another script, which the Latin model would only misread.
    private func embed(_ text: String) -> [Float]? {
        guard modelState == .ready, let model = latinModel, Self.isLatinScript(text),
              let result = try? model.embeddingResult(for: text, language: nil) else { return nil }
        var sum = [Double](repeating: 0, count: model.dimension)
        var count = 0
        result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, _ in
            guard vector.count == sum.count else { return false }
            for index in vector.indices { sum[index] += vector[index] }
            count += 1
            return true
        }
        guard count > 0 else { return nil }
        return sum.map { Float($0 / Double(count)) }
    }

    /// More Latin letters than Hangul, kana and Han characters together.
    private static func isLatinScript(_ text: String) -> Bool {
        var latin = 0
        var other = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F:
                latin += 1
            case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7A3:
                other += 1
            default:
                continue
            }
        }
        return latin > other
    }

    private static func norm(_ vector: [Float]) -> Float {
        vDSP.dot(vector, vector).squareRoot()
    }

    private static func cosine(_ a: [Float]?, _ aNorm: Float, _ b: [Float]?, _ bNorm: Float) -> Double? {
        guard let a, let b, a.count == b.count, aNorm > 0, bNorm > 0 else { return nil }
        return Double(vDSP.dot(a, b) / (aNorm * bNorm))
    }
}
