import XCTest

/// The rule that decides whether the keyboard is evidence of anything.
final class KeyboardLanguageRuleTests: XCTestCase {
    /// Measured from the real input source: `2-Set Korean` declares exactly this.
    func testAnIMEDeclaringOneLanguageIsBelieved() {
        XCTAssertEqual(KeyboardLanguage.language(fromDeclared: ["ko"])?.code, "ko")
        XCTAssertEqual(KeyboardLanguage.language(fromDeclared: ["ja"])?.code, "ja")
    }

    /// Also measured: the ABC layout declares 93 languages. That is a statement
    /// about the script, not the language, so it must not read as English — or as
    /// Afrikaans, which is what taking the list's first entry on a reordered
    /// system would eventually do.
    func testALayoutDeclaringManyLanguagesIsNotEvidence() {
        let abc = ["en", "af", "asa", "bem", "bez", "ca", "ceb", "cgg", "co", "da", "de",
                   "es", "eu", "fil", "fr", "it", "nl", "pt", "sv", "sw", "zu"]
        XCTAssertNil(KeyboardLanguage.language(fromDeclared: abc))
    }

    func testNoDeclarationIsNotEvidence() {
        XCTAssertNil(KeyboardLanguage.language(fromDeclared: []))
        XCTAssertNil(KeyboardLanguage.language(fromDeclared: [" "]))
    }

    /// A single-language Latin layout is still a real declaration.
    func testASingleLanguageLayoutCounts() {
        XCTAssertEqual(KeyboardLanguage.language(fromDeclared: ["de"])?.code, "de")
    }
}

final class SpokenLanguageTests: XCTestCase {
    func testEnglishIsRecognisedByRegionToo() {
        XCTAssertTrue(SpokenLanguage(code: "en").isEnglish)
        XCTAssertTrue(SpokenLanguage(code: "en-GB").isEnglish)
        XCTAssertFalse(SpokenLanguage(code: "ko").isEnglish)
    }

    /// Whisper takes "zh", not "zh-Hans".
    func testBaseSubtagIsStripped() {
        XCTAssertEqual(SpokenLanguage(code: "zh-Hans").base, "zh")
        XCTAssertEqual(SpokenLanguage(code: "ko").base, "ko")
        XCTAssertEqual(SpokenLanguage(code: "EN-US").base, "en")
    }

    /// The HUD badge is for the person speaking the language, so it shows the
    /// endonym rather than the English name.
    func testNativeNameIsTheEndonym() {
        XCTAssertEqual(SpokenLanguage(code: "ko").nativeName, "한국어")
        XCTAssertEqual(SpokenLanguage(code: "ko").englishName, "Korean")
    }
}

/// The block that stops a cleanup model from silently translating the take.
final class LanguageNoticeTests: XCTestCase {
    private func wrapped(_ language: SpokenLanguage?) -> String {
        CleanupPrompt.wrapTranscript(
            "여기 그 음 텍스트가 있습니다",
            targetApp: "Slack",
            language: language
        )
    }

    func testEnglishAddsNothingAtAll() {
        XCTAssertFalse(wrapped(nil).contains("<language"))
        XCTAssertFalse(wrapped(.english).contains("<language"))
        XCTAssertFalse(wrapped(SpokenLanguage(code: "en-GB")).contains("<language"))
    }

    func testAnotherLanguageIsNamedAndTranslationForbidden() {
        let out = wrapped(SpokenLanguage(code: "ko"))
        XCTAssertTrue(out.contains("<language code=\"ko\">"))
        XCTAssertTrue(out.contains("Korean"))
        XCTAssertTrue(out.contains("Never translate"))
    }

    /// It has to sit after the stable blocks and before the transcript, for the
    /// same reason <part> does: everything above it is a cacheable prefix.
    func testItSitsJustBeforeTheTranscript() {
        let out = wrapped(SpokenLanguage(code: "ko"))
        guard let app = out.range(of: "<target-app>"),
              let lang = out.range(of: "<language"),
              let transcript = out.range(of: "<transcript>") else {
            return XCTFail("expected all three blocks")
        }
        XCTAssertLessThan(app.lowerBound, lang.lowerBound)
        XCTAssertLessThan(lang.lowerBound, transcript.lowerBound)
    }
}

/// The rule whose violation put Korean into English dictation.
final class SpeechLocaleChoiceTests: XCTestCase {
    private let en = Locale(identifier: "en-US")
    private let ko = Locale(identifier: "ko-KR")
    private let korean = SpokenLanguage(code: "ko")

    /// The exact bug: Korean installed, English take. Must be English.
    func testAnEnglishTakeUsesEnglishEvenWithKoreanInstalled() {
        let picked = SpeechLocaleChoice.pick(for: .english, english: en, installed: [korean: ko])
        XCTAssertEqual(picked, en)
    }

    func testAKoreanTakeUsesTheKoreanLocale() {
        XCTAssertEqual(SpeechLocaleChoice.pick(for: korean, english: en, installed: [korean: ko]), ko)
    }

    /// Asking for a language that was never installed must fail rather than run
    /// on whatever is loaded — that fallback was the bug.
    func testAnUninstalledLanguageGetsNothingNotTheLoadedOne() {
        XCTAssertNil(SpeechLocaleChoice.pick(for: korean, english: en, installed: [:]))
        let japanese = SpokenLanguage(code: "ja")
        XCTAssertNil(SpeechLocaleChoice.pick(for: japanese, english: en, installed: [korean: ko]))
    }

    func testRegionalEnglishIsStillEnglish() {
        let picked = SpeechLocaleChoice.pick(for: SpokenLanguage(code: "en-GB"), english: en, installed: [korean: ko])
        XCTAssertEqual(picked, en)
    }
}
