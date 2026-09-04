import XCTest

/// The `<part>` block tells a polish piece it is a fragment. These pin the two
/// things that matter: it never appears for an unsplit take, and when it does
/// appear it says the right thing for that position.
final class TranscriptPartTests: XCTestCase {
    private func prompt(_ part: CleanupPrompt.TranscriptPart?) -> String {
        CleanupPrompt.wrapTranscript(
            "so the thing is uh we should probably ship this",
            targetApp: "Claude — chat app",
            appNotes: "",
            appDictionary: ["WhisperLocal"],
            part: part
        )
    }

    func testUnsplitTakesGetTheExactPromptTheyAlwaysDid() {
        // The common path: anything under the polish budget is one piece, and its
        // prompt must not change at all.
        XCTAssertEqual(prompt(nil), prompt(CleanupPrompt.TranscriptPart(index: 1, total: 1)))
        XCTAssertFalse(prompt(nil).contains("<part"))
        XCTAssertFalse(prompt(CleanupPrompt.TranscriptPart(index: 1, total: 1)).contains("<part"))
    }

    func testSplitTakesAnnounceThePiece() {
        let middle = prompt(CleanupPrompt.TranscriptPart(index: 2, total: 4))
        XCTAssertTrue(middle.contains("<part index=\"2\" of=\"4\">"))
        XCTAssertTrue(middle.contains("</part>"))
    }

    func testRulesMatchThePosition() {
        let first = prompt(CleanupPrompt.TranscriptPart(index: 1, total: 3))
        XCTAssertFalse(first.contains("continues the previous"), "the first piece starts the dictation")
        XCTAssertTrue(first.contains("runs into the next"))

        let middle = prompt(CleanupPrompt.TranscriptPart(index: 2, total: 3))
        XCTAssertTrue(middle.contains("continues the previous"))
        XCTAssertTrue(middle.contains("runs into the next"))

        let last = prompt(CleanupPrompt.TranscriptPart(index: 3, total: 3))
        XCTAssertTrue(last.contains("continues the previous"))
        XCTAssertFalse(last.contains("runs into the next"), "the last piece ends the dictation")
    }

    func testPartSitsBelowTheCacheablePrefix() {
        // Everything stable across takes into one app must precede the per-piece
        // block, or it stops being a shared prefix the provider can cache.
        let text = prompt(CleanupPrompt.TranscriptPart(index: 2, total: 4))
        let app = text.range(of: "<target-app>")
        let dictionary = text.range(of: "<app-dictionary>")
        let part = text.range(of: "<part index")
        let transcript = text.range(of: "<transcript>")
        XCTAssertNotNil(app); XCTAssertNotNil(dictionary); XCTAssertNotNil(part); XCTAssertNotNil(transcript)
        XCTAssertLessThan(app!.lowerBound, part!.lowerBound)
        XCTAssertLessThan(dictionary!.lowerBound, part!.lowerBound)
        XCTAssertLessThan(part!.lowerBound, transcript!.lowerBound)
    }

    func testTheBlockTellsTheModelNotToMentionTheSplit() {
        XCTAssertTrue(prompt(CleanupPrompt.TranscriptPart(index: 2, total: 4)).contains("never mention the split"))
    }
}
