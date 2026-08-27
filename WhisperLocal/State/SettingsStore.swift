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

    @Published var asrModelRaw: String { didSet { persist(asrModelRaw, key: "asrModel") } }
    @Published var cloudPolishProviderRaw: String { didSet { persist(cloudPolishProviderRaw, key: "cloudPolishProvider") } }
    @Published var useLocalLLMPolish: Bool { didSet { persist(useLocalLLMPolish, key: "useAppleIntelligencePolish") } }
    @Published var enableTextCleanup: Bool { didSet { persist(enableTextCleanup, key: "enableTextCleanup") } }
    @Published var hasCompletedOnboarding: Bool { didSet { persist(hasCompletedOnboarding, key: "hasCompletedOnboarding") } }
    @Published var dictionaryWordsRaw: String { didSet { persist(dictionaryWordsRaw, key: "dictionaryWords") } }
    @Published var dictionaryFullyEditable: Bool { didSet { persist(dictionaryFullyEditable, key: "dictionaryFullyEditable") } }
    @Published var cleanupPersonalContextRaw: String { didSet { persist(cleanupPersonalContextRaw, key: "cleanupPersonalContext") } }
    @Published var cleanupPersonalContextMigrated: Bool { didSet { persist(cleanupPersonalContextMigrated, key: "cleanupPersonalContextMigrated") } }
    @Published var openAIModel: String { didSet { persist(openAIModel, key: "openAIModel") } }
    @Published var anthropicModel: String { didSet { persist(anthropicModel, key: "anthropicModel") } }
    @Published var insertTrailingSpace: Bool { didSet { persist(insertTrailingSpace, key: "insertTrailingSpace") } }

    var asrModel: ASRModelOption {
        get { ASRModelOption(rawValue: asrModelRaw) ?? .smallEn }
        set { asrModelRaw = newValue.rawValue }
    }

    var cloudPolishProvider: CloudPolishProvider {
        get { CloudPolishProvider(rawValue: cloudPolishProviderRaw) ?? .none }
        set { cloudPolishProviderRaw = newValue.rawValue }
    }

    /// Cloud picker is OpenAI or Anthropic. Apple Intelligence is skipped in this mode.
    var isCloudPolishSelected: Bool {
        cloudPolishProvider != .none
    }

    var hasUsableCloudPolish: Bool {
        switch cloudPolishProvider {
        case .none: return false
        case .openAI: return !openAIAPIKey.isEmpty
        case .anthropic: return !anthropicAPIKey.isEmpty
        }
    }

    /// Stored Apple Intelligence preference, ignored while cloud polish is selected.
    var shouldUseLocalLLMPolish: Bool {
        useLocalLLMPolish && !isCloudPolishSelected
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
        let defaults = UserDefaults.standard
        asrModelRaw = defaults.string(forKey: "asrModel") ?? ASRModelOption.smallEn.rawValue
        cloudPolishProviderRaw = defaults.string(forKey: "cloudPolishProvider") ?? CloudPolishProvider.none.rawValue
        useLocalLLMPolish = defaults.object(forKey: "useAppleIntelligencePolish") as? Bool ?? true
        enableTextCleanup = defaults.object(forKey: "enableTextCleanup") as? Bool ?? true
        hasCompletedOnboarding = defaults.bool(forKey: "hasCompletedOnboarding")
        dictionaryWordsRaw = defaults.string(forKey: "dictionaryWords") ?? ""
        dictionaryFullyEditable = defaults.bool(forKey: "dictionaryFullyEditable")
        cleanupPersonalContextRaw = defaults.string(forKey: "cleanupPersonalContext") ?? ""
        cleanupPersonalContextMigrated = defaults.bool(forKey: "cleanupPersonalContextMigrated")
        openAIModel = defaults.string(forKey: "openAIModel") ?? CloudModelCatalog.openAIDefault
        anthropicModel = defaults.string(forKey: "anthropicModel") ?? CloudModelCatalog.anthropicDefault
        insertTrailingSpace = defaults.object(forKey: "insertTrailingSpace") as? Bool ?? true
        migrateDictionaryStorage()
        migratePersonalContext()
    }

    private func persist(_ value: Any, key: String) {
        UserDefaults.standard.set(value, forKey: key)
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
