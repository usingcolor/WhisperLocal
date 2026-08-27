import XCTest

final class HeuristicPolisherTests: XCTestCase {
    private let polisher = HeuristicPolisher()

    func polish(_ text: String, dictionary: [String] = []) async throws -> String {
        try await polisher.polish(text, dictionary: dictionary)
    }

    func testEmpty() async throws {
        let empty = try await polish("")
        let blank = try await polish("   ")
        XCTAssertEqual(empty, "")
        XCTAssertEqual(blank, "")
    }

    func testFillersAndCapitalization() async throws {
        let um = try await polish("um hello there")
        let so = try await polish("uh so I think we should um go")
        XCTAssertEqual(um, "Hello there.")
        XCTAssertEqual(so, "I think we should go.")
    }

    func testKeepsSemanticLikeAndYouKnow() async throws {
        let like = try await polish("I like coffee")
        let know = try await polish("do you know the way")
        XCTAssertEqual(like, "I like coffee.")
        XCTAssertEqual(know, "Do you know the way?")
    }

    func testFillerLike() async throws {
        let commaLike = try await polish("it was, like, really good")
        let wasLike = try await polish("it was like really good")
        XCTAssertEqual(commaLike, "It was really good.")
        XCTAssertEqual(wasLike, "It was really good.")
    }

    func testActuallyCorrectionNotAdverb() async throws {
        let time = try await polish("meet at 5 actually 6")
        let day = try await polish("slipping to Friday actually Monday")
        let adverb = try await polish("I actually think that's right")
        XCTAssertEqual(time, "Meet at 6.")
        XCTAssertEqual(day, "Slipping to Monday.")
        XCTAssertEqual(adverb, "I actually think that's right.")
    }

    func testScratchThatAndIMean() async throws {
        let scratch = try await polish("send it to John scratch that send it to Sarah")
        let iMean = try await polish("send it to John I mean Sarah")
        XCTAssertEqual(scratch, "Send it to Sarah.")
        XCTAssertEqual(iMean, "Send it to Sarah.")
    }

    func testSpokenPunctuationAndQuestions() async throws {
        let spoken = try await polish("hello world period next sentence")
        let question = try await polish("what time is the meeting")
        let canYou = try await polish("Can you send that")
        XCTAssertEqual(spoken, "Hello world. Next sentence.")
        XCTAssertEqual(question, "What time is the meeting?")
        XCTAssertEqual(canYou, "Can you send that?")
    }

    func testNewParagraph() async throws {
        let text = try await polish("hello new paragraph world")
        XCTAssertEqual(text, "Hello.\n\nWorld.")
    }

    func testUtteranceStarters() async throws {
        let fillerSo = try await polish("so I think we should go")
        let semanticSo = try await polish("so much better")
        XCTAssertEqual(fillerSo, "I think we should go.")
        XCTAssertEqual(semanticSo, "So much better.")
    }

    func testPronounIDictionaryAndRepeats() async throws {
        let pronoun = try await polish("i think i can")
        let dict = try await polish("try whisperkit please", dictionary: ["WhisperKit"])
        let repeats = try await polish("I I think think we we should")
        XCTAssertEqual(pronoun, "I think I can.")
        XCTAssertEqual(dict, "Try WhisperKit please.")
        XCTAssertEqual(repeats, "I think we should.")
    }

    func testPipelineOfflineCleanupIsSuccess() async {
        let pipeline = PolishPipeline(
            heuristic: HeuristicPolisher(),
            localLLM: nil,
            cloud: nil,
            useLocalLLM: false,
            enableTextCleanup: true,
            dictionary: []
        )
        let result = await pipeline.run("um hello there")
        XCTAssertEqual(result.text, "Hello there.")
        XCTAssertFalse(result.cleanupFailed)
        XCTAssertEqual(result.stages, ["Heuristic"])
    }

