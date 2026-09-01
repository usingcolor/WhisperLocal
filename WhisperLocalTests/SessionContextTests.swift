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
        XCTAssertEqual(SessionContext.capped(long).count, SessionContext.maxCharacters)
        XCTAssertEqual(SessionContext.make(text: long)?.text.count, SessionContext.maxCharacters)
        XCTAssertNil(SessionContext.make(text: "   "))
        XCTAssertEqual(SessionContext.capped("  hello  "), "hello")
    }
}
