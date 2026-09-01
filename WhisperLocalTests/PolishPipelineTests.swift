import XCTest

final class VocalFillerFilterTests: XCTestCase {
    func testVocalFillerSounds() {
        XCTAssertEqual(VocalFillerFilter.strip("um hello hmm there uh"), "hello there")
        XCTAssertEqual(VocalFillerFilter.strip("Um, I think, uh, we should go."), "I think, we should go.")
        XCTAssertEqual(VocalFillerFilter.strip("Hmm. Let's start"), "Let's start")
        XCTAssertEqual(VocalFillerFilter.strip("I like coffee"), "I like coffee")
    }

    func testKeepsMillimetreUnitAfterANumber() {
        XCTAssertEqual(VocalFillerFilter.strip("the gap is 5 mm"), "the gap is 5 mm")
        XCTAssertEqual(VocalFillerFilter.strip("shot it on a 50 mm lens"), "shot it on a 50 mm lens")
        XCTAssertEqual(VocalFillerFilter.strip("a 3.5 mm jack"), "a 3.5 mm jack")
        XCTAssertEqual(VocalFillerFilter.strip("shot it on a 50mm lens"), "shot it on a 50mm lens")
    }

    func testStillStripsMMAsAVocalizedPause() {
        XCTAssertEqual(VocalFillerFilter.strip("mm I see what you mean"), "I see what you mean")
        XCTAssertEqual(VocalFillerFilter.strip("well, mm, I think so"), "well, I think so")
        XCTAssertEqual(VocalFillerFilter.strip("mhm that works"), "that works")
    }
}

final class PolishPipelineTests: XCTestCase {
    func testPipelineWithoutLLMStillStripsFillers() async {
        let pipeline = PolishPipeline(
            localLLM: nil,
            cloud: nil,
            useLocalLLM: false,
            enableTextCleanup: true,
            dictionary: []
        )
        let result = await pipeline.run("um hello there")
        XCTAssertEqual(result.text, "hello there")
        XCTAssertFalse(result.cleanupFailed)
        XCTAssertEqual(result.stages, ["Fillers"])
    }