    func testPipelineCanSkipCleanup() async {
        let pipeline = PolishPipeline(
            heuristic: HeuristicPolisher(),
            localLLM: nil,
            cloud: nil,
            useLocalLLM: false,
            enableTextCleanup: false,
            dictionary: []
        )
        let result = await pipeline.run("um hello there")
        XCTAssertEqual(result.text, "um hello there")
        XCTAssertEqual(result.stages, ["Raw"])
    }

    func testPipelineSkipsAppleIntelligenceWhenCloudIsOn() async {
        let local = ProbePolisher(name: "Apple Intelligence")
        let cloud = ProbePolisher(name: "OpenAI")
        let pipeline = PolishPipeline(
            heuristic: HeuristicPolisher(),
            localLLM: local,
            cloud: cloud,
            useLocalLLM: true,
            enableTextCleanup: true,
            dictionary: []
        )
        let result = await pipeline.run("hello")
        XCTAssertEqual(local.callCount, 0)
        XCTAssertEqual(cloud.callCount, 1)
        XCTAssertEqual(result.stages, ["Heuristic", "OpenAI"])
        XCTAssertFalse(result.cleanupFailed)
    }

    func testPipelineUsesAppleIntelligenceWhenCloudIsOff() async {
        let local = ProbePolisher(name: "Apple Intelligence")
        let pipeline = PolishPipeline(
            heuristic: HeuristicPolisher(),
            localLLM: local,
            cloud: nil,
            useLocalLLM: true,
            enableTextCleanup: true,
            dictionary: []
        )
        let result = await pipeline.run("hello")
        XCTAssertEqual(local.callCount, 1)
        XCTAssertEqual(result.stages, ["Heuristic", "Apple Intelligence"])
    }
}

private final class ProbePolisher: TextPolisher, @unchecked Sendable {
    let name: String
    private let lock = NSLock()
    private(set) var callCount = 0

    init(name: String) {
        self.name = name
    }

    func polish(_ text: String, dictionary: [String], personalContext: String) async throws -> String {
        lock.lock()
        callCount += 1
        lock.unlock()
        return text
    }
}

final class CleanupPromptTests: XCTestCase {
    func testWrapsTranscriptLikeOpenWhispr() {
        let wrapped = CleanupPrompt.wrapTranscript("hello")
        XCTAssertTrue(wrapped.contains("<transcript>\nhello\n</transcript>"))
        XCTAssertTrue(wrapped.contains("Output only the cleaned transcript."))
    }

    func testSystemPromptIsCleanupEngineNotChatbot() {
        let system = CleanupPrompt.system()
        XCTAssertTrue(system.contains("THE SPEAKER IS NEVER TALKING TO YOU"))
        XCTAssertTrue(system.contains("What's the capital of France?"))
        XCTAssertTrue(system.contains("WhisperLocal"))
        XCTAssertTrue(system.contains("Grok Bot"))
        XCTAssertFalse(system.contains("{{agentName}}"))
        XCTAssertFalse(system.contains("Changho Choi"))
        XCTAssertFalse(system.contains("CUSTOM INSTRUCTIONS"))
    }

    func testPersonalContextIsInjected() {
        XCTAssertTrue(CleanupPrompt.defaultPersonalContext.contains("Changho Choi"))
        let personalized = CleanupPrompt.system(personalContext: CleanupPrompt.defaultPersonalContext)
        XCTAssertTrue(personalized.contains("CUSTOM INSTRUCTIONS"))
        XCTAssertTrue(personalized.contains("Changho Choi"))
        XCTAssertTrue(personalized.contains("MambaEye follow-up for ICLR 2027."))
        let empty = CleanupPrompt.system(personalContext: "   ")
        XCTAssertFalse(empty.contains("CUSTOM INSTRUCTIONS"))
    }

    func testDictionarySuffix() {
        let withTerm = CleanupPrompt.system(dictionary: ["WhisperKit"])
        XCTAssertTrue(withTerm.hasSuffix("Custom Dictionary (use these exact spellings when they appear in the text): WhisperKit"))
        let empty = CleanupPrompt.system(dictionary: [])
        XCTAssertFalse(empty.contains("exact spellings when they appear in the text"))
    }

