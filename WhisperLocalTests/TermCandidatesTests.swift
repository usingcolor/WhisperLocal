import XCTest

final class TermCandidatesTests: XCTestCase {
    private let base = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func take(
        _ polished: String,
        app: String? = "Terminal",
        minutesAgo: Double = 0,
        outcome: DictationLogEntry.Outcome = .success
    ) -> DictationLogEntry {
        DictationLogEntry(
            id: UUID(),
            date: base.addingTimeInterval(-minutesAgo * 60),
            raw: polished.lowercased(),
            polished: polished,
            stages: [],
            cleanupNote: nil,
            appName: app,
            insertMethod: nil,
            outcome: outcome,
            errorMessage: nil,
            audioSeconds: nil
        )
    }

    func testTermFormsKeepTheSpellingAsWritten() {
        XCTAssertEqual(
            RelatedTakeScoring.termForms(in: "Ask Casey about QuillMate. Casey agreed."),
            ["Casey", "QuillMate"]
        )
    }

    func testCountsTakesNotMentionsAndKeepsTheCommonestSpelling() {
        let entries = [
            take("Ask Casey about the layout, and Casey again.", minutesAgo: 1),
            take("The CASEY layout and the QXDB logs.", app: "Claude", minutesAgo: 2),
            take("Check the QXDB dashboard with Casey.", minutesAgo: 3),
        ]
        let candidates = TermCandidates.collect(from: entries, knownText: "", handled: [])

        XCTAssertEqual(candidates.map(\.id), ["casey", "qxdb"])
        XCTAssertEqual(candidates[0].form, "Casey")
        XCTAssertEqual(candidates[0].takeCount, 3)
        XCTAssertEqual(candidates[0].apps, ["Terminal", "Claude"])
        XCTAssertEqual(candidates[1].takeCount, 2)
    }

    func testSkipsWhatIsAlreadyKnownOrHandled() {
        let entries = [take("Open README.md for QuillMate and ZXPL, then ask Morgan.")]
        let known = "Sample wiki. Rejoin quill mate → QuillMate. Keep README.md as written."

        XCTAssertEqual(
            TermCandidates.collect(from: entries, knownText: known, handled: []).map(\.id),
            ["morgan", "zxpl"]
        )
        XCTAssertEqual(
            TermCandidates.collect(from: entries, knownText: known, handled: ["zxpl"]).map(\.id),
            ["morgan"]
        )
    }

    func testIgnoresFailedTakesAndWordsWithoutLatinLetters() {
        let entries = [
            take("Ask Casey now.", outcome: .error),
            take("새 문서를 열어 주세요."),
        ]
        XCTAssertTrue(TermCandidates.collect(from: entries, knownText: "", handled: []).isEmpty)
    }

    func testExampleIsTheSentenceFromTheNewestTake() {
        let entries = [
            take("Old mention of Zed here.", minutesAgo: 10),
            take("First sentence here. Open the README.md with Zed now! Next one.", minutesAgo: 1),
        ]
        let zed = TermCandidates.collect(from: entries, knownText: "", handled: []).first { $0.id == "zed" }
        XCTAssertEqual(zed?.example, "Open the README.md with Zed now!")
    }
}
