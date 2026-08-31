import Foundation
import os
import Security
import SwiftUI

enum ASRModelOption: String, CaseIterable, Identifiable, Codable {
    case appleSpeech = "apple-speech"
    case tinyEn = "tiny.en"
    case smallEn = "small.en"
    case baseEn = "base.en"
    case largeV3Turbo = "large-v3-v20240930_turbo"
    case parakeetTDT06bV2 = "parakeet-tdt-0.6b-v2"

    var id: String { rawValue }

    /// Apple Speech when the Mac supports it; otherwise Whisper Small.
    static var defaultModel: ASRModelOption {
        AppleSpeechASR.isAvailable ? .appleSpeech : .smallEn
    }

    var displayName: String {
        switch self {
        case .appleSpeech: return "Apple Speech (macOS) — default"
        case .tinyEn: return "Whisper Tiny (English) — fastest"
        case .baseEn: return "Whisper Base (English)"
        case .smallEn: return "Whisper Small (English)"
        case .largeV3Turbo: return "Whisper Large v3 Turbo — best Whisper quality"
        case .parakeetTDT06bV2: return "Parakeet TDT 0.6B v2 — NVIDIA English"
        }
    }

    /// Compact label for the menu bar and status line.
    var shortName: String {
        switch self {
        case .appleSpeech: return "Apple Speech"
        case .tinyEn: return "Whisper Tiny"
        case .baseEn: return "Whisper Base"
        case .smallEn: return "Whisper Small"
        case .largeV3Turbo: return "Whisper Large v3 Turbo"
        case .parakeetTDT06bV2: return "Parakeet 0.6B"
        }
    }

    var engine: ASREngine {
        switch self {
        case .parakeetTDT06bV2: return .parakeet
        case .appleSpeech: return .appleSpeech
        default: return .whisper
        }
    }

    var whisperKitName: String? {
        switch self {
        case .parakeetTDT06bV2, .appleSpeech: return nil
        default: return rawValue
        }
    }
}

enum ASREngine: String {
    case whisper
    case parakeet
    case appleSpeech
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

    /// OpenAI and Anthropic — the cloud picker, without Off.
    static var cloudCases: [CloudPolishProvider] { [.openAI, .anthropic] }
}

