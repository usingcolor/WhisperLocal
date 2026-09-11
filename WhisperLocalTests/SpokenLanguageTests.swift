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

/// The language block has to survive `userMessage`, which is what every polisher
/// calls. The earlier tests went one layer down to `wrapTranscript` and passed
/// while the cloud branch of `userMessage` dropped the language — so OpenAI got
/// a Korean transcript with no instruction and translated it.
final class UserMessageLanguageTests: XCTestCase {
    private let korean = SpokenLanguage(code: "ko")
    private let transcript = "한국어로 한번 말해 볼게요. 잘 들리세요."

    private func message(onDevice: Bool, language: SpokenLanguage?) -> String {
        CleanupPrompt.userMessage(
            for: .dictation,
            text: transcript,
            targetApp: "Claude — chat app",
            onDevice: onDevice,
            language: language
        )
    }

    /// The branch OpenAI and Anthropic use. This is the one that was broken.
    func testCloudRequestCarriesTheLanguage() {
        let out = message(onDevice: false, language: korean)
        XCTAssertTrue(out.contains("<language code=\"ko\">"), "cloud request lost the language block")
        XCTAssertTrue(out.contains("Never translate"))
    }

    func testOnDeviceRequestCarriesTheLanguage() {
        let out = message(onDevice: true, language: korean)
        XCTAssertTrue(out.contains("<language code=\"ko\">"))
    }

    /// And English still sends nothing new, on either path.
    func testEnglishSendsNoLanguageBlockOnEitherPath() {
        for onDevice in [false, true] {
            XCTAssertFalse(message(onDevice: onDevice, language: .english).contains("<language"))
            XCTAssertFalse(message(onDevice: onDevice, language: nil).contains("<language"))
        }
    }
}
