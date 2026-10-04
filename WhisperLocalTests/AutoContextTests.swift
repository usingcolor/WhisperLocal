import XCTest

final class AutoContextTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    // MARK: - Reading the model's line

    func testReadsEachKindOfLine() {
        XCTAssertEqual(AutoContext.change(fromTag: "<context-none/>"), .skip)
        XCTAssertEqual(AutoContext.change(fromTag: "<context-use n=\"2\"/>"), .use(2))
        XCTAssertEqual(
            AutoContext.change(fromTag: "<context-refine n=\"1\">QuillMate release draft</context-refine>"),
            .refine(1, "QuillMate release draft")
        )
        XCTAssertEqual(AutoContext.change(fromTag: "<context-add>WhisperLocal 0.2.5 release</context-add>"), .add("WhisperLocal 0.2.5 release"))
        XCTAssertNil(AutoContext.change(fromTag: nil))
        XCTAssertNil(AutoContext.change(fromTag: "<context-use/>"), "a use with no topic number says nothing")
        XCTAssertNil(AutoContext.change(fromTag: "<context-add>"), "an addition that never says what")
    }

    /// Every form here is one GPT-6 Luna answered with in the context benchmark.
    func testReadsTheLooseFormsTheModelAlsoUses() {
        XCTAssertEqual(AutoContext.change(fromTag: "<context-use 1/>"), .use(1))
        XCTAssertEqual(AutoContext.change(fromTag: "<context-use>1</context-use>"), .use(1))
        XCTAssertEqual(AutoContext.change(fromTag: "<context-refine>2</context-refine>"), .use(2))
        XCTAssertEqual(
            AutoContext.change(fromTag: "<context-refine 1>Horizon Kappa proposal budget</context-refine>"),
            .refine(1, "Horizon Kappa proposal budget")
        )
        XCTAssertEqual(
            AutoContext.change(fromTag: "<context-refine>Tessellate pull request review</context-refine>"),
            .add("Tessellate pull request review"),
            "with no topic number it is an addition, which refreshes the topic it repeats"
        )
        XCTAssertEqual(AutoContext.change(fromTag: "<context-none>"), .skip)
    }

    /// Apple Intelligence lists names; the app decides where they go.
    func testAppleIntelligenceListsNamesAndTheAppKeepsThem() {
        let take = "Okay, so I'm writing the Pellucid rebuttal for ICLR."
        XCTAssertEqual(AutoContext.change(names: [], in: take, topics: []), .skip)
        XCTAssertEqual(AutoContext.change(names: ["Pellucid", "ICLR"], in: take, topics: []), .add("Pellucid, ICLR"))
        XCTAssertEqual(
            AutoContext.change(names: ["Pellucid", "QuillMate"], in: take, topics: []), .add("Pellucid"),
            "a name the take does not contain is not kept"
        )
        XCTAssertEqual(AutoContext.change(names: ["Pellucid"], in: take, topics: ["Sosamjeong", "pellucid, ICLR"]), .use(2))
        XCTAssertEqual(
            AutoContext.change(names: ["pellucid"], in: "the pellucid rebuttal", topics: []), .skip,
            "no capital, so not a name"
        )
        XCTAssertEqual(
            AutoContext.change(names: ["Thursday", "Nnamdi"], in: "Nnamdi said Thursday works.", topics: []), .add("Nnamdi"),
            "a weekday is capitalised but not a name"
        )
        XCTAssertEqual(AutoContext.change(names: ["Thanks"], in: "Thanks.", topics: []), .skip, "small talk, capitalised")
        XCTAssertEqual(
            AutoContext.change(names: ["Reviewer 2", "Pellucid"], in: "Pellucid: answer Reviewer 2 first.", topics: ["Pellucid, ICLR"]),
            .refine(1, "Reviewer 2, Pellucid, ICLR"),
            "a new name joins the topic it shares a name with, newest first"
        )
        XCTAssertEqual(
            AutoContext.change(names: ["table", "Appendix", "ICLR"], in: "Move the table to the appendix for ICLR.", topics: []),
            .add("ICLR"),
            "a plain word is not a name, capitalised or not"
        )
        XCTAssertEqual(
            AutoContext.change(names: ["소담정", "시간"], in: "소담정 예약은 내가 할게, 시간은 열두 시", topics: []), .skip,
            "no capitals to tell a name from a word"
        )
    }

    /// Written as the tag it stands for, an answer reads back as itself.
    func testAChangeWrittenAsATagReadsBackTheSame() {
        let changes: [AutoContext.Change] = [
            .skip, .use(3), .refine(1, "Hiring loop, Siobhan Keane"), .add("혜린 이모 생일 선물"),
        ]
        for change in changes {
            XCTAssertEqual(AutoContext.change(fromTag: CleanupPrompt.lastContextTag(in: change.tag)), change)
        }
    }

    func testFindsTheAnswerInTheReply() {
        XCTAssertEqual(CleanupPrompt.lastContextTag(in: "<context-use n=\"1\"/>"), "<context-use n=\"1\"/>")
        XCTAssertEqual(
            CleanupPrompt.lastContextTag(in: "Topic 2 fits.\n<context-refine n=\"2\">Lunch budget</context-refine>"),
            "<context-refine n=\"2\">Lunch budget</context-refine>"
        )
        XCTAssertEqual(
            CleanupPrompt.lastContextTag(in: "<context-none/>\n<context-use n=\"2\"/>"),
            "<context-use n=\"2\"/>",
            "the last line is the answer"
        )
        XCTAssertEqual(CleanupPrompt.lastContextTag(in: "<context-none>"), "<context-none>")
        XCTAssertNil(CleanupPrompt.lastContextTag(in: "It is about the paper."))
    }

    // MARK: - Moving slowly

    func testDemoNameSurvivesTenInterveningTakesAcrossApps() {
        var context = AutoContext()
        context.record(.add("Interview with Joaquin"), app: "Messages", now: start)
        context.record(.add("Mom's birthday at Luigi's"), app: "Notes", now: start.addingTimeInterval(60))
        context.record(.add("Q3 budget review"), app: "Numbers", now: start.addingTimeInterval(120))
        for index in 3...10 {
            context.record(.skip, app: index.isMultiple(of: 2) ? "Slack" : "Mail",
                           now: start.addingTimeInterval(Double(index) * 60))
        }
        let now = start.addingTimeInterval(11 * 60)
        XCTAssertEqual(context.liveTopics(now: now).map(\.text), [
            "Interview with Joaquin", "Mom's birthday at Luigi's", "Q3 budget review",
        ])
        let intent = AutoContext.polishIntent(session: "", topics: context.liveTopics(now: now), now: now)
        XCTAssertTrue(intent.contains("Interview with Joaquin"), "the name still reaches polish beyond recent examples")
        XCTAssertFalse(intent.contains("walking"), "context does not learn the demo's mistaken transcription")
    }

    func testAddsAndUsesTopics() {
        var context = AutoContext()
        XCTAssertEqual(context.record(.add("QuillMate release draft"), now: start), "added: QuillMate release draft")
        XCTAssertEqual(context.record(.use(1), now: start), "used 1")
        XCTAssertEqual(context.topicTexts, ["QuillMate release draft"])
    }

    func testATopicRemembersWhereItCameUpAndWhen() {
        var context = AutoContext()
        context.record(.add("QuillMate release draft"), app: "Overleaf", now: start)
        context.record(.use(1), app: "ChatGPT", now: start.addingTimeInterval(120))
        context.record(.use(1), app: "overleaf", now: start.addingTimeInterval(240))
        XCTAssertEqual(context.topics[0].apps, ["overleaf", "ChatGPT"], "the latest first, each once")
        context.record(.refine(1, "QuillMate release draft for reviewer 2"), app: "Slack", now: start.addingTimeInterval(300))
        XCTAssertEqual(context.topics[0].apps, ["Slack", "overleaf"], "at most two")
        XCTAssertEqual(context.topics[0].lastUsedAt, start.addingTimeInterval(300))

        context.record(.skip, app: "Messages", now: start.addingTimeInterval(360))
        XCTAssertEqual(context.topics[0].apps, ["Slack", "overleaf"], "a take that is not part of it leaves it alone")
        context.record(.add("Lunch at Sodamjeong"), app: " ", now: start.addingTimeInterval(420))
        XCTAssertEqual(context.topics[1].apps, [], "no app, nothing noted")

        XCTAssertEqual(AutoContext.whereAndWhen(context.topics[0], now: start.addingTimeInterval(1_020)), "Slack and overleaf, 12 min ago")
        XCTAssertEqual(AutoContext.whereAndWhen(context.topics[1], now: start.addingTimeInterval(430)), "just now")
    }

    func testARefinementKeepsMostOfTheTopic() {
        var context = AutoContext()
        context.record(.add("QuillMate release draft"), now: start)
        XCTAssertEqual(
            context.record(.refine(1, "QuillMate release draft to reviewer 2"), now: start),
            "refined 1: QuillMate release draft to reviewer 2"
        )
        XCTAssertEqual(context.topicTexts, ["QuillMate release draft to reviewer 2"])
    }

    /// Several things at once: a take about lunch must not rewrite the paper.
    func testAReplacementIsAddedBesideTheTopicNotOverIt() {
        var context = AutoContext()
        context.record(.add("QuillMate release draft"), now: start)
        let happened = context.record(.refine(1, "Company lunch and grocery budget"), now: start)
        XCTAssertTrue(happened.hasPrefix("too big a change to 1"))
        XCTAssertEqual(context.topicTexts, ["QuillMate release draft", "Company lunch and grocery budget"])
    }

    func testARepeatedTopicIsRefreshedNotDuplicated() {
        var context = AutoContext()
        context.record(.add("QuillMate release draft"), now: start)
        XCTAssertEqual(context.record(.add("Release draft for QuillMate"), now: start), "already noted as 1")
        XCTAssertEqual(context.topicTexts.count, 1)
    }

    func testAFourthTopicPushesOutTheOneUsedLongestAgo() {
        var context = AutoContext()
        context.record(.add("QuillMate draft"), now: start)
        context.record(.add("Grocery budget"), now: start)
        context.record(.add("WhisperLocal release"), now: start)
        context.record(.use(1), now: start)
        let happened = context.record(.add("Demo planning with Casey"), now: start)
        XCTAssertTrue(happened.hasSuffix("dropped: Grocery budget"), happened)
        XCTAssertEqual(context.topicTexts, ["QuillMate draft", "WhisperLocal release", "Demo planning with Casey"])
    }

    func testTopicsFadeRatherThanBeingRemovedByTheModel() {
        var context = AutoContext()
        context.record(.add("QuillMate draft"), now: start)
        for _ in 0..<AutoContext.fadeAfterTakes {
            context.record(.skip, now: start)
        }
        XCTAssertEqual(context.topicTexts, ["QuillMate draft"], "fifteen takes about other things are not enough")
        XCTAssertTrue(context.record(.skip, now: start).contains("faded: QuillMate draft"))
        XCTAssertTrue(context.isEmpty)

        context.record(.add("Grocery budget"), now: start)
        context.record(nil, now: start.addingTimeInterval(AutoContext.fadeAfterIdle + 1))
        XCTAssertTrue(context.isEmpty, "idle as long as a spoken context lasts")
    }

    /// The model numbered the topics before this take's fading: its numbers
    /// must still mean those topics.
    func testAnAnswersNumbersMeanTheTopicsTheModelWasShown() {
        var context = AutoContext()
        context.record(.add("QuillMate draft"), now: start)
        context.record(.add("Grocery budget"), now: start)
        for _ in 0..<AutoContext.fadeAfterTakes - 1 {
            context.record(.use(2), now: start)
        }
        // "QuillMate draft" is due to fade on this take, and the take is about it.
        XCTAssertEqual(context.record(.use(1), now: start), "used 1")
        XCTAssertEqual(context.topicTexts, ["QuillMate draft", "Grocery budget"])

        for _ in 0..<AutoContext.fadeAfterTakes {
            context.record(.use(2), now: start)
        }
        // Now topic 1 fades on this take, and the answer is about topic 2.
        XCTAssertEqual(
            context.record(.refine(2, "Grocery budget for the party"), now: start),
            "refined 2: Grocery budget for the party; faded: QuillMate draft"
        )
        XCTAssertEqual(context.topicTexts, ["Grocery budget for the party"])
    }

    func testTopicsAreOneShortLine() {
        XCTAssertEqual(AutoContext.clean("  \"QuillMate\n draft\"  "), "QuillMate draft")
        XCTAssertNil(AutoContext.clean(" \n "))
        XCTAssertEqual(AutoContext.clean(String(repeating: "a", count: 300))?.count, AutoContext.maxCharacters)
    }

    /// The to-do list the model grew topics into, from the benchmark.
    func testATopicIsCutAtEightWords() {
        XCTAssertEqual(
            AutoContext.clean("Horizon Kappa proposal budget and deadline; cut travel line and move funds to equipment"),
            "Horizon Kappa proposal budget and deadline; cut travel…"
        )
        XCTAssertEqual(
            AutoContext.clean("Tessellate pull request review: tiling logic, cache reuse, tests"),
            "Tessellate pull request review: tiling logic, cache reuse…",
            "no comma left hanging where the cut falls"
        )
        XCTAssertEqual(AutoContext.clean("혜린 이모 생일 선물"), "혜린 이모 생일 선물")

        var context = AutoContext()
        context.record(.add("Pellucid ICLR rebuttal"), now: start)
        context.record(.refine(1, "Pellucid ICLR rebuttal with table moved to appendix and caption shortened"), now: start)
        XCTAssertEqual(context.topicTexts, ["Pellucid ICLR rebuttal with table moved to appendix…"])
    }

    // MARK: - The prompts

    func testShortNamesAndAcronymsDoNotSwallowOtherTopics() {
        var context = AutoContext()
        context.record(.add("AI"), now: start)
        context.record(.add("WhisperLocal release"), now: start)
        context.record(.add("UI"), now: start)
        XCTAssertEqual(context.topicTexts, ["AI", "WhisperLocal release", "UI"])
        context.record(.add("AI"), now: start)
        XCTAssertEqual(context.topicTexts.count, 3)
        XCTAssertFalse(AutoContext.keepsEnough(of: "to", in: "WhisperLocal release"))
        XCTAssertFalse(AutoContext.keepsEnough(of: "WhisperLocal release", in: "to"))
    }

    func testARefinementCanKeepAShortName() {
        var context = AutoContext()
        context.record(.add("Bo"), now: start)
        let id = context.topics[0].id
        context.record(.refine(1, "Bo interview"), now: start)
        XCTAssertEqual(context.topicTexts, ["Bo interview"])
        XCTAssertEqual(context.topics[0].id, id)
    }

    func testNamesMatchCompleteWordsInTakesAndTopics() {
        XCTAssertEqual(
            AutoContext.change(names: ["Ann"], in: "Ask Ann about lunch.", topics: ["Anna, Robotics"]),
            .add("Ann")
        )
        XCTAssertEqual(AutoContext.change(names: ["API"], in: "The APIServer is ready.", topics: []), .skip)
        XCTAssertEqual(AutoContext.change(names: ["API"], in: "The API_Server is ready.", topics: []), .skip)
        XCTAssertEqual(
            AutoContext.change(names: ["Ann"], in: "Annabelle met Ann today.", topics: ["Ann, Robotics"]),
            .use(1), "an embedded first match must not hide a later complete name"
        )
        XCTAssertEqual(AutoContext.change(names: ["Ann"], in: "Ann's draft is ready.", topics: []), .add("Ann"))
    }

    func testExpiredTopicsAreNotAvailableToPolishBeforeAnotherUpdate() {
        var context = AutoContext()
        context.record(.add("QuillMate draft"), now: start)
        context.record(.add("Grocery budget"), now: start.addingTimeInterval(120))
        let now = start.addingTimeInterval(AutoContext.fadeAfterIdle + 1)
        let live = context.liveTopics(now: now)
        XCTAssertEqual(live.map(\.text), ["Grocery budget"])
        XCTAssertFalse(AutoContext.polishIntent(session: "", topics: live, now: now).contains("QuillMate"))
        XCTAssertEqual(context.expire(now: now), ["QuillMate draft"])
    }

    func testAPendingAnswerKeepsItsTopicAfterEarlierTopicsExpire() {
        var context = AutoContext()
        context.record(.add("QuillMate draft"), now: start)
        context.record(.add("Grocery budget"), now: start.addingTimeInterval(120))
        let shown = context.topics
        let now = start.addingTimeInterval(AutoContext.fadeAfterIdle + 1)
        context.expire(now: now)
        XCTAssertEqual(
            context.record(.refine(2, "Grocery budget for the party"), relativeTo: shown, now: now),
            "refined 1: Grocery budget for the party"
        )
        XCTAssertEqual(context.topicTexts, ["Grocery budget for the party"])
        XCTAssertEqual(context.topics[0].id, shown[1].id)
    }

    func testAPendingAnswerCannotReviveAnExpiredTopicOrTouchItsReplacement() {
        var context = AutoContext()
        context.record(.add("QuillMate draft"), now: start)
        context.record(.add("Grocery budget"), now: start.addingTimeInterval(120))
        let shown = context.topics
        let now = start.addingTimeInterval(AutoContext.fadeAfterIdle + 1)
        let happened = context.record(.use(1), relativeTo: shown, now: now)
        XCTAssertTrue(happened.contains("topic no longer available"))
        XCTAssertEqual(context.topicTexts, ["Grocery budget"])
        XCTAssertEqual(context.topics[0].lastUsedAt, start.addingTimeInterval(120))

        context.clear()
        context.record(.add("Hiring Hubbard"), now: now)
        context.record(.refine(1, "QuillMate draft draft"), relativeTo: shown, now: now)
        XCTAssertEqual(context.topicTexts, ["Hiring Hubbard"])
    }

    func testDelayedUpdatesUseTheTakeDateAndStillRespectTheCurrentClock() {
        var context = AutoContext()
        context.record(.add("QuillMate draft"), relativeTo: [], now: start, observedAt: start.addingTimeInterval(120))
        XCTAssertEqual(context.topics[0].lastUsedAt, start)
        let happened = context.record(
            .add("Grocery budget"), relativeTo: [], now: start,
            observedAt: start.addingTimeInterval(AutoContext.fadeAfterIdle + 1)
        )
        XCTAssertTrue(context.isEmpty, "a queued take older than the expiry must not look newly used")
        XCTAssertEqual(happened, "added: Grocery budget; faded: QuillMate draft | Grocery budget")
    }

    func testPolishSeesWhatTheSpeakerHasBeenDoingAsAListAndIsAskedNothing() {
        XCTAssertEqual(AutoContext.polishIntent(session: "", topics: [], now: start), "")
        var context = AutoContext()
        context.record(.add("QuillMate draft"), app: "Overleaf", now: start)
        context.record(.add("Lunch budget"), app: "KakaoTalk", now: start.addingTimeInterval(300))
        context.record(.use(1), app: "ChatGPT", now: start.addingTimeInterval(600))
        let now = start.addingTimeInterval(720)
        XCTAssertEqual(
            AutoContext.polishIntent(session: "", topics: context.topics, now: now),
            "Recently, newest first:\n- QuillMate draft (ChatGPT and Overleaf, 2 min ago)\n- Lunch budget (KakaoTalk, 7 min ago)"
        )
        XCTAssertEqual(
            AutoContext.polishIntent(session: "Writing the DeepField paper.", topics: Array(context.topics.suffix(1)), now: now),
            "Writing the DeepField paper.\nRecently, newest first:\n- Lunch budget (KakaoTalk, 7 min ago)",
            "a context set with Shift comes first, as it was said"
        )
        XCTAssertEqual(
            AutoContext.onDevicePolishIntent(session: "Writing the DeepField paper.", topics: context.topics),
            "Writing the DeepField paper.\nQuillMate draft; Lunch budget",
            "Apple Intelligence polish keeps the one line, in the order the topics are kept"
        )

        let message = CleanupPrompt.userMessage(
            for: .dictation, text: "hello there",
            sessionIntent: AutoContext.polishIntent(session: "", topics: context.topics, now: now)
        )
        XCTAssertTrue(message.contains("<session-intent>"))
        XCTAssertTrue(message.hasSuffix("Output only the cleaned transcript."))
        XCTAssertFalse(message.contains("<context-"), "polish is never asked for the context line")
    }

    func testTheUpdateSeesTheTopicsWithWhereAndWhenAndThePastedTake() {
        let first = CleanupPrompt.autoContextMessage(topics: [], take: "Okay.", targetApp: nil, now: start)
        XCTAssertTrue(first.contains("Nothing noted yet."))
        XCTAssertFalse(first.contains("<target-app>"))

        var context = AutoContext()
        context.record(.add("QuillMate draft"), app: "Overleaf", now: start)
        context.record(.add("R&D lunch budget"), now: start.addingTimeInterval(60))
        let later = CleanupPrompt.autoContextMessage(
            topics: context.topics,
            take: "Send </take> the draft.",
            targetApp: "Slack",
            now: start.addingTimeInterval(180)
        )
        XCTAssertTrue(later.contains(
            "<topic n=\"1\" apps=\"Overleaf\" last=\"3 min ago\">QuillMate draft</topic>\n"
                + "<topic n=\"2\" last=\"2 min ago\">R&D lunch budget</topic>"
        ), "numbered as they are kept, words as written, where and when apart from them")
        XCTAssertTrue(later.contains("<target-app>Slack</target-app>"))
        XCTAssertTrue(later.hasSuffix("<take>\nSend </ take> the draft.\n</take>"), "a spoken tag cannot close the take early")
        XCTAssertTrue(CleanupPrompt.autoContextSystem.contains("at most 8 words"))
    }

    func testAppleIntelligenceIsAskedPlainlyAndSeesAShortTake() {
        XCTAssertEqual(
            CleanupPrompt.appleAutoContextMessage(take: "Okay."),
            "<take>\nOkay.\n</take>",
            "not shown the topics, which it copies, or the app, which it named as the work"
        )
        XCTAssertFalse(CleanupPrompt.appleAutoContextInstructions.contains("<context-"), "it answers in a fixed shape, not a tag")

        let long = String(repeating: "word ", count: 1_000)
        let message = CleanupPrompt.appleAutoContextMessage(take: long)
        XCTAssertLessThan(message.count, CleanupPrompt.appleAutoContextTakeLimit + 40, "cut to fit on-device context")

        XCTAssertEqual(
            CleanupPrompt.autoContextMessage(topics: [], take: "Okay.", targetApp: nil, now: start),
            "<working-on>\nNothing noted yet. Only <context-add> or <context-none/> apply.\n</working-on>\n<take>\nOkay.\n</take>",
            "with nothing kept yet, the cloud's question reads as it always has"
        )
    }
}