    func testDictionaryDoesNotForceStarterTerms() {
        XCTAssertEqual(CleanupPrompt.mergedDictionary(["WhisperKit", " whisperkit ", ""]), ["WhisperKit"])
        XCTAssertEqual(CleanupPrompt.mergedDictionary([]), [])
    }
}

final class CloudModelCatalogTests: XCTestCase {
    func testFiltersOpenAIChatModels() {
        XCTAssertTrue(CloudModelCatalog.isOpenAIChatModel("gpt-4o-mini"))
        XCTAssertTrue(CloudModelCatalog.isOpenAIChatModel("gpt-5.6-luna"))
        XCTAssertTrue(CloudModelCatalog.isOpenAIChatModel("o3-mini"))
        XCTAssertFalse(CloudModelCatalog.isOpenAIChatModel("whisper-1"))
        XCTAssertFalse(CloudModelCatalog.isOpenAIChatModel("text-embedding-3-small"))
        XCTAssertFalse(CloudModelCatalog.isOpenAIChatModel("dall-e-3"))
        XCTAssertFalse(CloudModelCatalog.isOpenAIChatModel("gpt-image-1"))
        XCTAssertFalse(CloudModelCatalog.isOpenAIChatModel("tts-1"))
    }

    func testTemperatureSupport() {
        XCTAssertTrue(CloudModelCatalog.supportsChatTemperature("gpt-4o-mini"))
        XCTAssertTrue(CloudModelCatalog.supportsChatTemperature("gpt-4.1"))
        XCTAssertFalse(CloudModelCatalog.supportsChatTemperature("gpt-5.6-luna"))
        XCTAssertFalse(CloudModelCatalog.supportsChatTemperature("o3-mini"))
    }

    func testParsesOpenAIModelList() throws {
        let json = """
        {"data":[{"id":"gpt-4o-mini"},{"id":"whisper-1"},{"id":"gpt-5.6-luna"}]}
        """.data(using: .utf8)!
        let ids = try CloudModelCatalog.parseOpenAIModelIDs(from: json)
        XCTAssertEqual(ids, ["gpt-4o-mini", "whisper-1", "gpt-5.6-luna"])
    }

    func testParsesAnthropicModelPage() throws {
        let json = """
        {"data":[{"id":"claude-haiku-4-5","display_name":"Claude Haiku 4.5"},{"id":"claude-sonnet-5"}],"has_more":false,"last_id":"claude-sonnet-5"}
        """.data(using: .utf8)!
        let page = try CloudModelCatalog.parseAnthropicModelsPage(from: json)
        XCTAssertEqual(page.ids, ["claude-haiku-4-5", "claude-sonnet-5"])
        XCTAssertEqual(page.models.first?.displayName, "Claude Haiku 4.5")
        XCTAssertFalse(page.hasMore)
        XCTAssertEqual(page.lastID, "claude-sonnet-5")
    }

    func testPrettyDisplayName() {
        XCTAssertEqual(CloudModelCatalog.prettyDisplayName(for: "gpt-4o-mini"), "GPT 4o Mini")
        XCTAssertEqual(CloudModelCatalog.prettyDisplayName(for: "gpt-5.6-luna"), "GPT 5.6 Luna")
    }

    func testMergePutsRecommendedFirst() {
        let recommended = CloudModelCatalog.openAIRecommended
        let fetched = [
            CloudModelOption(id: "gpt-4o", displayName: "GPT-4o"),
            CloudModelOption(id: "gpt-4o-mini", displayName: "GPT-4o Mini"),
            CloudModelOption(id: "gpt-special", displayName: "Special")
        ]
        let merged = CloudModelCatalog.mergeForPicker(recommended: recommended, fetched: fetched)
        XCTAssertEqual(merged.map(\.id).prefix(2), ["gpt-4o-mini", "gpt-4o"])
        XCTAssertTrue(merged.contains(where: { $0.id == "gpt-special" }))
        XCTAssertFalse(merged.contains(where: { $0.id == "gpt-5.6-luna" }))
    }
}