    func testPipelineCanSkipCleanup() async {
        let pipeline = PolishPipeline(
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

    func testPipelineUsesLLMAfterFillers() async {
        let local = ProbePolisher(name: "Gemma 4 E2B")
        let pipeline = PolishPipeline(
            localLLM: local,
            cloud: nil,
            useLocalLLM: true,
            enableTextCleanup: true,
            dictionary: []
        )
        let result = await pipeline.run("um hello there")
        XCTAssertEqual(local.callCount, 1)
        XCTAssertEqual(result.text, "hello there")
        XCTAssertEqual(result.stages, ["Fillers", "Gemma 4 E2B"])
        XCTAssertFalse(result.cleanupFailed)
    }

    func testPipelineSkipsAppleIntelligenceWhenCloudIsOn() async {
        let local = ProbePolisher(name: "Apple Intelligence")
        let cloud = ProbePolisher(name: "OpenAI")
        let pipeline = PolishPipeline(
            localLLM: local,
            cloud: cloud,
            useLocalLLM: true,
            enableTextCleanup: true,
            dictionary: []
        )
        let result = await pipeline.run("hello")
        XCTAssertEqual(local.callCount, 0)
        XCTAssertEqual(cloud.callCount, 1)
        XCTAssertEqual(result.stages, ["OpenAI"])
        XCTAssertFalse(result.cleanupFailed)
    }

    func testPipelineUsesAppleIntelligenceWhenCloudIsOff() async {
        let local = ProbePolisher(name: "Apple Intelligence")
        let pipeline = PolishPipeline(
            localLLM: local,
            cloud: nil,
            useLocalLLM: true,
            enableTextCleanup: true,
            dictionary: []
        )
        let result = await pipeline.run("hello")
        XCTAssertEqual(local.callCount, 1)
        XCTAssertEqual(result.stages, ["Apple Intelligence"])
    }

    func testPipelinePassesTargetAppToLLM() async {
        let local = ProbePolisher(name: "Apple Intelligence")
        let pipeline = PolishPipeline(
            localLLM: local,
            cloud: nil,
            useLocalLLM: true,
            enableTextCleanup: true,
            dictionary: []
        )
        _ = await pipeline.run("hello", targetApp: "Cursor — code editor")
        XCTAssertEqual(local.lastTargetApp, "Cursor — code editor")
    }

    func testPipelinePassesSessionIntentToLLM() async {
        let local = ProbePolisher(name: "Apple Intelligence")
        let pipeline = PolishPipeline(
            localLLM: local,
            cloud: nil,
            useLocalLLM: true,
            enableTextCleanup: true,
            dictionary: [],
            sessionIntent: "I'm writing the MambaEye paper"
        )
        let result = await pipeline.run("hello")
        XCTAssertEqual(local.lastSessionIntent, "I'm writing the MambaEye paper")
        XCTAssertNil(result.contextRelevant)
    }

    func testPipelineSurfacesAppleIntelligenceContextJudgment() async {
        let local = JudgmentPolisher(relevant: false)
        let pipeline = PolishPipeline(
            localLLM: local,
            cloud: nil,
            useLocalLLM: true,
            enableTextCleanup: true,
            dictionary: [],
            sessionIntent: "MambaEye paper"
        )
        let result = await pipeline.run("hello")
        XCTAssertEqual(result.contextRelevant, false)
    }

    func testPipelineCloudDoesNotJudgeSessionContext() async {
        let local = JudgmentPolisher(relevant: false)
        let cloud = ProbePolisher(name: "OpenAI")
        let pipeline = PolishPipeline(
            localLLM: local,
            cloud: cloud,
            useLocalLLM: true,
            enableTextCleanup: true,
            dictionary: [],
            sessionIntent: "MambaEye paper"
        )
        let result = await pipeline.run("hello")
        XCTAssertNil(result.contextRelevant)
        XCTAssertEqual(cloud.lastSessionIntent, "MambaEye paper")
    }

    func testPipelineStripsFillersTheModelLeftIn() async {
        let local = FillerReinjectingPolisher()
        let pipeline = PolishPipeline(
            localLLM: local,
            cloud: nil,
            useLocalLLM: true,
            enableTextCleanup: true,
            dictionary: []
        )
        let result = await pipeline.run("hello there")
        XCTAssertEqual(result.text, "hello there")
        XCTAssertEqual(result.stages, ["Apple Intelligence", "Fillers"])
        XCTAssertFalse(result.cleanupFailed)
    }

    func testPipelineTruncationFailOpensWithCutShortNote() async {
        let local = TruncatingPolisher()
        let pipeline = PolishPipeline(
            localLLM: local,
            cloud: nil,
            useLocalLLM: true,
            enableTextCleanup: true,
            dictionary: []
        )
        let result = await pipeline.run("hello there")
        XCTAssertEqual(result.text, "hello there")
        XCTAssertTrue(result.cleanupFailed)
        XCTAssertEqual(result.cleanupNote, "Cleanup was cut short. Pasted without AI cleanup.")
        XCTAssertEqual(result.stages, ["Apple Intelligence failed"])
        XCTAssertNil(result.contextRelevant)
    }

    func testPolishTruncationHelpers() {
        XCTAssertTrue(PolishOutput.openaiHitLengthCap("length"))
        XCTAssertFalse(PolishOutput.openaiHitLengthCap("stop"))
        XCTAssertTrue(PolishOutput.anthropicHitTokenCap("max_tokens"))
        XCTAssertFalse(PolishOutput.anthropicHitTokenCap("end_turn"))
        XCTAssertEqual(PolishOutput.maxOutputTokens(for: "hi"), 256)
        XCTAssertEqual(PolisherError.truncated.pasteNote, "Cleanup was cut short. Pasted without AI cleanup.")
    }
}

private final class JudgmentPolisher: TextPolisher {
    let name = "Apple Intelligence"
    let relevant: Bool

    init(relevant: Bool) {
        self.relevant = relevant
    }

    func polish(
        _ text: String,
        dictionary _: [String],
        personalContext _: String,
        targetApp _: String?,
        recentDictations _: String,
        sessionIntent _: String
    ) async throws -> PolishedText {
        PolishedText(text: text, contextRelevant: relevant)
    }
}

private final class TruncatingPolisher: TextPolisher {
    let name = "Apple Intelligence"

    func polish(
        _ text: String,
        dictionary _: [String],
        personalContext _: String,
        targetApp _: String?,
        recentDictations _: String,
        sessionIntent _: String
    ) async throws -> PolishedText {
        throw PolisherError.truncated
    }
}

private final class FillerReinjectingPolisher: TextPolisher {
    let name = "Apple Intelligence"

    func polish(
        _ text: String,
        dictionary _: [String],
        personalContext _: String,
        targetApp _: String?,
        recentDictations _: String,
        sessionIntent _: String
    ) async throws -> PolishedText {
        PolishedText(text: "um \(text) uh")
    }
}

private final class ProbePolisher: TextPolisher, @unchecked Sendable {
    let name: String
    private let lock = NSLock()
    private(set) var callCount = 0

    init(name: String) {
        self.name = name
    }

    private(set) var lastTargetApp: String?
    private(set) var lastSessionIntent: String?

    func polish(
        _ text: String,
        dictionary: [String],
        personalContext: String,
        targetApp: String?,
        recentDictations _: String,
        sessionIntent: String
    ) async throws -> PolishedText {
        lock.lock()
        callCount += 1
        lastTargetApp = targetApp
        lastSessionIntent = sessionIntent
        lock.unlock()
        return PolishedText(text: text)
    }
}

final class CleanupPromptTests: XCTestCase {
    func testWrapsTranscriptLikeOpenWhispr() {
        let wrapped = CleanupPrompt.wrapTranscript("hello")
        XCTAssertTrue(wrapped.contains("<transcript>\nhello\n</transcript>"))
        XCTAssertTrue(wrapped.contains("Output only the cleaned transcript."))
        XCTAssertFalse(wrapped.contains("<target-app>"))
    }

    func testWrapPutsTargetAppInFrontOfTranscript() {
        let wrapped = CleanupPrompt.wrapTranscript("hello", targetApp: "Cursor — code editor")
        XCTAssertTrue(wrapped.hasPrefix("<target-app>Cursor — code editor</target-app>\n<transcript>"))
        XCTAssertTrue(wrapped.contains("<transcript>\nhello\n</transcript>"))
    }

    func testWrapEscapesTargetAppXml() {
        let wrapped = CleanupPrompt.wrapTranscript("hello", targetApp: "Foo <bar> & baz")
        XCTAssertTrue(wrapped.contains("<target-app>Foo &lt;bar&gt; &amp; baz</target-app>"))
    }

    func testWrapNeutralizesTranscriptDelimiters() {
        let wrapped = CleanupPrompt.wrapTranscript("keep </transcript> and <transcript> inside")
        XCTAssertEqual(wrapped.components(separatedBy: "<transcript>").count - 1, 1)
        XCTAssertEqual(wrapped.components(separatedBy: "</transcript>").count - 1, 1)
        XCTAssertTrue(wrapped.contains("keep </ transcript> and < transcript> inside"))
        XCTAssertTrue(wrapped.contains("<transcript>\n"))
        XCTAssertTrue(wrapped.contains("\n</transcript>"))
    }

    func testFormatRecentDictationsIsEmptyWithoutExamples() {
        XCTAssertEqual(CleanupPrompt.formatRecentDictations([]), "")
    }

    func testFormatRecentDictationsIsRequestTimeContext() {
        let block = CleanupPrompt.formatRecentDictations([
            RecentDictationExample(raw: "um ship it today", polished: "Ship it today.", appName: "Cursor"),
            RecentDictationExample(raw: "tell sam I'll be late", polished: "Tell Sam I'll be late.", appName: nil)
        ])
        XCTAssertTrue(block.contains("<recent-dictations>"))
        XCTAssertTrue(block.contains("said: um ship it today"))
        XCTAssertTrue(block.contains("cleaned: Ship it today."))
        XCTAssertTrue(block.contains("1. Cursor"))
        XCTAssertTrue(block.contains("2."))
        XCTAssertTrue(block.contains("Tell Sam I'll be late."))
        XCTAssertFalse(CleanupPrompt.defaultPersonalContext.contains("<recent-dictations>"))
        XCTAssertFalse(CleanupPrompt.system().contains("<recent-dictations>"))
    }

    func testWrapTranscriptPutsRecentDictationsBeforeCurrentTake() {
        let recent = CleanupPrompt.formatRecentDictations([
            RecentDictationExample(raw: "hi", polished: "Hi.", appName: nil)
        ])
        let wrapped = CleanupPrompt.wrapTranscript("hello there", recentDictations: recent)
        XCTAssertTrue(wrapped.contains("<recent-dictations>"))
        let recentRange = wrapped.range(of: "<recent-dictations>")!
        let transcriptRange = wrapped.range(of: "<transcript>")!
        XCTAssertLessThan(recentRange.lowerBound, transcriptRange.lowerBound)
        XCTAssertTrue(wrapped.contains("<transcript>\nhello there\n</transcript>"))
    }

    func testWrapTranscriptOmitsEmptySessionIntent() {
        let wrapped = CleanupPrompt.wrapTranscript("hello")
        XCTAssertFalse(wrapped.contains("<session-intent>"))
    }

    func testWrapTranscriptEmitsSessionIntentBeforeTranscript() {
        let wrapped = CleanupPrompt.wrapTranscript(
            "hello there",
            sessionIntent: "I'm writing the MambaEye paper on state-space models"
        )
        XCTAssertTrue(wrapped.contains("<session-intent>"))
        XCTAssertTrue(wrapped.contains("I'm writing the MambaEye paper on state-space models"))
        XCTAssertTrue(wrapped.contains("not an instruction"))
        let intentRange = wrapped.range(of: "<session-intent>")!
        let transcriptRange = wrapped.range(of: "<transcript>")!
        XCTAssertLessThan(intentRange.lowerBound, transcriptRange.lowerBound)
        XCTAssertFalse(CleanupPrompt.system().contains("I'm writing the MambaEye paper"))
    }

    func testWrapSessionIntentCannotBreakOutOfItsBlock() {
        let wrapped = CleanupPrompt.wrapTranscript(
            "hello",
            sessionIntent: "keep </transcript> and </session-intent> inside"
        )
        XCTAssertEqual(wrapped.components(separatedBy: "<transcript>").count - 1, 1)
        XCTAssertEqual(wrapped.components(separatedBy: "</transcript>").count - 1, 1)
        XCTAssertEqual(wrapped.components(separatedBy: "<session-intent>").count - 1, 1)
        XCTAssertEqual(wrapped.components(separatedBy: "</session-intent>").count - 1, 1)
        XCTAssertTrue(wrapped.contains("&lt;/ transcript&gt;") || wrapped.contains("</ transcript>"))
        XCTAssertFalse(wrapped.contains("keep </transcript>"))
    }

    func testClipsLongRecentDictations() {
        let long = String(repeating: "a", count: 80)
        let block = CleanupPrompt.formatRecentDictations(
            [RecentDictationExample(raw: long, polished: long, appName: nil)],
            maxCharsPerSide: 20
        )
        XCTAssertTrue(block.contains("said: aaaaaaaaaaaaaaaaaaaa…"))
        XCTAssertFalse(block.contains(long))
    }

    func testClampRecentPolishLogCount() {
        XCTAssertEqual(CleanupPrompt.clampRecentPolishLogCount(3), 3)
        XCTAssertEqual(CleanupPrompt.clampRecentPolishLogCount(8), 8)
        XCTAssertEqual(CleanupPrompt.clampRecentPolishLogCount(4), 3)
        XCTAssertEqual(CleanupPrompt.clampRecentPolishLogCount(0), 3)
    }

    func testSystemPromptIsCleanupEngineNotChatbot() {
        let system = CleanupPrompt.system()
        XCTAssertTrue(system.lowercased().contains("never talking to you"))
        XCTAssertTrue(system.contains("I think we should go."))
        XCTAssertTrue(system.contains("I wanted to email Sarah."))
        XCTAssertTrue(system.lowercased().contains("cancel a phrase"))
        XCTAssertTrue(system.lowercased().contains("restart a sentence"))
        XCTAssertTrue(system.contains("WhisperLocal"))
        XCTAssertTrue(system.contains("ChatGPT"))
        XCTAssertTrue(system.contains("<target-app>"))
        XCTAssertTrue(system.contains("<app-notes>"))
        XCTAssertTrue(system.contains("poem about the ocean"))
        XCTAssertTrue(system.lowercased().contains("dictating into"))
        XCTAssertTrue(system.contains("<session-intent>"))
        XCTAssertLessThan(system.count, 1450)
        XCTAssertFalse(system.contains("{{agentName}}"))
        XCTAssertFalse(system.contains("Changho Choi"))
        XCTAssertFalse(system.contains("CUSTOM INSTRUCTIONS"))
    }

    func testPersonalContextIsInjected() {
        XCTAssertTrue(CleanupPrompt.defaultPersonalContext.contains("PERSONAL"))
        XCTAssertTrue(CleanupPrompt.defaultPersonalContext.contains("EXAMPLES"))
        XCTAssertTrue(CleanupPrompt.defaultPersonalContext.contains("EXCEPTIONS"))
        let personalized = CleanupPrompt.system(personalContext: CleanupPrompt.defaultPersonalContext)
        XCTAssertTrue(personalized.contains("CUSTOM INSTRUCTIONS"))
        XCTAssertTrue(personalized.contains("PERSONAL"))
        XCTAssertTrue(personalized.contains("EXAMPLES"))
        XCTAssertTrue(personalized.contains("EXCEPTIONS"))
        XCTAssertTrue(personalized.contains("Cursor / VS Code"))
        XCTAssertTrue(personalized.contains("match <target-app>"))
        let empty = CleanupPrompt.system(personalContext: "   ")
        XCTAssertFalse(empty.contains("CUSTOM INSTRUCTIONS"))
    }

    func testFactoryDefaultsStayGenericUnlessPrivateOverlay() {
        let notes = CleanupPrompt.defaultPersonalNotes
        let context = CleanupPrompt.defaultPersonalContext
        if notes.contains("Changho Choi") {
            XCTAssertTrue(context.contains("Changho Choi"))
            return
        }
        XCTAssertTrue(context.contains("Fill this in"))
        XCTAssertTrue(context.contains("Email Alex about the draft"))
        XCTAssertFalse(context.contains("@gmail.com"))
        XCTAssertFalse(context.contains("Changho Choi"))
        XCTAssertTrue(CleanupPrompt.defaultPersonalExamples.contains("WhisperKit follow-up for the next release."))
    }

    func testDictionarySuffix() {
        let withTerm = CleanupPrompt.system(dictionary: ["WhisperKit"])
        XCTAssertTrue(withTerm.hasSuffix("Custom Dictionary (exact spellings; rejoin if ASR split them): WhisperKit"))
        let empty = CleanupPrompt.system(dictionary: [])
        XCTAssertFalse(empty.contains("exact spellings; rejoin if ASR split them"))
    }

    func testDictionaryDoesNotForceStarterTerms() {
        XCTAssertEqual(CleanupPrompt.mergedDictionary(["WhisperKit", " whisperkit ", ""]), ["WhisperKit"])
        XCTAssertEqual(CleanupPrompt.mergedDictionary([]), [])
    }

    func testCompactSystemIsShorterButStillACleanupEngine() {
        let compact = CleanupPrompt.compactSystem()
        let full = CleanupPrompt.system()
        XCTAssertEqual(compact, full)
        XCTAssertTrue(compact.lowercased().contains("never talking to you"))
        XCTAssertTrue(compact.contains("I think we should go."))
        XCTAssertTrue(compact.contains("I wanted to email Sarah."))
        XCTAssertTrue(compact.contains("<target-app>"))
        XCTAssertTrue(compact.contains("<app-notes>"))
        XCTAssertFalse(compact.contains("Changho Choi"))
        let personalized = CleanupPrompt.compactSystem(personalContext: "Keep KST.")
        XCTAssertTrue(personalized.contains("CUSTOM INSTRUCTIONS"))
        XCTAssertTrue(personalized.contains("Keep KST."))
        XCTAssertLessThan(
            CleanupPrompt.defaultPersonalNotes.count,
            CleanupPrompt.legacyDefaultPersonalNotes.count
        )
    }

    func testOnDeviceSystemDropsAllAppsDump() {
        let baked = CleanupPrompt.assembleUserLayers(
            personalNotes: "Keep KST.",
            exceptions: "- Cursor: keep comments tight.\n- Mail: light letter polish.",
            appDictionaries: [
                AppDictionaryEntry(appName: "Cursor", kind: "code editor", terms: ["mlx-swift"]),
                AppDictionaryEntry(appName: "Mail", kind: "mail app", terms: ["Jinkyu Kim"])
            ]
        )
        let onDevice = CleanupPrompt.onDeviceSystem(personalContext: baked)
        XCTAssertTrue(onDevice.contains("Keep KST."))
        XCTAssertFalse(onDevice.contains("mlx-swift"))
        XCTAssertFalse(onDevice.contains("light letter polish"))
        XCTAssertFalse(onDevice.contains("Jinkyu Kim"))
        XCTAssertLessThan(onDevice.count, CleanupPrompt.system(personalContext: baked).count)
    }

    func testOnDeviceWrapKeepsOnlyMatchingAppNotes() {
        let baked = CleanupPrompt.assembleUserLayers(
            personalNotes: "Keep KST.",
            exceptions: "- Cursor: keep comments tight.\n- Mail: light letter polish.",
            appDictionaries: [
                AppDictionaryEntry(appName: "Cursor", kind: "code editor", terms: ["mlx-swift"]),
                AppDictionaryEntry(appName: "Mail", kind: "mail app", terms: ["Jinkyu Kim"])
            ]
        )
        let wrapped = CleanupPrompt.wrapOnDeviceTranscript(
            "hello",
            targetApp: "Cursor — code editor",
            personalContext: baked
        )
        XCTAssertTrue(wrapped.contains("<target-app>Cursor — code editor</target-app>"))
        XCTAssertTrue(wrapped.contains("keep comments tight"))
        XCTAssertTrue(wrapped.contains("mlx-swift"))
        XCTAssertFalse(wrapped.contains("light letter polish"))
        XCTAssertFalse(wrapped.contains("Jinkyu Kim"))
    }

    func testAssembleUserLayersOmitsEmptySections() {
        let personalOnly = CleanupPrompt.assembleUserLayers(
            personalNotes: "Keep KST.",
            exceptions: "  ",
            appDictionaries: []
        )
        XCTAssertTrue(personalOnly.hasPrefix("PERSONAL\nKeep KST."))
        XCTAssertFalse(personalOnly.contains("EXCEPTIONS"))
        XCTAssertFalse(personalOnly.contains("EXAMPLES"))
        XCTAssertFalse(personalOnly.contains("PER-APP DICTIONARY"))

        let withExamples = CleanupPrompt.assembleUserLayers(
            personalNotes: "Keep KST.",
            exceptions: "",
            appDictionaries: [],
            examples: "mamba eye → MambaEye"
        )
        XCTAssertTrue(withExamples.contains("PERSONAL\nKeep KST."))
        XCTAssertTrue(withExamples.contains("EXAMPLES\nmamba eye → MambaEye"))
        XCTAssertFalse(withExamples.contains("EXCEPTIONS"))

        let withDict = CleanupPrompt.assembleUserLayers(
            personalNotes: "",
            exceptions: "In Slack stay casual.",
            appDictionaries: [
                AppDictionaryEntry(appName: "Cursor", kind: "code editor", terms: ["WhisperKit", "mlx-swift"])
            ]
        )
        XCTAssertTrue(withDict.contains("EXCEPTIONS\n\(CleanupPrompt.hiddenExceptionRule)\nIn Slack stay casual."))
        XCTAssertTrue(withDict.contains("PER-APP DICTIONARY"))
        XCTAssertTrue(withDict.contains("- Cursor — code editor: WhisperKit, mlx-swift"))
    }

    func testSplitNotesAndExamples() {
        let combined = """
        Keep KST.

        Examples:
        mamba eye → MambaEye
        """
        let split = CleanupPrompt.splitNotesAndExamples(combined)
        XCTAssertEqual(split.notes, "Keep KST.")
        XCTAssertEqual(split.examples, "mamba eye → MambaEye")
        XCTAssertFalse(CleanupPrompt.defaultPersonalNotes.contains("Examples:"))
        XCTAssertFalse(CleanupPrompt.defaultPersonalExamples.isEmpty)
        let none = CleanupPrompt.splitNotesAndExamples("Keep KST.")
        XCTAssertEqual(none.notes, "Keep KST.")
        XCTAssertEqual(none.examples, "")
    }

    func testExceptionBoilerplateIsHiddenFromUserDrafts() {
        XCTAssertFalse(CleanupPrompt.defaultExceptions.contains("<target-app>"))
        XCTAssertTrue(CleanupPrompt.defaultExceptions.contains("- Cursor / VS Code"))
        let assembled = CleanupPrompt.assembleUserLayers(
            personalNotes: "",
            exceptions: CleanupPrompt.defaultExceptions,
            appDictionaries: []
        )
        XCTAssertTrue(assembled.contains(CleanupPrompt.hiddenExceptionRule))
        XCTAssertEqual(
            CleanupPrompt.strippedUserExceptions(
                "Apply only the notes that match <target-app>. Ignore the rest.\n- In Cursor keep comments tight."
            ),
            "- In Cursor keep comments tight."
        )
    }

    func testSplitLegacyKeepsExamplesInPersonalNotes() {
        let blob = """
        SPEAKER
        Hello.

        PER APP
        In Cursor keep comments tight.

        EXAMPLES
        Input: hi
        Output: Hi.
        """
        let split = CleanupPrompt.splitLegacyPersonalContext(blob)
        XCTAssertTrue(split.notes.contains("SPEAKER"))
        XCTAssertTrue(split.notes.contains("EXAMPLES"))
        XCTAssertTrue(split.notes.contains("Input: hi"))
        XCTAssertFalse(split.notes.contains("PER APP"))
        XCTAssertTrue(split.exceptions.contains("In Cursor keep comments tight."))
        XCTAssertFalse(split.exceptions.contains("Apply only the notes"))
        XCTAssertFalse(split.exceptions.contains("EXAMPLES"))
    }

    func testSettingsGeneratorPromptIsPasteReadyAndGeneric() {
        let prompt = CleanupPrompt.settingsGeneratorPrompt()
        XCTAssertTrue(prompt.contains("=== ABOUT YOU ==="))
        XCTAssertTrue(prompt.contains("=== EXAMPLES ==="))
        XCTAssertTrue(prompt.contains("=== EXCEPTIONS ==="))
        XCTAssertTrue(prompt.contains("=== DICTIONARY CSV ==="))
        XCTAssertTrue(prompt.contains(DictionaryCSV.header))
        XCTAssertTrue(prompt.contains("Save system prompt"))
        XCTAssertTrue(prompt.contains("Import CSV"))
        XCTAssertTrue(prompt.contains("raw dictation → cleaned text"))
        XCTAssertFalse(prompt.contains("Changho Choi"))
        XCTAssertFalse(prompt.contains("@gmail.com"))
        XCTAssertFalse(prompt.contains("CURRENT ABOUT YOU"))
        let withDrafts = CleanupPrompt.settingsGeneratorPrompt(
            personalNotes: "Keep UTC.",
            examples: "hi there → Hi there.",
            exceptions: "- Slack: keep casual.",
            dictionaryCSV: "app,kind,word,exception\n,,WhisperKit,"
        )
        XCTAssertTrue(withDrafts.contains("CURRENT ABOUT YOU"))
        XCTAssertTrue(withDrafts.contains("Keep UTC."))
        XCTAssertTrue(withDrafts.contains("hi there → Hi there."))
        XCTAssertTrue(withDrafts.contains("- Slack: keep casual."))
        XCTAssertTrue(withDrafts.contains(",,WhisperKit,"))
    }

    func testMatchingAppDictionaryUsesFocusedAppName() {
        let entries = [
            AppDictionaryEntry(appName: "Cursor", kind: "code editor", terms: ["WhisperKit"]),
            AppDictionaryEntry(appName: "Slack", kind: "chat app", terms: ["standup"])
        ]
        XCTAssertEqual(
            CleanupPrompt.matchingDictionaryTerms(in: entries, targetApp: "Cursor — code editor"),
            ["WhisperKit"]
        )
        XCTAssertEqual(
            CleanupPrompt.matchingDictionaryTerms(in: entries, targetApp: "Slack — chat app"),
            ["standup"]
        )
        XCTAssertEqual(
            CleanupPrompt.matchingDictionaryTerms(in: entries, targetApp: "Safari — browser"),
            []
        )
    }
}

final class DictionaryCSVTests: XCTestCase {
    func testParsesEveryAppAndPerAppRows() throws {
        let csv = """
        app,kind,word,exception
        ,,WhisperKit,
        Cursor,code editor,mlx-swift,keep comments tight
        Cursor,code editor,Gemma,
        Slack,chat app,standup,keep casual
        """
        let snapshot = try DictionaryCSV.parse(csv)
        XCTAssertEqual(snapshot.globalWords, ["WhisperKit"])
        XCTAssertEqual(snapshot.apps.map(\.appName), ["Cursor", "Slack"])
        XCTAssertEqual(snapshot.apps[0].terms, ["mlx-swift", "Gemma"])
        XCTAssertEqual(snapshot.apps[0].kind, "code editor")
        XCTAssertEqual(snapshot.exceptionsByApp["Cursor"], "keep comments tight")
        XCTAssertEqual(snapshot.exceptionsByApp["Slack"], "keep casual")
    }

    func testIgnoresCommentsAndAcceptsQuotedCommas() throws {
        let csv = """
        # WhisperLocal dictionary CSV
        # kind: code editor, chat app, browser, terminal, mail app, notes app, app
        # Empty app = words for every app. One word per row, or separate several with ;
        app,kind,word,exception
        Cursor,code editor,"foo, bar","tight, no fences"
        """
        let snapshot = try DictionaryCSV.parse(csv)
        XCTAssertEqual(snapshot.apps.map(\.appName), ["Cursor"])
        XCTAssertEqual(snapshot.apps.first?.terms, ["foo, bar"])
        XCTAssertEqual(snapshot.exceptionsByApp["Cursor"], "tight, no fences")
        XCTAssertFalse(snapshot.apps.contains(where: { $0.appName.hasPrefix("#") }))
    }

    func testTemplateDoesNotImportHashNotesAsApps() throws {
        let snapshot = try DictionaryCSV.parse(DictionaryCSV.template)
        XCTAssertTrue(snapshot.globalWords.contains("WhisperLocal"))
        XCTAssertTrue(snapshot.apps.contains(where: { $0.appName == "Cursor" }))
        XCTAssertFalse(snapshot.apps.contains(where: { $0.appName.hasPrefix("#") }))
        XCTAssertFalse(snapshot.apps.contains(where: { $0.appName.localizedCaseInsensitiveContains("kind:") }))
    }

    func testRoundTripExportParse() throws {
        let apps = [
            AppDictionaryEntry(appName: "Cursor", kind: "code editor", terms: ["WhisperKit"]),
            AppDictionaryEntry(appName: "Slack", kind: "chat app", terms: ["standup"])
        ]
        let text = DictionaryCSV.export(
            globalWords: ["WhisperLocal"],
            apps: apps,
            exceptions: "- Cursor: keep comments tight\n- Slack: keep casual"
        )
        let snapshot = try DictionaryCSV.parse(text)
        XCTAssertEqual(snapshot.globalWords, ["WhisperLocal"])
        XCTAssertEqual(
            snapshot.apps.first(where: { $0.appName == "Cursor" })?.terms,
            ["WhisperKit"]
        )
        XCTAssertEqual(snapshot.exceptionsByApp["Cursor"], "keep comments tight")
    }

    func testTemplateIsImportable() throws {
        let snapshot = try DictionaryCSV.parse(DictionaryCSV.template)
        XCTAssertTrue(snapshot.globalWords.contains("WhisperLocal"))
        XCTAssertTrue(snapshot.apps.contains(where: { $0.appName == "Cursor" }))
        XCTAssertEqual(
            snapshot.apps.filter { $0.appName.hasPrefix("#") }.map(\.appName),
            []
        )
    }

    func testMergeExceptionsReplacesMatchingBullet() {
        let merged = DictionaryCSV.mergeExceptions(
            existing: "- Cursor / VS Code / Xcode: old rule.\n- Mail: light letter polish.",
            byApp: ["Cursor": "keep comments tight"]
        )
        XCTAssertTrue(merged.contains("- Cursor: keep comments tight"))
        XCTAssertFalse(merged.contains("old rule"))
        XCTAssertTrue(merged.contains("- Mail: light letter polish."))
    }
}

final class TargetAppContextTests: XCTestCase {
    func testKindFromKnownBundleIDs() {
        XCTAssertEqual(
            TargetAppContext.kind(bundleID: "com.anysphere.cursor", name: "Cursor"),
            .codeEditor
        )
        XCTAssertEqual(
            TargetAppContext.kind(bundleID: "com.microsoft.VSCode", name: "Code"),
            .codeEditor
        )
        XCTAssertEqual(
            TargetAppContext.kind(bundleID: "com.tinyspeck.slackmacgap", name: "Slack"),
            .chat
        )
        XCTAssertEqual(
            TargetAppContext.kind(bundleID: "com.apple.Safari", name: "Safari"),
            .browser
        )
        XCTAssertEqual(
            TargetAppContext.kind(bundleID: "com.apple.Terminal", name: "Terminal"),
            .terminal
        )
        XCTAssertEqual(
            TargetAppContext.kind(bundleID: "com.apple.mail", name: "Mail"),
            .mail
        )
        XCTAssertEqual(
            TargetAppContext.kind(bundleID: "com.apple.Notes", name: "Notes"),
            .notes
        )
        XCTAssertEqual(
            TargetAppContext.kind(bundleID: "com.example.unknown", name: "Mystery"),
            .other
        )
    }

    func testPromptLineOmitsKindForUnknownApps() {
        let cursor = TargetAppContext(name: "Cursor", bundleID: "com.anysphere.cursor", kind: .codeEditor)
        XCTAssertEqual(cursor.promptLine, "Cursor — code editor")
        let other = TargetAppContext(name: "Mystery", bundleID: "com.example.unknown", kind: .other)
        XCTAssertEqual(other.promptLine, "Mystery")
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

final class PolishOutputTests: XCTestCase {
    func testStripsMarkdownFence() {
        XCTAssertEqual(PolishOutput.sanitize("```\nHello there.\n```"), "Hello there.")
        XCTAssertEqual(PolishOutput.sanitize("```text\nHello there.\n```"), "Hello there.")
    }

    func testStripsWrappingQuotesWithoutInnerQuotes() {
        XCTAssertEqual(PolishOutput.sanitize("\"Hello there.\""), "Hello there.")
        XCTAssertEqual(PolishOutput.sanitize("“Hello there.”"), "Hello there.")
    }

    func testKeepsQuotesWhenTheyBelongToTheTranscript() {
        XCTAssertEqual(PolishOutput.sanitize("\"He said \"hi\".\""), "\"He said \"hi\".\"")
    }

    func testStripsGemmaEndOfTurn() {
        XCTAssertEqual(PolishOutput.sanitize("Hello there.<end_of_turn>"), "Hello there.")
    }
}

final class AppUpdateFeedTests: XCTestCase {
    func testVersionCompare() {
        XCTAssertTrue(AppUpdateFeed.isNewer(latest: "0.1.3", current: "0.1.2"))
        XCTAssertTrue(AppUpdateFeed.isNewer(latest: "v0.2.0", current: "0.1.9"))
        XCTAssertTrue(AppUpdateFeed.isNewer(latest: "0.1.10", current: "0.1.2"))
        XCTAssertFalse(AppUpdateFeed.isNewer(latest: "0.1.2", current: "0.1.2"))
        XCTAssertFalse(AppUpdateFeed.isNewer(latest: "0.1.1", current: "0.1.2"))
    }

    func testParsesGitHubReleaseAndPrefersArm64DMG() throws {
        let json = """
        {
          "tag_name": "v0.1.3",
          "html_url": "https://github.com/usingcolor/WhisperLocal/releases/tag/v0.1.3",
          "assets": [
            {
              "name": "WhisperLocal-0.1.3.zip",
              "browser_download_url": "https://github.com/usingcolor/WhisperLocal/releases/download/v0.1.3/WhisperLocal-0.1.3.zip",
              "size": 12
            },
            {
              "name": "WhisperLocal-0.1.3-arm64.dmg",
              "browser_download_url": "https://github.com/usingcolor/WhisperLocal/releases/download/v0.1.3/WhisperLocal-0.1.3-arm64.dmg",
              "size": 80000000
            }
          ]
        }
        """.data(using: .utf8)!
        let release = try AppUpdateFeed.parseRelease(from: json)
        XCTAssertEqual(release.version, "0.1.3")
        XCTAssertEqual(release.dmgName, "WhisperLocal-0.1.3-arm64.dmg")
        XCTAssertEqual(release.dmgBytes, 80_000_000)
        XCTAssertTrue(release.dmgURL.absoluteString.hasSuffix("WhisperLocal-0.1.3-arm64.dmg"))
        XCTAssertNil(release.sha256)
        XCTAssertNil(release.sha256SumsURL)
    }

    func testParseReleaseLocatesSHA256SUMS() throws {
        let json = """
        {
          "tag_name": "v0.1.4",
          "html_url": "https://github.com/usingcolor/WhisperLocal/releases/tag/v0.1.4",
          "assets": [
            {
              "name": "WhisperLocal-0.1.4-arm64.dmg",
              "browser_download_url": "https://github.com/usingcolor/WhisperLocal/releases/download/v0.1.4/WhisperLocal-0.1.4-arm64.dmg",
              "size": 80000000
            },
            {
              "name": "SHA256SUMS",
              "browser_download_url": "https://github.com/usingcolor/WhisperLocal/releases/download/v0.1.4/SHA256SUMS",
              "size": 128
            }
          ]
        }
        """.data(using: .utf8)!
        let release = try AppUpdateFeed.parseRelease(from: json)
        XCTAssertEqual(
            release.sha256SumsURL?.absoluteString,
            "https://github.com/usingcolor/WhisperLocal/releases/download/v0.1.4/SHA256SUMS"
        )
        XCTAssertNil(release.sha256)
    }

    func testParseSHA256SUMSMatchingMissingAndMalformed() {
        let digest = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
        let text = """
        # comment
        \(digest)  WhisperLocal-0.1.4-arm64.dmg
        not-a-hash  foo.dmg
        deadbeef
        """
        XCTAssertEqual(
            AppUpdateFeed.parseSHA256SUMS(text, for: "WhisperLocal-0.1.4-arm64.dmg"),
            digest
        )
        XCTAssertNil(AppUpdateFeed.parseSHA256SUMS(text, for: "missing.dmg"))
        XCTAssertNil(AppUpdateFeed.parseSHA256SUMS("not a valid line\n", for: "WhisperLocal.dmg"))
    }

    func testPickDMGUsesLastPathComponent() throws {
        let json = """
        {
          "tag_name": "v0.1.4",
          "html_url": "https://github.com/usingcolor/WhisperLocal/releases/tag/v0.1.4",
          "assets": [
            {
              "name": "whisperlocal/../../evil.dmg",
              "browser_download_url": "https://github.com/usingcolor/WhisperLocal/releases/download/v0.1.4/evil.dmg",
              "size": 80000000
            },
            {
              "name": "WhisperLocal-0.1.4-arm64.dmg",
              "browser_download_url": "https://github.com/usingcolor/WhisperLocal/releases/download/v0.1.4/WhisperLocal-0.1.4-arm64.dmg",
              "size": 80000000
            }
          ]
        }
        """.data(using: .utf8)!
        let release = try AppUpdateFeed.parseRelease(from: json)
        XCTAssertEqual(release.dmgName, "WhisperLocal-0.1.4-arm64.dmg")
        XCTAssertFalse(release.dmgName.contains(".."))
    }

    func testRejectsOffsiteAssetURLs() {
        XCTAssertFalse(
            AppUpdateFeed.isTrustedDownloadURL(URL(string: "https://evil.example/WhisperLocal.dmg")!)
        )
        XCTAssertTrue(
            AppUpdateFeed.isTrustedDownloadURL(
                URL(string: "https://github.com/usingcolor/WhisperLocal/releases/download/v0.1.2/WhisperLocal-0.1.2-arm64.dmg")!
            )
        )
        XCTAssertFalse(
            AppUpdateFeed.isTrustedDownloadURL(
                URL(string: "http://github.com/usingcolor/WhisperLocal/releases/download/v0.1.2/WhisperLocal-0.1.2-arm64.dmg")!
            )
        )
        XCTAssertFalse(
            AppUpdateFeed.isTrustedDownloadURL(
                URL(string: "file:///tmp/WhisperLocal.dmg")!
            )
        )
    }
}

final class UpdateInstallLogTests: XCTestCase {
    func testParsesSuccess() {
        let text = """
        === 2026-08-29T00:00:00Z WhisperLocal update start pid=1 ===
        copying
        UPDATE_OK
        """
        XCTAssertEqual(UpdateInstallLog.parse(text), .succeeded)
    }

    func testParsesFailureAndAcknowledgement() {
        let failed = """
        === 2026-08-29T00:00:00Z WhisperLocal update start pid=1 ===
        ditto: permission denied
        UPDATE_FAILED status=1
        """
        guard case .failed(let detail) = UpdateInstallLog.parse(failed) else {
            return XCTFail("expected failed")
        }
        XCTAssertTrue(detail.contains("UPDATE_FAILED"))

        let ack = failed + "\nUPDATE_FAILURE_ACK\n"
        XCTAssertEqual(UpdateInstallLog.parse(ack), .acknowledgedFailure)
    }

    func testEmptyLog() {
        XCTAssertEqual(UpdateInstallLog.parse(""), .none)
    }
}

final class AppIdentityTests: XCTestCase {
    func testPublicBundleIsNotDev() {
        XCTAssertFalse(AppIdentity.isDev(bundleID: AppIdentity.publicBundleID))
        XCTAssertFalse(AppIdentity.isDev(bundleID: "com.usingcolor.WhisperLocalTests"))
    }

    func testDevBundleIsDev() {
        XCTAssertTrue(AppIdentity.isDev(bundleID: AppIdentity.devBundleID))
    }
}
