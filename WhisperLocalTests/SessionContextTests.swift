import XCTest

final class SessionContextTests: XCTestCase {
    func testIdleCutoffExpiresAfter45Minutes() {
        let setAt = Date(timeIntervalSince1970: 1_000_000)
        let context = SessionContext(
            text: "I'm writing the MambaEye paper",
            setAt: setAt,
            lastUsedAt: setAt,
            driftStrikes: 0
        )
        XCTAssertFalse(context.isExpired(now: setAt.addingTimeInterval(44 * 60)))
        XCTAssertTrue(context.isExpired(now: setAt.addingTimeInterval(45 * 60)))
        XCTAssertTrue(SessionContext.isExpired(context, now: setAt.addingTimeInterval(46 * 60)))
    }

    func testRegisterUseResetsIdleClock() {
        let setAt = Date(timeIntervalSince1970: 1_000_000)
        let context = SessionContext(
            text: "MambaEye",
            setAt: setAt,
            lastUsedAt: setAt,
            driftStrikes: 0
        )
        let later = setAt.addingTimeInterval(40 * 60)
        let used = context.registerUse(now: later)
        XCTAssertEqual(used.lastUsedAt, later)
        XCTAssertFalse(used.isExpired(now: later.addingTimeInterval(10 * 60)))
        XCTAssertTrue(used.isExpired(now: later.addingTimeInterval(45 * 60)))
    }

    func testTwoStrikesKeepAndThreeClear() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let start = SessionContext.make(text: "MambaEye paper", now: now)!
        let one = start.registerJudgment(relevant: false)
        XCTAssertEqual(one?.driftStrikes, 1)
        let two = one?.registerJudgment(relevant: false)
        XCTAssertEqual(two?.driftStrikes, 2)
        XCTAssertNotNil(two)
        XCTAssertNil(two?.registerJudgment(relevant: false))
    }

    func testRelevantJudgmentResetsStrikes() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var context = SessionContext.make(text: "MambaEye paper", now: now)!
        context = context.registerJudgment(relevant: false)!
        context = context.registerJudgment(relevant: false)!
        context = context.registerJudgment(relevant: true)!
        XCTAssertEqual(context.driftStrikes, 0)
        XCTAssertNotNil(context.registerJudgment(relevant: false))
    }

    func testCharacterCapTruncates() {
        let long = String(repeating: "a", count: 400)
        let capped = SessionContext.capped(long)
        XCTAssertEqual(capped.count, SessionContext.maxCharacters)
        XCTAssertTrue(capped.hasSuffix("…"))
        XCTAssertEqual(capped.filter { $0 == "a" }.count, SessionContext.maxCharacters - 1)
        XCTAssertEqual(SessionContext.make(text: long)?.text, capped)
        XCTAssertNil(SessionContext.make(text: "   "))
        XCTAssertEqual(SessionContext.capped("  hello  "), "hello")
        XCTAssertEqual(SessionContext.capped(String(repeating: "a", count: 280)).count, 280)
        XCTAssertFalse(SessionContext.capped(String(repeating: "a", count: 280)).hasSuffix("…"))
    }

    func testEmptyEditedTextDoesNotMakeAContext() {
        XCTAssertNil(SessionContext.make(text: ""))
        XCTAssertNil(SessionContext.make(text: " \n\t "))
        XCTAssertEqual(SessionContext.make(text: "  MambaEye paper  ")?.text, "MambaEye paper")
    }

    func testAgeLabelUsesSetAt() {
        let setAt = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertNil(SessionContext.ageLabel(setAt: setAt, now: setAt.addingTimeInterval(59)))
        XCTAssertEqual(SessionContext.ageLabel(setAt: setAt, now: setAt.addingTimeInterval(60)), "1 min ago")
        XCTAssertEqual(SessionContext.ageLabel(setAt: setAt, now: setAt.addingTimeInterval(20 * 60)), "20 min ago")
        XCTAssertEqual(SessionContext.ageLabel(setAt: setAt, now: setAt.addingTimeInterval(60 * 60)), "1 hr ago")
        XCTAssertEqual(SessionContext.ageLabel(setAt: setAt, now: setAt.addingTimeInterval(2 * 60 * 60)), "2 hr ago")
    }

    func testMenuLineIncludesSetAtAgeAndClipsPhrase() {
        let setAt = Date(timeIntervalSince1970: 1_000_000)
        let short = SessionContext(
            text: "MambaEye paper",
            setAt: setAt,
            lastUsedAt: setAt,
            driftStrikes: 0
        )
        XCTAssertEqual(short.menuLine(now: setAt), "Context: MambaEye paper")
        XCTAssertEqual(
            short.menuLine(now: setAt.addingTimeInterval(20 * 60)),
            "Context: MambaEye paper · set 20 min ago"
        )
        let longText = String(repeating: "a", count: 80)
        let long = SessionContext(text: longText, setAt: setAt, lastUsedAt: setAt, driftStrikes: 0)
        let line = long.menuLine(now: setAt, phraseLimit: 56)
        XCTAssertTrue(line.hasPrefix("Context: "))
        XCTAssertTrue(line.hasSuffix("…"))
        XCTAssertFalse(line.contains("set"))
        XCTAssertEqual(line.count, "Context: ".count + 56)
    }
}
