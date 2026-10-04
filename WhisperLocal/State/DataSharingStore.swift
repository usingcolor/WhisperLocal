import Foundation
import os

/// Consent, the queue and the uploads for data sharing. Dev only while it is
/// tried; `DataSharing` has the rules a shared take follows.
///
/// Nothing is sent before someone joins, and joining asks twice: whether to
/// share takes at all, and separately whether they may train models. A take
/// shared as it happens waits in the queue for `DataSharing.holdInterval`
/// before it goes; one sent from the log goes once it is confirmed.
///
/// Every change of mind takes effect here first and reaches the server after:
/// stopping clears the queue at once, even offline, and the server is told on
/// the next attempt. The token that proves who is asking lives in the
/// Keychain; the install id and the consent in defaults.
@MainActor
final class DataSharingStore: ObservableObject {
    static let shared = DataSharingStore()

    struct QueuedTake: Codable, Identifiable, Equatable {
        var id: UUID { take.id }
        let take: SharedTake
        let queuedAt: Date
        /// Sent from the log, or released from the queue: already looked at, so it does not wait.
        var chosen: Bool
        var privacyPolicy: DataSharingPrivacyPolicy? = nil

        func sendsAt() -> Date {
            chosen ? queuedAt : queuedAt.addingTimeInterval(DataSharing.holdInterval)
        }
    }

    @Published private(set) var consent: DataSharingConsent?
    @Published private(set) var installID: String?
    @Published private(set) var queue: [QueuedTake] = []
    /// Take ids already sent, with the day of each, so none goes twice.
    @Published private(set) var sent: [String: String] = [:]
    @Published private(set) var lastResult: String?
    @Published private(set) var lastError: String?
    @Published private(set) var isBusy = false

    @Published var shareAutomatically: Bool { didSet { defaults.set(shareAutomatically, forKey: Keys.automatic) } }
    @Published var hideNames: Bool { didSet {
        defaults.set(hideNames, forKey: Keys.hideNames)
        applyPrivacyPolicy()
    } }
    @Published var excludedAppsText: String { didSet {
        defaults.set(excludedAppsText, forKey: Keys.excluded)
        applyPrivacyPolicy()
    } }
    @Published var serverAddress: String { didSet { defaults.set(serverAddress, forKey: Keys.server) } }

