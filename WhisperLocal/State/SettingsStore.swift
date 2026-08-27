import Foundation
import Security
import SwiftUI

enum ASRModelOption: String, CaseIterable, Identifiable, Codable {
    case tinyEn = "tiny.en"
    case smallEn = "small.en"
    case baseEn = "base.en"
    case largeV3Turbo = "large-v3-v20240930_turbo"
    case parakeetTDT06bV2 = "parakeet-tdt-0.6b-v2"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tinyEn: return "Whisper Tiny (English) — fastest"
        case .baseEn: return "Whisper Base (English)"
        case .smallEn: return "Whisper Small (English) — recommended"
        case .largeV3Turbo: return "Whisper Large v3 Turbo — best quality"
        case .parakeetTDT06bV2: return "Parakeet TDT 0.6B v2 — NVIDIA English"
        }
    }

    var engine: ASREngine {
        switch self {
        case .parakeetTDT06bV2: return .parakeet
        default: return .whisper
        }
    }

    var statusBrand: String {
        switch engine {
        case .whisper: return "Whisper"
        case .parakeet: return "Parakeet"
        }
    }

    var whisperKitName: String? {
        switch self {
        case .parakeetTDT06bV2: return nil
        default: return rawValue
        }
    }
}

enum ASREngine: String {
    case whisper
    case parakeet
}

enum CloudPolishProvider: String, CaseIterable, Identifiable, Codable {
    case none
    case openAI
    case anthropic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "Off (local only)"
        case .openAI: return "OpenAI"
        case .anthropic: return "Anthropic"
        }
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @AppStorage("asrModel") var asrModelRaw: String = ASRModelOption.smallEn.rawValue
    @AppStorage("cloudPolishProvider") var cloudPolishProviderRaw: String = CloudPolishProvider.none.rawValue
    @AppStorage("useAppleIntelligencePolish") var useLocalLLMPolish: Bool = true
    /// Wispr/OpenWhispr-style: cleanup on by default (offline heuristic always; LLM when configured).
    @AppStorage("enableTextCleanup") var enableTextCleanup: Bool = true
    @AppStorage("hasCompletedOnboarding") var hasCompletedOnboarding: Bool = false
    @AppStorage("dictionaryWords") var dictionaryWordsRaw: String = ""
    @AppStorage("dictionaryFullyEditable") var dictionaryFullyEditable: Bool = false
    @AppStorage("cleanupPersonalContext") var cleanupPersonalContextRaw: String = ""
    @AppStorage("cleanupPersonalContextMigrated") var cleanupPersonalContextMigrated: Bool = false
    @AppStorage("openAIModel") var openAIModel: String = CloudModelCatalog.openAIDefault
    @AppStorage("anthropicModel") var anthropicModel: String = CloudModelCatalog.anthropicDefault
    @AppStorage("insertTrailingSpace") var insertTrailingSpace: Bool = true

    var asrModel: ASRModelOption {
        get { ASRModelOption(rawValue: asrModelRaw) ?? .smallEn }
        set { asrModelRaw = newValue.rawValue }
    }

    var cloudPolishProvider: CloudPolishProvider {
        get { CloudPolishProvider(rawValue: cloudPolishProviderRaw) ?? .none }
        set { cloudPolishProviderRaw = newValue.rawValue }
    }

    var cleanupPersonalContext: String {
        get { cleanupPersonalContextRaw }
        set {
            cleanupPersonalContextRaw = newValue
            objectWillChange.send()
        }
    }

    var dictionaryWords: [String] {
        get {
            CleanupPrompt.mergedDictionary(parseDictionaryList(dictionaryWordsRaw))
        }
        set {
            dictionaryWordsRaw = CleanupPrompt.mergedDictionary(newValue).joined(separator: ", ")
            objectWillChange.send()
        }
    }

    private init() {
        migrateDictionaryStorage()
        migratePersonalContext()
    }

    func addDictionaryWord(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var words = dictionaryWords
        let key = trimmed.lowercased()
        if words.contains(where: { $0.lowercased() == key }) { return }
        words.append(trimmed)
        dictionaryWords = words
    }

    func removeDictionaryWord(_ word: String) {
        let key = word.lowercased()
        dictionaryWords = dictionaryWords.filter { $0.lowercased() != key }
    }

    func restoreDefaultPersonalContext() {
        cleanupPersonalContext = CleanupPrompt.defaultPersonalContext
    }

    func clearPersonalContext() {
        cleanupPersonalContext = ""
    }

    /// One-time: copy the built-in speaker notes into the editable Settings field.
    private func migratePersonalContext() {
        guard !cleanupPersonalContextMigrated else { return }
        if cleanupPersonalContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            cleanupPersonalContext = CleanupPrompt.defaultPersonalContext
        }
        cleanupPersonalContextMigrated = true
    }

    /// One-time: fold the old locked starter list into the editable list.
    private func migrateDictionaryStorage() {
        guard !dictionaryFullyEditable else { return }
        dictionaryWords = CleanupPrompt.mergedDictionary(
            CleanupPrompt.defaultDictionary + parseDictionaryList(dictionaryWordsRaw)
        )
        dictionaryFullyEditable = true
    }

    private func parseDictionaryList(_ raw: String) -> [String] {
        raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    var openAIAPIKey: String {
        get { KeychainHelper.load(account: "openai_api_key") ?? "" }
        set {
            if newValue.isEmpty {
                KeychainHelper.delete(account: "openai_api_key")
            } else {
                KeychainHelper.save(account: "openai_api_key", value: newValue)
            }
            objectWillChange.send()
        }
    }

    var anthropicAPIKey: String {
        get { KeychainHelper.load(account: "anthropic_api_key") ?? "" }
        set {
            if newValue.isEmpty {
                KeychainHelper.delete(account: "anthropic_api_key")
            } else {
                KeychainHelper.save(account: "anthropic_api_key", value: newValue)
            }
            objectWillChange.send()
        }
    }
}

enum KeychainHelper {
    private static let service = "com.usingcolor.WhisperLocal"

    static func save(account: String, value: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attrs as CFDictionary, nil)
    }

    static func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
