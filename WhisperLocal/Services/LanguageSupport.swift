import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif
#if canImport(Speech)
import Speech
#endif

/// Whether the pipeline can actually serve a language end to end.
///
/// Both halves have to agree. Transcribing Korean and then handing it to a polish
/// model that does not read Korean is worse than not trying: the model's most
/// likely repair for text it cannot clean is to translate it, and the speaker gets
/// fluent English they never asked for. When either half says no, the take runs in
/// English exactly as it does today.
enum LanguageSupport {
    /// Languages Whisper's multilingual checkpoints are trained on. The `.en`
    /// checkpoints serve English only, whatever code you pass them.
    static let whisperLanguages: Set<String> = [
        "af", "am", "ar", "as", "az", "ba", "be", "bg", "bn", "bo", "br", "bs", "ca", "cs",
        "cy", "da", "de", "el", "en", "es", "et", "eu", "fa", "fi", "fo", "fr", "gl", "gu",
        "ha", "haw", "he", "hi", "hr", "ht", "hu", "hy", "id", "is", "it", "ja", "jw", "ka",
        "kk", "km", "kn", "ko", "la", "lb", "ln", "lo", "lt", "lv", "mg", "mi", "mk", "ml",
        "mn", "mr", "ms", "mt", "my", "ne", "nl", "nn", "no", "oc", "pa", "pl", "ps", "pt",
        "ro", "ru", "sa", "sd", "si", "sk", "sl", "sn", "so", "sq", "sr", "su", "sv", "sw",
        "ta", "te", "tg", "th", "tk", "tl", "tr", "tt", "uk", "ur", "uz", "vi", "yi", "yo", "zh"
    ]

    /// Can this speech model produce this language at all? Pure, so it is testable;
    /// Apple Speech's answer also depends on an asset being installed, which
    /// `AppleSpeechASR` resolves separately.
    static func speechModelCanServe(_ language: SpokenLanguage, model: ASRModelOption) -> Bool {
        if language.isEnglish { return true }
        switch model {
        case .appleSpeech:
            return true                       // narrowed by locale availability at load time
        case .largeV3Turbo:
            return whisperLanguages.contains(language.base)
        case .tinyEn, .baseEn, .smallEn:
            return false                      // English-only checkpoints
        case .parakeetTDT06bV2:
            return false                      // English-only model
        }
    }

    /// Apple Speech ships one asset per locale and only English is installed by
    /// default, so this asks the framework rather than assuming.
    static func appleSpeechLocale(for language: SpokenLanguage) async -> Locale? {
        guard #available(macOS 26.0, *) else { return nil }
        return await SpeechTranscriber.supportedLocale(
            equivalentTo: Locale(identifier: language.code)
        )
    }

    /// Cloud models handle every language here. On-device ones do not, and Apple
    /// publishes the list, so it is read rather than hardcoded.
    static func polishCanServe(
        _ language: SpokenLanguage,
        cloud: CloudPolishProvider,
        local: LocalPolishEngine
    ) -> Bool {
        if language.isEnglish { return true }
        if cloud != .none { return true }
        switch local {
        case .none:
            // No LLM runs, so nothing can mistranslate. The filler pass is English
            // string matching and simply finds nothing to strip.
            return true
        case .gemma4_e2b:
            return true
        case .appleIntelligence:
            return appleIntelligenceSupports(language)
        }
    }

    static func appleIntelligenceSupports(_ language: SpokenLanguage) -> Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return SystemLanguageModel.default.supportedLanguages.contains {
                $0.languageCode?.identifier.lowercased() == language.base
            }
        }
        #endif
        return false
    }
}