    var isSharing: Bool { consent?.isActive == true }
    var allowsTraining: Bool { consent?.scopes.contains(.train) == true }
    /// Joined at some point and still able to reach what was sent. Stopping
    /// keeps it, so the takes can be downloaded or deleted afterwards.
    var hasCredentials: Bool { installID != nil && token != nil }
    var excludedApps: [String] {
        excludedAppsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    func wasSent(_ id: UUID) -> Bool { sent[id.uuidString] != nil }
    func isQueued(_ id: UUID) -> Bool { queue.contains { $0.id == id } }

    private let defaults = UserDefaults.standard
    private let logger = Logger(subsystem: "com.usingcolor.WhisperLocal", category: "data-sharing")
    private let folder: URL
    private var timer: Timer?
    private var retryAfter: Date?
    private var failures = 0
    /// A consent change the server has not acknowledged yet.
    private var consentUnsynced: Bool { didSet { defaults.set(consentUnsynced, forKey: Keys.unsynced) } }

    private enum Keys {
        static let consent = "dataSharing.consent"
        static let installID = "dataSharing.installID"
        static let unsynced = "dataSharing.consentUnsynced"
        static let automatic = "dataSharing.shareAutomatically"
        static let hideNames = "dataSharing.hideNames"
        static let excluded = "dataSharing.excludedApps"
        static let server = "dataSharing.server"
        static let token = "data_sharing_token_dev"
    }

    private var token: String? { KeychainHelper.load(account: Keys.token) }

    /// Plain keys for files on this Mac. The server's snake_case would lowercase
    /// the take ids the sent list is keyed by, and nothing would ever match.
    private static let fileEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let fileDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private init() {
        shareAutomatically = defaults.object(forKey: Keys.automatic) as? Bool ?? false
        hideNames = defaults.object(forKey: Keys.hideNames) as? Bool ?? true
        excludedAppsText = defaults.string(forKey: Keys.excluded) ?? DataSharing.defaultExcludedApps.joined(separator: ", ")
        serverAddress = defaults.string(forKey: Keys.server) ?? DataSharing.defaultServerURL
        consentUnsynced = defaults.bool(forKey: Keys.unsynced)
        installID = defaults.string(forKey: Keys.installID)
        consent = defaults.data(forKey: Keys.consent).flatMap { try? Self.fileDecoder.decode(DataSharingConsent.self, from: $0) }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        folder = base.appendingPathComponent(AppIdentity.supportFolderName, isDirectory: true)
        queue = read([QueuedTake].self, from: "data-sharing-queue.json") ?? []
        sent = read([String: String].self, from: "data-sharing-sent.json") ?? [:]
        applyPrivacyPolicy()
    }

    /// Resumes whatever was waiting when the app last quit.
    func start() {
        guard DataSharing.isEnabled, timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in await DataSharingStore.shared.flush() }
        }
        Task { await flush() }
    }

    // MARK: - Joining and leaving

    func join(allowTraining: Bool) async {
        let consent = DataSharingConsent(
            version: DataSharing.consentVersion,
            scopes: allowTraining ? [.improve, .train] : [.improve],
            acceptedAt: Date()
        )
        await attempt {
            if self.hasCredentials {
                // Joined before and stopped: the same install, a new consent.
                try await self.client().updateConsent(consent)
            } else {
                let enrollment = try await self.client(authorized: false)
                    .enroll(consent: consent, appVersion: AppIdentity.versionSummary)
                guard KeychainHelper.save(account: Keys.token, value: enrollment.token) else {
                    throw DataSharingError.rejected(0, "the Keychain would not keep the server's token")
                }
                self.installID = enrollment.installId
                self.defaults.set(enrollment.installId, forKey: Keys.installID)
            }
            self.record(consent, synced: true)
            return "Joined."
        }
    }

    func setTraining(_ allowed: Bool) async {
        guard let current = consent, current.isActive, allowsTraining != allowed else { return }
        let consent = DataSharingConsent(
            version: DataSharing.consentVersion,
            scopes: allowed ? [.improve, .train] : [.improve],
            acceptedAt: Date()
        )
        record(consent, synced: false)
        await flush()
    }

    /// Takes effect at once, offline too; the server hears on the next attempt.
    func stopSharing() async {
        guard let current = consent else { return }
        record(DataSharingConsent(version: current.version, scopes: [], acceptedAt: Date()), synced: false)
        queue = []
        writeQueue()
        shareAutomatically = false
        lastResult = "Stopped. Takes already sent stay on the server until you delete them."
        await flush()
    }

    /// Everything the server holds for this install, and every local trace of joining.
    func deleteEverything() async {
        await attempt {
            let deleted = try await self.client().deleteEverything()
            KeychainHelper.delete(account: Keys.token)
            self.installID = nil
            self.defaults.removeObject(forKey: Keys.installID)
            self.consent = nil
            self.defaults.removeObject(forKey: Keys.consent)
            self.consentUnsynced = false
            self.queue = []
            self.writeQueue()
            self.sent = [:]
            self.write(self.sent, to: "data-sharing-sent.json")
            self.shareAutomatically = false
            return deleted == 1 ? "Deleted 1 take from the server." : "Deleted \(deleted) takes from the server."
        }
    }

    func download() async -> Data? {
        var data: Data?
        await attempt {
            data = try await self.client().export()
            return "Downloaded."
        }
        return data
    }

    // MARK: - Takes

    /// A finished take, queued if its speaker shares takes as they happen.
    func takeFinished(_ entry: DictationLogEntry) {
        guard DataSharing.isEnabled, isSharing, shareAutomatically, !wasSent(entry.id), !isQueued(entry.id),
              let take = preview(entry) else { return }
        queue.append(QueuedTake(take: take, queuedAt: Date(), chosen: false, privacyPolicy: privacyPolicy))
        writeQueue()
    }

    /// Exactly what would leave the Mac for this take, or nil if it would not.
    func preview(_ entry: DictationLogEntry) -> SharedTake? {
        SharedTake.make(from: entry, hideNames: hideNames, excludedApps: excludedApps, appVersion: AppIdentity.versionSummary)
    }

    /// Sends one take now, from the log, as it was previewed.
    func send(_ take: SharedTake, from entry: DictationLogEntry) async {
        guard DataSharing.isEnabled, isSharing, !wasSent(take.id) else { return }
        guard preview(entry) == take else {
            lastError = "Privacy settings changed. Review the updated preview before sending."
            return
        }
        queue.removeAll { $0.id == take.id }
        queue.append(QueuedTake(take: take, queuedAt: Date(), chosen: true, privacyPolicy: privacyPolicy))
        writeQueue()
        await flush(now: true)
    }

    /// So a sheet opens on what it is about, not on an old failure.
    func clearMessages() {
        lastResult = nil
        lastError = nil
    }

    func remove(_ id: UUID) {
        queue.removeAll { $0.id == id }
        writeQueue()
    }

    func sendQueuedNow() async {
        guard DataSharing.isEnabled else { return }
        for index in queue.indices { queue[index].chosen = true }
        writeQueue()
        await flush(now: true)
    }

    /// Sends what is due, after telling the server of any change of consent.
    /// Backs off after a failure, from a minute to half an hour.
    func flush(now: Bool = false) async {
        guard DataSharing.isEnabled else { return }
        applyPrivacyPolicy()
        guard !isBusy, hasCredentials else { return }
        if !now, let retryAfter, retryAfter > Date() { return }
        isBusy = true
        defer { isBusy = false }
        do {
            if consentUnsynced, let consent {
                try await client().updateConsent(consent)
                consentUnsynced = false
            }
            guard let consent, consent.isActive else { return succeeded() }
            applyPrivacyPolicy()
            let due = queue.filter { $0.sendsAt() <= Date() }.prefix(50)
            guard !due.isEmpty else { return succeeded() }
            let result = try await client().submit(due.map(\.take), consent: consent)
            let done = Set(result.accepted + result.duplicates)
            for item in due where done.contains(item.id) {
                sent[item.id.uuidString] = item.take.day
            }
            queue.removeAll { done.contains($0.id) }
            writeQueue()
            write(sent, to: "data-sharing-sent.json")
            lastResult = done.count == 1 ? "Sent 1 take." : "Sent \(done.count) takes."
            succeeded()
        } catch {
            failures += 1
            retryAfter = Date().addingTimeInterval(min(1800, 60 * pow(2, Double(failures - 1))))
            lastError = error.localizedDescription
            logger.error("Data sharing: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func succeeded() {
        failures = 0
        retryAfter = nil
        lastError = nil
    }

    // MARK: -

    private func record(_ consent: DataSharingConsent, synced: Bool) {
        self.consent = consent
        defaults.set(try? Self.fileEncoder.encode(consent), forKey: Keys.consent)
        consentUnsynced = !synced
    }

    private func client(authorized: Bool = true) throws -> DataSharingClient {
        guard DataSharing.isEnabled else { throw DataSharingError.notJoined }
        let url = try DataSharingClient.serverURL(serverAddress)
        guard authorized else { return DataSharingClient(baseURL: url) }
        guard let token else { throw DataSharingError.notJoined }
        return DataSharingClient(baseURL: url, token: token)
    }

    private func attempt(_ work: @escaping () async throws -> String) async {
        guard DataSharing.isEnabled, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            lastResult = try await work()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func writeQueue() { write(queue, to: "data-sharing-queue.json") }

    private var privacyPolicy: DataSharingPrivacyPolicy {
        DataSharingPrivacyPolicy(hideNames: hideNames, excludedApps: excludedApps)
    }

    private func applyPrivacyPolicy() {
        let before = queue.count
        let current = privacyPolicy
        queue.removeAll { !current.permits($0.privacyPolicy) }
        if queue.count != before {
            writeQueue()
            lastResult = "Privacy settings changed. Removed \(before - queue.count) pending takes; you can choose them again from the log."
        }
    }

    /// Only this user can read these: they hold what was said.
    private func write<T: Encodable>(_ value: T, to name: String) {
        let url = folder.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Self.fileEncoder.encode(value).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            logger.error("Could not save \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func read<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)) else { return nil }
        return try? Self.fileDecoder.decode(type, from: data)
    }
}
