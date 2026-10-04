import XCTest

final class ContextEditorDraftTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    func testAutomaticCorrectionIsProtectedFromPendingRefinementExpiryAndEviction() throws {
        var context = AutoContext()
        context.record(.add("Jaoquin evaluation figures"), app: "Overleaf", now: start)
        let shown = context.topics
        var draft = ContextEditorDraft(session: nil, topics: shown, now: start)
        draft.entries[0].text = "Joaquin evaluation figures"
        (context, _) = try XCTUnwrap(draft.applying(to: context, session: nil, now: start))
        XCTAssertEqual(context.topics[0].source, .edited)
        XCTAssertEqual(context.topics[0].id, shown[0].id)
        context.record(.refine(1, "Jaoquin evaluation figures draft"), relativeTo: shown, now: start)
        for index in 0..<20 { context.record(.add("Project \(index)"), now: start) }
        context.expire(now: start.addingTimeInterval(AutoContext.fadeAfterIdle + 1))
        XCTAssertEqual(context.topicTexts, ["Joaquin evaluation figures"])
    }

    func testSaveKeepsUneditedBackgroundRefinementAndNewTopics() throws {
        var context = AutoContext()
        context.record(.add("QuillMate draft"), now: start)
        var draft = ContextEditorDraft(session: nil, topics: context.topics, now: start)
        let note = draft.addNote()
        draft.entries[1].text = "Spell the reviewer name Nnamdi."
        context.record(.refine(1, "QuillMate draft for ICLR"), now: start)
        context.record(.add("Grocery budget"), now: start)
        let (saved, _) = try XCTUnwrap(draft.applying(to: context, session: nil, now: start))
        XCTAssertEqual(saved.topicTexts, ["QuillMate draft for ICLR", "Grocery budget", "Spell the reviewer name Nnamdi."])
        XCTAssertEqual(saved.userTopics.first?.id, note)
        XCTAssertEqual(saved.takes, context.takes)
    }

    func testDeletingAnOldRowCannotDeleteItsAutomaticReplacement() throws {
        var context = AutoContext()
        context.record(.add("QuillMate draft"), now: start)
        var draft = ContextEditorDraft(session: nil, topics: context.topics, now: start)
        draft.entries.removeAll()
        context.clearAutomatic()
        context.record(.add("Grocery budget"), now: start)
        let (saved, _) = try XCTUnwrap(draft.applying(to: context, session: nil, now: start))
        XCTAssertEqual(saved.topicTexts, ["Grocery budget"])
    }

    func testAShiftTakeArrivingDuringEditingIsKeptAlongsideTheOldPhrase() throws {
        let first = try XCTUnwrap(SessionContext.make(text: "QuillMate draft", now: start))
        var draft = ContextEditorDraft(session: first, topics: [], now: start)
        draft.entries[0].text = "QuillMate draft with Nnamdi"
        let newer = try XCTUnwrap(SessionContext.make(text: "Lunch at Sodamjeong", now: start))
        let (saved, spoken) = try XCTUnwrap(draft.applying(to: AutoContext(), session: newer, now: start))
        XCTAssertEqual(spoken, newer)
        XCTAssertEqual(saved.userTopics.map(\.text), ["QuillMate draft with Nnamdi"])

        draft.entries.removeAll()
        let (_, afterRemoval) = try XCTUnwrap(draft.applying(to: AutoContext(), session: newer, now: start))
        XCTAssertEqual(afterRemoval, newer)
    }

    func testShiftEditingAndRemovalKeepTheExistingSessionRules() throws {
        let spoken = try XCTUnwrap(SessionContext.make(text: "QuillMate", now: start))
        var draft = ContextEditorDraft(session: spoken, topics: [], now: start)
        draft.entries[0].text = "QuillMate with Nnamdi"
        let (_, edited) = try XCTUnwrap(draft.applying(to: AutoContext(), session: spoken, now: start))
        XCTAssertEqual(edited?.id, spoken.id)
        XCTAssertEqual(edited?.text, "QuillMate with Nnamdi")
        XCTAssertEqual(edited?.driftStrikes, 0)
        draft.entries[0].text = "   "
        let (_, removed) = try XCTUnwrap(draft.applying(to: AutoContext(), session: spoken, now: start))
        XCTAssertNil(removed)
    }

    func testLearningOffClearsOnlyAutomaticTopicsAndManualPromptStillWorks() {
        var context = AutoContext()
        context.record(.add("Jaoquin figures"), now: start)
        context.setUserTopic(text: "The name is Joaquin.", now: start)
        context.clearAutomatic()
        XCTAssertEqual(context.topicTexts, ["The name is Joaquin."])
        let cloud = AutoContext.polishIntent(session: "QuillMate draft", topics: context.topics, now: start)
        XCTAssertTrue(cloud.hasPrefix("QuillMate draft\nUser-provided context"))
        XCTAssertTrue(cloud.contains("The name is Joaquin."))
        XCTAssertFalse(cloud.contains("Recently"))
        XCTAssertTrue(AutoContext.onDevicePolishIntent(session: "", topics: context.topics).contains("The name is Joaquin."))
    }

    func testUserNotesGetTheManualBudgetAndTooManyNotesFailAtomically() {
        var context = AutoContext()
        let long = "Please keep this user note exactly as entered with more than eight words."
        context.setUserTopic(text: long, now: start)
        XCTAssertEqual(context.topicTexts, [long])
        for index in 1..<AutoContext.maxUserTopics { context.setUserTopic(text: "Note \(index)", now: start) }
        var draft = ContextEditorDraft(session: nil, topics: context.topics, now: start)
        _ = draft.addNote()
        draft.entries[draft.entries.count - 1].text = "Extra note"
        draft.entries[0].text = "An edit that must not be partially saved"
        XCTAssertNil(draft.applying(to: context, session: nil, now: start))
        XCTAssertEqual(context.topicTexts.first, long)
    }

    func testMetadataRefreshDoesNotCountAsAnEditAndBlankNewNotesAreOmitted() throws {
        var context = AutoContext()
        context.record(.add("QuillMate draft"), now: start)
        var draft = ContextEditorDraft(session: nil, topics: context.topics, now: start)
        XCTAssertFalse(draft.isDirty)
        _ = draft.addNote()
        XCTAssertTrue(draft.isDirty)
        let (saved, _) = try XCTUnwrap(draft.applying(to: context, session: nil, now: start))
        XCTAssertEqual(saved, context)
    }
}
