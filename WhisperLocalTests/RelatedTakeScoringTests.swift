import XCTest

final class RelatedTakeScoringTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func candidate(
        _ text: String,
        cosine: Double? = nil,
        sameApp: Bool = false,
        age: TimeInterval = 0
    ) -> RelatedTakeScoring.Candidate {
        RelatedTakeScoring.Candidate(
            id: UUID(),
            date: now.addingTimeInterval(-age),
            words: RelatedTakeScoring.words(in: text),
            terms: RelatedTakeScoring.terms(in: text),
            cosine: cosine,
            sameApp: sameApp
        )
    }

    /// Document frequencies as if these texts were the whole log.
    private func frequencies(_ texts: [String]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for text in texts {
            for word in RelatedTakeScoring.words(in: text) { counts[word, default: 0] += 1 }
        }
        return counts
    }

    func testWordsDropFillersCommonWordsAndPunctuation() {
        XCTAssertEqual(
            RelatedTakeScoring.words(in: "Uh, so the Quill mate — it's README.md, okay"),
            ["quill", "mate", "readme"]
        )
    }

    func testTermsAreNamesNotSentenceStarts() {
        XCTAssertEqual(
            RelatedTakeScoring.terms(in: "Quill mate follow-up for ICLR 2027. Then ask Casey about QuillMate and GPT5."),
            ["iclr", "casey", "quillmate", "gpt5"]
        )
    }

    /// Replaying the log with one shared rare word as enough paired takes on
    /// nothing but "okay", "then" or "match": a small log thinks those are rare.
    func testOneSharedOrdinaryWordIsNotEnough() {
        let log = ["match the tables to the figures"] + Array(repeating: "filler take", count: 40)
        let matches = RelatedTakeScoring.rank(
            query: RelatedTakeScoring.words(in: "match the limitation"),
            candidates: [candidate("match the tables to the figures")],
            documentFrequency: frequencies(log),
            takeCount: log.count,
            limit: 3
        )
        XCTAssertTrue(matches.isEmpty)
    }

    func testOneSharedNameIsEnough() {
        let log = ["Email Jordan about the draft."] + Array(repeating: "filler take", count: 40)
        let named = candidate("Email Jordan about the draft.")
        let matches = RelatedTakeScoring.rank(
            query: RelatedTakeScoring.words(in: "ask jordan tomorrow"),
            candidates: [named],
            documentFrequency: frequencies(log),
            takeCount: log.count,
            limit: 3
        )
        XCTAssertEqual(matches.map(\.id), [named.id])
    }

    func testRelatedSlotsLeaveRecencyTheMajority() {
        XCTAssertEqual(RelatedTakeScoring.relatedSlots(outOf: 1), 0)
        XCTAssertEqual(RelatedTakeScoring.relatedSlots(outOf: 2), 1)
        XCTAssertEqual(RelatedTakeScoring.relatedSlots(outOf: 3), 1)
        XCTAssertEqual(RelatedTakeScoring.relatedSlots(outOf: 5), 2)
        XCTAssertEqual(RelatedTakeScoring.relatedSlots(outOf: 8), 3)
    }

    func testRareCeilingGrowsWithTheLog() {
        XCTAssertEqual(RelatedTakeScoring.rareCeiling(takeCount: 10), 2)
        XCTAssertEqual(RelatedTakeScoring.rareCeiling(takeCount: 150), 3)
        XCTAssertEqual(RelatedTakeScoring.rareCeiling(takeCount: 5_000), 100)
    }

    /// Synthetic regression: embedding similarity alone prefers an unrelated
    /// take, while shared rare words find the take that spells the name out.
    func testSharedRareWordsFindTheTakeThatTeachesTheName() {
        let teaches = candidate("The ribbon layout, Casey, is from the handbook Quill mate.", cosine: 0.50)
        let unrelated = candidate("Adjust the microphone recording level.", cosine: 0.53)
        let log = [
            "The ribbon layout, Casey, is from the handbook Quill mate.",
            "Adjust the microphone recording level.",
        ] + Array(repeating: "The export completed successfully.", count: 20)

        let matches = RelatedTakeScoring.rank(
            query: RelatedTakeScoring.words(in: "Use the quilt mate for the ribbon layout."),
            candidates: [unrelated, teaches],
            documentFrequency: frequencies(log),
            takeCount: log.count,
            limit: 3
        )

        XCTAssertEqual(matches.map(\.id), [teaches.id])
        XCTAssertEqual(matches.first?.sharedRareWords, ["layout", "mate", "ribbon"])
    }

    func testCommonWordsAloneAreNotRelated() {
        let log = Array(repeating: "the build and the tests", count: 30)
        let matches = RelatedTakeScoring.rank(
            query: RelatedTakeScoring.words(in: "and the build"),
            candidates: [candidate("the build and the tests", cosine: 0.7)],
            documentFrequency: frequencies(log),
            takeCount: log.count,
            limit: 3
        )
        XCTAssertTrue(matches.isEmpty)
    }

    func testARestatementIsRelatedWithoutSharingAWord() {
        let restated = candidate("completely different words here", cosine: 0.99)
        let matches = RelatedTakeScoring.rank(
            query: RelatedTakeScoring.words(in: "nothing overlaps at all"),
            candidates: [restated],
            documentFrequency: frequencies(["completely different words here"]),
            takeCount: 40,
            limit: 3
        )
        XCTAssertEqual(matches.map(\.id), [restated.id])
    }

    func testSameAppWinsATieAndRecencyBreaksTheRest() {
        // Three takes share the word, so the log has to be big enough for three
        // to still count as rare.
        let log = ["quillmate results", "quillmate results", "quillmate results"]
            + Array(repeating: "filler take", count: 200)
        let older = candidate("quillmate results", age: 600)
        let newer = candidate("quillmate results", age: 60)
        let sameApp = candidate("quillmate results", sameApp: true, age: 900)

        let matches = RelatedTakeScoring.rank(
            query: RelatedTakeScoring.words(in: "quillmate results"),
            candidates: [older, newer, sameApp],
            documentFrequency: frequencies(log),
            takeCount: log.count,
            limit: 3
        )
        XCTAssertEqual(matches.map(\.id), [sameApp.id, newer.id, older.id])
    }

    func testLimitAndEmptyQuery() {
        let log = ["kakao pay bill", "kakao pay bill"] + Array(repeating: "filler take", count: 40)
        let candidates = [candidate("kakao pay bill"), candidate("kakao pay bill")]
        let frequencyTable = frequencies(log)

        XCTAssertEqual(RelatedTakeScoring.rank(
            query: RelatedTakeScoring.words(in: "kakao pay"),
            candidates: candidates,
            documentFrequency: frequencyTable,
            takeCount: log.count,
            limit: 1
        ).count, 1)
        XCTAssertTrue(RelatedTakeScoring.rank(
            query: RelatedTakeScoring.words(in: "uh um"),
            candidates: candidates,
            documentFrequency: frequencyTable,
            takeCount: log.count,
            limit: 3
        ).isEmpty)
    }

    /// The band the contextual embedding scores ordinary takes in must not open
    /// the gate on its own. This score is below the restatement threshold.
    func testTheEmbeddingsUsualBandDoesNotOpenTheGate() {
        let log = Array(repeating: "filler take", count: 40) + ["completely different words here"]
        let matches = RelatedTakeScoring.rank(
            query: RelatedTakeScoring.words(in: "nothing overlaps at all"),
            candidates: [candidate("completely different words here", cosine: 0.958)],
            documentFrequency: frequencies(log),
            takeCount: log.count,
            limit: 3
        )
        XCTAssertTrue(matches.isEmpty)
    }

    func testSimilarityAboveTheFloorBreaksATie() {
        let log = ["kakao pay bill", "kakao pay bill"] + Array(repeating: "filler take", count: 40)
        let closer = candidate("kakao pay bill", cosine: 0.96, age: 600)
        let plain = candidate("kakao pay bill", cosine: 0.90, age: 60)
        let matches = RelatedTakeScoring.rank(
            query: RelatedTakeScoring.words(in: "kakao pay"),
            candidates: [plain, closer],
            documentFrequency: frequencies(log),
            takeCount: log.count,
            limit: 3
        )
        XCTAssertEqual(matches.map(\.id), [closer.id, plain.id])
    }
}
