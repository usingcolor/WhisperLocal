import Carbon
import Foundation

/// The language one take is dictated in, resolved when the take starts.
///
/// Deliberately not an enumeration of blessed languages. What can be served is a
/// property of the speech model and the polish model, both of which the user can
/// change, so the set is asked for at the point of use rather than declared here.
struct SpokenLanguage: Hashable, Sendable {
    /// BCP-47 primary subtag as the input source declared it: "en", "ko", "zh-Hans".
    let code: String

    static let english = SpokenLanguage(code: "en")

    init(code: String) {
        self.code = code.trimmingCharacters(in: .whitespaces)
    }

    var isEnglish: Bool { base == "en" }

    /// Primary subtag. Whisper wants "zh", not "zh-Hans".
    var base: String {
        code.split(separator: "-").first.map(String.init)?.lowercased() ?? code.lowercased()
    }

    /// Endonym, for the HUD: a Korean speaker should see 한국어, not "Korean".
    var nativeName: String {
        let locale = Locale(identifier: code)
        if let name = locale.localizedString(forLanguageCode: code), !name.isEmpty {
            return name
        }
        return code.uppercased()
    }

    /// For log lines and English UI.
    var englishName: String {
        Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
    }
}

/// Reads the language the macOS input source declares.
///
/// The rule comes from what the sources actually report: `2-Set Korean` declares
/// exactly `["ko"]`, while `ABC` declares 93 languages — English, Afrikaans,
/// Catalan, Filipino, and on. A source naming one language is a statement of
/// intent; a source naming ninety-three is telling you the script and nothing
/// more, so it is treated as no answer at all rather than as English.
enum KeyboardLanguage {
    /// Languages declared by the current keyboard input source.
    static func currentDeclaredLanguages() -> [String] {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return [] }
        return declaredLanguages(of: source)
    }

    /// The language the keyboard is evidence for, or nil when it is evidence for
    /// nothing. Callers fall back to English.
    static func current() -> SpokenLanguage? {
        language(fromDeclared: currentDeclaredLanguages())
    }

    /// Split out from the TIS call so the rule can be tested without a keyboard.
    static func language(fromDeclared declared: [String]) -> SpokenLanguage? {
        guard declared.count == 1, let only = declared.first else { return nil }
        let trimmed = only.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return SpokenLanguage(code: trimmed)
    }

    private static func declaredLanguages(of source: TISInputSource) -> [String] {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else {
            return []
        }
        return Unmanaged<CFArray>.fromOpaque(raw).takeUnretainedValue() as? [String] ?? []
    }

    /// The enabled keyboards that name exactly one language — the only ones that
    /// can ever decide a take's language. Deduplicated by language: the Korean IME
    /// shows up as both "Korean" and "2-Set Korean", and that is one choice.
    static func enabledSingleLanguageKeyboards() -> [(language: SpokenLanguage, name: String)] {
        let filter = [
            kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
            kTISPropertyInputSourceIsEnabled as String: true
        ] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue()
                as? [TISInputSource] else { return [] }
        var seen = Set<String>()
        var result: [(language: SpokenLanguage, name: String)] = []
        for source in list {
            guard let language = language(fromDeclared: declaredLanguages(of: source)),
                  seen.insert(language.base).inserted else { continue }
            result.append((language, localizedName(of: source) ?? language.nativeName))
        }
        return result
    }

    private static func localizedName(of source: TISInputSource) -> String? {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }

    /// Posted by the system when the user switches input source. Used to warm a
    /// speech model before the hotkey is pressed rather than stalling a take.
    static let changedNotification = Notification.Name(
        kTISNotifySelectedKeyboardInputSourceChanged as String
    )
}

/// Which speech locale a take runs on. Pulled out of `AppleSpeechASR` so the rule
/// can be tested, because breaking it is the one failure that puts another
/// language into an English dictation.
enum SpeechLocaleChoice {
    /// English takes use the English locale. Any other language uses the locale
    /// installed for *that* language, or nothing. There is deliberately no
    /// "whatever is loaded" fallback: the first version had one, and after a
    /// Korean warm-up it transcribed English speech with the Korean model.
    static func pick(
        for language: SpokenLanguage,
        english: Locale?,
        installed: [SpokenLanguage: Locale]
    ) -> Locale? {
        language.isEnglish ? english : installed[language]
    }
}

/// How a take's language is chosen. Pure, so every case can be a test.
///
/// Two settings feed it: the dictation language, used by default, and the set of
/// keyboard languages the user chose to follow. The keyboard only decides a take
/// when it names one language *and* that language is followed; an unfollowed
/// keyboard, ABC, or no answer all mean the dictation language. With the dictation
/// language set to English and nothing followed, every take is English — the path
/// the app had before any of this existed.
enum LanguageResolution {
    static func wanted(
        preferred: SpokenLanguage,
        keyboard: SpokenLanguage?,
        followed: Set<String>
    ) -> SpokenLanguage {
        if let keyboard, followed.contains(keyboard.base) { return keyboard }
        return preferred
    }

    /// One step down at a time: the wanted language, then the dictation language,
    /// then English, which is always servable. Never a language nobody chose.
    static func resolve(
        wanted: SpokenLanguage,
        preferred: SpokenLanguage,
        canServe: (SpokenLanguage) -> Bool
    ) -> SpokenLanguage {
        if wanted.isEnglish || canServe(wanted) { return wanted }
        if preferred != wanted, preferred.isEnglish || canServe(preferred) { return preferred }
        return .english
    }
}