enum LocalPolishEngine: String, CaseIterable, Identifiable, Codable {
    case none
    case appleIntelligence
    case gemma4_e2b

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "Off"
        case .appleIntelligence: return "Apple Intelligence (~3B) — default"
        case .gemma4_e2b: return "Gemma 4 E2B IT (MLX)"
        }
    }

    var shortName: String {
        switch self {
        case .none: return "Off"
        case .appleIntelligence: return "Apple Intelligence"
        case .gemma4_e2b: return "Gemma 4 E2B"
        }
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published var asrModelRaw: String { didSet { persist(asrModelRaw, key: "asrModel") } }
    @Published var cloudPolishProviderRaw: String { didSet { persist(cloudPolishProviderRaw, key: "cloudPolishProvider") } }
    /// Last OpenAI/Anthropic choice so switching Cloud back on restores the provider.
    @Published var lastCloudPolishProviderRaw: String { didSet { persist(lastCloudPolishProviderRaw, key: "lastCloudPolishProvider") } }
    @Published var localPolishEngineRaw: String { didSet { persist(localPolishEngineRaw, key: "localPolishEngine") } }
    @Published var enableTextCleanup: Bool { didSet { persist(enableTextCleanup, key: "enableTextCleanup") } }
    @Published var hasCompletedOnboarding: Bool { didSet { persist(hasCompletedOnboarding, key: "hasCompletedOnboarding") } }
    @Published var dictionaryWordsRaw: String { didSet { persist(dictionaryWordsRaw, key: "dictionaryWords") } }
    @Published var dictionaryFullyEditable: Bool { didSet { persist(dictionaryFullyEditable, key: "dictionaryFullyEditable") } }
    @Published var cleanupPersonalContextRaw: String { didSet { persist(cleanupPersonalContextRaw, key: "cleanupPersonalContext") } }
    @Published var cleanupPersonalContextMigrated: Bool { didSet { persist(cleanupPersonalContextMigrated, key: "cleanupPersonalContextMigrated") } }
    @Published var cleanupPersonalNotesRaw: String { didSet { persist(cleanupPersonalNotesRaw, key: "cleanupPersonalNotes") } }
    @Published var cleanupPersonalExamplesRaw: String { didSet { persist(cleanupPersonalExamplesRaw, key: "cleanupPersonalExamples") } }
    @Published var cleanupExceptionsRaw: String { didSet { persist(cleanupExceptionsRaw, key: "cleanupExceptions") } }
    @Published var appDictionariesRaw: String { didSet { persist(appDictionariesRaw, key: "appDictionaries") } }
    @Published var hiddenAppDictionaryNamesRaw: String { didSet { persist(hiddenAppDictionaryNamesRaw, key: "hiddenAppDictionaryNames") } }
    @Published var systemPromptLayersMigrated: Bool { didSet { persist(systemPromptLayersMigrated, key: "systemPromptLayersMigrated") } }
    @Published var openAIModel: String { didSet { persist(openAIModel, key: "openAIModel") } }
    @Published var anthropicModel: String { didSet { persist(anthropicModel, key: "anthropicModel") } }
    @Published var insertTrailingSpace: Bool { didSet { persist(insertTrailingSpace, key: "insertTrailingSpace") } }
    @Published var enableDictationLog: Bool { didSet { persist(enableDictationLog, key: "enableDictationLog") } }
    /// When on, the last N successful takes are sent with this polish request. Off by default; not saved into the system prompt.
    @Published var includeRecentPolishLogs: Bool { didSet { persist(includeRecentPolishLogs, key: "includeRecentPolishLogs") } }
    @Published var recentPolishLogCountRaw: Int { didSet { persist(recentPolishLogCountRaw, key: "recentPolishLogCount") } }
    @Published var promptCommitForced: Bool { didSet { persist(promptCommitForced, key: "promptCommitForced") } }
    @Published private(set) var hasOpenAIKey = false
    @Published private(set) var openAIKeySuffix: String?
    @Published private(set) var hasAnthropicKey = false
    @Published private(set) var anthropicKeySuffix: String?

    var asrModel: ASRModelOption {
        get { ASRModelOption(rawValue: asrModelRaw) ?? .defaultModel }
        set { asrModelRaw = newValue.rawValue }
    }

    var cloudPolishProvider: CloudPolishProvider {
        get { CloudPolishProvider(rawValue: cloudPolishProviderRaw) ?? .none }
        set {
            cloudPolishProviderRaw = newValue.rawValue
            if newValue != .none {
                lastCloudPolishProviderRaw = newValue.rawValue
            }
        }
    }

    /// Provider to restore when the user switches Polish with back to Cloud.
    var preferredCloudProvider: CloudPolishProvider {
        switch CloudPolishProvider(rawValue: lastCloudPolishProviderRaw) {
        case .openAI: return .openAI
        case .anthropic: return .anthropic
        default:
            if hasAnthropicKey && !hasOpenAIKey { return .anthropic }
            return .openAI
        }
    }

    var localPolishEngine: LocalPolishEngine {
        get { LocalPolishEngine(rawValue: localPolishEngineRaw) ?? .appleIntelligence }
        set { localPolishEngineRaw = newValue.rawValue }
    }

    var recentPolishLogCount: Int {
        get { CleanupPrompt.clampRecentPolishLogCount(recentPolishLogCountRaw) }
        set { recentPolishLogCountRaw = CleanupPrompt.clampRecentPolishLogCount(newValue) }
    }

    /// Opt-in recent takes in the polish user message. Requires the dictation log.
    var shouldIncludeRecentPolishLogs: Bool {
        includeRecentPolishLogs && enableDictationLog
    }

    /// Cloud picker is OpenAI or Anthropic. On-device LLM polish is skipped in this mode.
    var isCloudPolishSelected: Bool {
        cloudPolishProvider != .none
    }

    var hasUsableCloudPolish: Bool {
        switch cloudPolishProvider {
        case .none: return false
        case .openAI: return hasOpenAIKey
        case .anthropic: return hasAnthropicKey
        }
    }

    /// Stored on-device polish preference, ignored while cloud polish is selected.
    var shouldUseLocalLLMPolish: Bool {
        localPolishEngine != .none && !isCloudPolishSelected
    }

    var shouldRunOnDevicePolish: Bool {
        guard shouldUseLocalLLMPolish else { return false }
        switch localPolishEngine {
        case .none:
            return false
        case .appleIntelligence:
            return LocalLLMPolisher.isAvailable
        case .gemma4_e2b:
            return true
        }
    }

    var cleanupPersonalContext: String {
        get { cleanupPersonalContextRaw }
        set { cleanupPersonalContextRaw = newValue }
    }

    var cleanupPersonalNotes: String {
        get { cleanupPersonalNotesRaw }
        set { cleanupPersonalNotesRaw = newValue }
    }

    var cleanupPersonalExamples: String {
        get { cleanupPersonalExamplesRaw }
        set { cleanupPersonalExamplesRaw = newValue }
    }

    var cleanupExceptions: String {
        get { cleanupExceptionsRaw }
        set { cleanupExceptionsRaw = CleanupPrompt.strippedUserExceptions(newValue) }
    }

    var appDictionaries: [AppDictionaryEntry] {
        get {
            guard let data = appDictionariesRaw.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([AppDictionaryEntry].self, from: data) else {
                return []
            }
            return decoded
        }
        set {
            let data = (try? JSONEncoder().encode(newValue)) ?? Data("[]".utf8)
            let encoded = String(data: data, encoding: .utf8) ?? "[]"
            if encoded != appDictionariesRaw {
                appDictionariesRaw = encoded
            }
        }
    }

    private var hiddenAppDictionaryNames: Set<String> {
        get {
            guard let data = hiddenAppDictionaryNamesRaw.data(using: .utf8),
                  let names = try? JSONDecoder().decode([String].self, from: data) else {
                return []
            }
            return Set(names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty })
        }
        set {
            let names = newValue
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
                .sorted()
            let data = (try? JSONEncoder().encode(names)) ?? Data("[]".utf8)
            hiddenAppDictionaryNamesRaw = String(data: data, encoding: .utf8) ?? "[]"
        }
    }

    var draftSystemPrompt: String {
        CleanupPrompt.assembleUserLayers(
            personalNotes: cleanupPersonalNotes,
            exceptions: cleanupExceptions,
            appDictionaries: appDictionaries,
            examples: cleanupPersonalExamples
        )
    }

    var isSystemPromptStale: Bool {
        promptCommitForced || draftSystemPrompt != cleanupPersonalContext
    }

    var dictionaryWords: [String] {
        get {
            CleanupPrompt.mergedDictionary(parseDictionaryList(dictionaryWordsRaw))
        }
        set {
            dictionaryWordsRaw = CleanupPrompt.mergedDictionary(newValue).joined(separator: ", ")
        }
    }

    private init() {
        let defaults = UserDefaults.standard
        asrModelRaw = defaults.string(forKey: "asrModel") ?? ASRModelOption.defaultModel.rawValue
        let cloudRaw = defaults.string(forKey: "cloudPolishProvider") ?? CloudPolishProvider.none.rawValue
        cloudPolishProviderRaw = cloudRaw
        if let storedLast = defaults.string(forKey: "lastCloudPolishProvider"),
           CloudPolishProvider.cloudCases.map(\.rawValue).contains(storedLast) {
            lastCloudPolishProviderRaw = storedLast
        } else if CloudPolishProvider.cloudCases.map(\.rawValue).contains(cloudRaw) {
            lastCloudPolishProviderRaw = cloudRaw
        } else {
            lastCloudPolishProviderRaw = ""
        }
        localPolishEngineRaw = Self.migratedLocalPolishEngine(from: defaults)
        enableTextCleanup = defaults.object(forKey: "enableTextCleanup") as? Bool ?? true
        hasCompletedOnboarding = defaults.bool(forKey: "hasCompletedOnboarding")
        dictionaryWordsRaw = defaults.string(forKey: "dictionaryWords") ?? ""
        dictionaryFullyEditable = defaults.bool(forKey: "dictionaryFullyEditable")
        cleanupPersonalContextRaw = defaults.string(forKey: "cleanupPersonalContext") ?? ""
        cleanupPersonalContextMigrated = defaults.bool(forKey: "cleanupPersonalContextMigrated")
        cleanupPersonalNotesRaw = defaults.string(forKey: "cleanupPersonalNotes") ?? ""
        cleanupPersonalExamplesRaw = defaults.string(forKey: "cleanupPersonalExamples") ?? ""
        cleanupExceptionsRaw = CleanupPrompt.strippedUserExceptions(
            defaults.string(forKey: "cleanupExceptions") ?? ""
        )
        appDictionariesRaw = defaults.string(forKey: "appDictionaries") ?? "[]"
        hiddenAppDictionaryNamesRaw = defaults.string(forKey: "hiddenAppDictionaryNames") ?? "[]"
        systemPromptLayersMigrated = defaults.bool(forKey: "systemPromptLayersMigrated")
        openAIModel = defaults.string(forKey: "openAIModel") ?? CloudModelCatalog.openAIDefault
        anthropicModel = defaults.string(forKey: "anthropicModel") ?? CloudModelCatalog.anthropicDefault
        insertTrailingSpace = defaults.object(forKey: "insertTrailingSpace") as? Bool ?? true
        enableDictationLog = defaults.object(forKey: "enableDictationLog") as? Bool ?? true
        includeRecentPolishLogs = defaults.object(forKey: "includeRecentPolishLogs") as? Bool ?? false
        recentPolishLogCountRaw = defaults.object(forKey: "recentPolishLogCount") as? Int
            ?? CleanupPrompt.defaultRecentPolishLogCount
        promptCommitForced = defaults.bool(forKey: "promptCommitForced")
        if defaults.string(forKey: "localPolishEngine") != localPolishEngineRaw {
            UserDefaults.standard.set(localPolishEngineRaw, forKey: "localPolishEngine")
        }
        migrateFactoryASRDefault()
        migrateDictionaryStorage()
        migratePersonalContext()
        migrateSystemPromptLayers()
        migrateShorterPersonalNotes()
        migratePersonalExamples()
        ensurePresetApps()
        refreshAPIKeyCache()
    }

    /// One-time: the old factory ASR was Whisper Small. Move that default to Apple Speech.
    /// Explicit Tiny / Base / Large / Parakeet choices are left alone.
    private func migrateFactoryASRDefault() {
        let key = "asrDefaultMigratedToAppleSpeech"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        if asrModelRaw == ASRModelOption.smallEn.rawValue, AppleSpeechASR.isAvailable {
            asrModelRaw = ASRModelOption.appleSpeech.rawValue
        }
    }

    private func persist(_ value: Any, key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    /// One-time: map the old Apple Intelligence toggle onto the engine picker.
    private static func migratedLocalPolishEngine(from defaults: UserDefaults) -> String {
        if let stored = defaults.string(forKey: "localPolishEngine") {
            if stored == "gemma3_4b" {
                return LocalPolishEngine.gemma4_e2b.rawValue
            }
            if LocalPolishEngine(rawValue: stored) != nil {
                return stored
            }
        }
        let legacyApple = defaults.object(forKey: "useAppleIntelligencePolish") as? Bool ?? true
        return (legacyApple ? LocalPolishEngine.appleIntelligence : .none).rawValue
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
        cleanupPersonalNotes = CleanupPrompt.defaultPersonalNotes
        cleanupPersonalExamples = CleanupPrompt.defaultPersonalExamples
        cleanupExceptions = CleanupPrompt.defaultExceptions
    }

    func clearPersonalContext() {
        cleanupPersonalNotes = ""
    }

    func clearPersonalExamples() {
        cleanupPersonalExamples = ""
    }

    func clearExceptions() {
        cleanupExceptions = ""
    }

    func commitSystemPrompt() {
        cleanupPersonalContext = draftSystemPrompt
        promptCommitForced = false
    }

    func matchingAppDictionaryTerms(targetApp: String?) -> [String] {
        CleanupPrompt.matchingDictionaryTerms(in: appDictionaries, targetApp: targetApp)
    }

    func addAppDictionary(_ entry: AppDictionaryEntry) {
        let nameKey = Self.appNameKey(entry.appName)
        guard !nameKey.isEmpty else { return }
        var hidden = hiddenAppDictionaryNames
        hidden.remove(nameKey)
        hiddenAppDictionaryNames = hidden
        var entries = appDictionaries
        if entries.contains(where: { Self.appNameKey($0.appName) == nameKey }) {
            return
        }
        entries.append(entry)
        appDictionaries = entries
        promptCommitForced = true
    }

    func removeAppDictionary(id: UUID) {
        guard let entry = appDictionaries.first(where: { $0.id == id }) else { return }
        let nameKey = Self.appNameKey(entry.appName)
        if !nameKey.isEmpty {
            var hidden = hiddenAppDictionaryNames
            hidden.insert(nameKey)
            hiddenAppDictionaryNames = hidden
        }
        appDictionaries = appDictionaries.filter { $0.id != id }
        promptCommitForced = true
    }

    func addAppDictionaryTerm(id: UUID, raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var entries = appDictionaries
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let key = trimmed.lowercased()
        if entries[index].terms.contains(where: { $0.lowercased() == key }) { return }
        entries[index].terms.append(trimmed)
        entries[index].terms = CleanupPrompt.mergedDictionary(entries[index].terms)
        appDictionaries = entries
    }

    func removeAppDictionaryTerm(id: UUID, term: String) {
        let key = term.lowercased()
        var entries = appDictionaries
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].terms = entries[index].terms.filter { $0.lowercased() != key }
        appDictionaries = entries
    }

    func ensurePresetApps() {
        let hidden = hiddenAppDictionaryNames
        var entries = appDictionaries.filter {
            !$0.appName.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#")
        }
        for preset in AppDictionaryEntry.presets {
            let key = Self.appNameKey(preset.appName)
            if hidden.contains(key) { continue }
            if let index = entries.firstIndex(where: { Self.appNameKey($0.appName) == key }) {
                if entries[index].kind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    entries[index].kind = preset.kind
                }
            } else {
                entries.append(AppDictionaryEntry(appName: preset.appName, kind: preset.kind))
            }
        }
        let presetKeys = AppDictionaryEntry.presets.map { Self.appNameKey($0.appName) }
        var ordered: [AppDictionaryEntry] = []
        for preset in AppDictionaryEntry.presets {
            let key = Self.appNameKey(preset.appName)
            if let found = entries.first(where: { Self.appNameKey($0.appName) == key }) {
                ordered.append(found)
            }
        }
        ordered.append(contentsOf: entries.filter { entry in
            !presetKeys.contains(Self.appNameKey(entry.appName))
        })
        appDictionaries = ordered
    }

    func applyDictionarySnapshot(_ snapshot: DictionaryCSV.Snapshot, replace: Bool) {
        if !snapshot.apps.isEmpty {
            var hidden = hiddenAppDictionaryNames
            for app in snapshot.apps {
                hidden.remove(Self.appNameKey(app.appName))
            }
            hiddenAppDictionaryNames = hidden
        }
        if replace {
            dictionaryWords = snapshot.globalWords
            appDictionaries = snapshot.apps
        } else {
            for word in snapshot.globalWords {
                addDictionaryWord(word)
            }
            var entries = appDictionaries
            for app in snapshot.apps {
                let key = Self.appNameKey(app.appName)
                guard !key.isEmpty else { continue }
                if let index = entries.firstIndex(where: { Self.appNameKey($0.appName) == key }) {
                    if !app.kind.isEmpty {
                        entries[index].kind = app.kind
                    }
                    entries[index].terms = CleanupPrompt.mergedDictionary(entries[index].terms + app.terms)
                } else {
                    entries.append(app)
                }
            }
            appDictionaries = entries
        }
        ensurePresetApps()
        if !snapshot.exceptionsByApp.isEmpty {
            cleanupExceptions = DictionaryCSV.mergeExceptions(
                existing: replace ? "" : cleanupExceptions,
                byApp: snapshot.exceptionsByApp
            )
        }
    }

    /// One-time: replace the factory About-you blob with the shorter draft if the user never edited it.
    private func migrateShorterPersonalNotes() {
        let key = "shortPersonalNotesV1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        let current = cleanupPersonalNotes.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\r\n", with: "\n")
        let legacy = CleanupPrompt.legacyDefaultPersonalNotes.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\r\n", with: "\n")
        let isFactory = current == legacy
            || (current.contains("not like a native US email") && abs(current.count - legacy.count) < 80)
        guard isFactory else { return }
        cleanupPersonalNotes = CleanupPrompt.defaultPersonalNotes
        cleanupPersonalExamples = CleanupPrompt.defaultPersonalExamples
        commitSystemPrompt()
    }

    /// One-time: move a trailing Examples block out of About you into its own field.
    private func migratePersonalExamples() {
        let key = "personalExamplesSplitV1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        if !cleanupPersonalExamples.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return
        }
        let split = CleanupPrompt.splitNotesAndExamples(cleanupPersonalNotes)
        guard !split.examples.isEmpty else { return }
        cleanupPersonalNotes = split.notes
        cleanupPersonalExamples = split.examples
        commitSystemPrompt()
    }

    /// One-time: copy the built-in speaker notes into the editable Settings field.
    private func migratePersonalContext() {
        guard !cleanupPersonalContextMigrated else { return }
        if cleanupPersonalContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            cleanupPersonalContext = CleanupPrompt.defaultPersonalContext
        }
        cleanupPersonalContextMigrated = true
    }

    /// One-time: split the old single custom-instructions blob into personal + exceptions drafts.
    private func migrateSystemPromptLayers() {
        guard !systemPromptLayersMigrated else { return }
        systemPromptLayersMigrated = true
        let split = CleanupPrompt.splitLegacyPersonalContext(cleanupPersonalContext)
        if cleanupPersonalNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            cleanupPersonalNotes = split.notes.isEmpty ? CleanupPrompt.defaultPersonalNotes : split.notes
        }
        if cleanupExceptions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            cleanupExceptions = split.exceptions.isEmpty ? CleanupPrompt.defaultExceptions : split.exceptions
        }
        commitSystemPrompt()
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

    private static func appNameKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var openAIAPIKey: String {
        get { KeychainHelper.load(account: "openai_api_key") ?? "" }
        set { _ = saveOpenAIAPIKey(newValue) }
    }

    var anthropicAPIKey: String {
        get { KeychainHelper.load(account: "anthropic_api_key") ?? "" }
        set { _ = saveAnthropicAPIKey(newValue) }
    }

    @discardableResult
    func saveOpenAIAPIKey(_ value: String) -> Bool {
        saveAPIKey(account: "openai_api_key", value: value)
    }

    @discardableResult
    func saveAnthropicAPIKey(_ value: String) -> Bool {
        saveAPIKey(account: "anthropic_api_key", value: value)
    }

    private func saveAPIKey(account: String, value: String) -> Bool {
        let ok: Bool
        if value.isEmpty {
            KeychainHelper.delete(account: account)
            ok = true
        } else {
            ok = KeychainHelper.save(account: account, value: value)
        }
        if ok {
            applyAPIKeyCache(account: account, value: value)
        }
        objectWillChange.send()
        return ok
    }

    private func refreshAPIKeyCache() {
        applyAPIKeyCache(account: "openai_api_key", value: KeychainHelper.load(account: "openai_api_key") ?? "")
        applyAPIKeyCache(account: "anthropic_api_key", value: KeychainHelper.load(account: "anthropic_api_key") ?? "")
    }

    private func applyAPIKeyCache(account: String, value: String) {
        let suffix = Self.keySuffix(value)
        switch account {
        case "openai_api_key":
            hasOpenAIKey = suffix != nil
            openAIKeySuffix = suffix
        case "anthropic_api_key":
            hasAnthropicKey = suffix != nil
            anthropicKeySuffix = suffix
        default:
            break
        }
    }

    private static func keySuffix(_ key: String) -> String? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.suffix(4))
    }
}

enum KeychainHelper {
    private static let service = AppIdentity.keychainService
    private static let logger = Logger(subsystem: service, category: "keychain")

    /// Returns false when the Keychain refused the write. Callers must not assume a
    /// successful save — a silent failure looks identical to a stored key in the UI.
    @discardableResult
    static func save(account: String, value: String) -> Bool {
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
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            logger.error("Keychain save failed for \(account, privacy: .public): \(message, privacy: .public)")
            return false
        }
        return true
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
