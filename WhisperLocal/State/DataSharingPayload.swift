import Foundation
import NaturalLanguage

/// The policy used to prepare an upload. A stricter policy invalidates an older
/// payload; its source app is deliberately absent from the redacted payload.
struct DataSharingPrivacyPolicy: Codable, Equatable {
    let hideNames: Bool
    let excludedApps: [String]

    init(hideNames: Bool, excludedApps: [String]) {
        self.hideNames = hideNames
        self.excludedApps = Array(Set(excludedApps.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }.filter { !$0.isEmpty })).sorted()
    }

    func permits(_ previous: DataSharingPrivacyPolicy?) -> Bool {
        guard let previous else { return false }
        return (!hideNames || previous.hideNames)
            && Set(excludedApps).isSubset(of: Set(previous.excludedApps))
    }
}

/// Sending takes to WhisperLocal's developer, for people who opt in. Dev only
/// while it is tried, against a server on this Mac.
///
/// What is here is the part the tests hold: what a shared take contains, what
/// is taken out of it on the Mac before it leaves, and the requests to the
/// server. `DataSharingStore` keeps the consent, the queue and the uploads.
enum DataSharing {
    // Keep volunteer submissions out of 0.2.5, including installs with old consent.
    static var isEnabled: Bool { isEnabled(bundleID: AppIdentity.bundleID) }

    static func isEnabled(bundleID: String) -> Bool {
        AppIdentity.isDev(bundleID: bundleID)
    }

    /// Changes whenever the consent text does, and travels with every take so
    /// the server knows what each one was shared under. A draft for testing:
    /// the text must be reviewed by a lawyer before this reaches Release.
    static let consentVersion = "2026-09-29.1"
    /// How long a take queued automatically waits before it is sent, so
    /// anything said by mistake can be taken out of the queue.
    static let holdInterval: TimeInterval = 10 * 60
    static let retentionMonths = 12
    static let defaultServerURL = "http://127.0.0.1:8787"
    /// Never queued, whatever was said into them.
    static let defaultExcludedApps = [
        "1Password", "Bitwarden", "Passwords", "Keychain Access", "LastPass",
        "Dashlane", "KeePassXC", "Proton Pass", "Enpass",
    ]

    /// An excluded app is matched by name, loosely: "1Password" covers "1Password 7".
    static func isExcluded(appName: String?, excluded: [String]) -> Bool {
        guard let appName = appName?.trimmingCharacters(in: .whitespaces), !appName.isEmpty else { return false }
        return excluded.contains { name in
            let name = name.trimmingCharacters(in: .whitespaces)
            return !name.isEmpty && appName.localizedCaseInsensitiveContains(name)
        }
    }
}

enum DataSharingScope: String, Codable, CaseIterable, Sendable {
    /// Find and fix polishing mistakes. Joining means this.
    case improve
    /// Train models. Asked for on its own, never implied by `improve`.
    case train
}

struct DataSharingConsent: Codable, Equatable, Sendable {
    var version: String
    /// Empty once sharing is stopped: the withdrawal is itself a record.
    var scopes: [DataSharingScope]
    var acceptedAt: Date

    var isActive: Bool { scopes.contains(.improve) }
}

/// One take as it leaves the Mac. Everything a take can reveal that polish
/// quality does not need stays behind: the audio, the app's name, the window
/// title, the microphone, the time of day, the custom instructions.
struct SharedTake: Codable, Equatable, Identifiable, Sendable {
    /// The log entry's own random id, so the same take is never counted twice.
    let id: UUID
    /// The day only.
    let day: String
    let appVersion: String
    let language: String?
    /// The kind of app — "chat app", "code editor" — never its name.
    let appKind: String
    let speechModel: String?
    let polishModel: String?
    /// The polish steps that ran, e.g. ["Fillers", "OpenAI"]. Where the text
    /// was inserted names the app, so that step is dropped.
    let stages: [String]
    let raw: String
    let polished: String
    /// The auto-context topics polish was shown, redacted like the text.
    let contextTopics: [String]?
    let audioSeconds: Double?
    let cleanupNote: String?
    /// What was taken out, by kind: ["name": 2, "email": 1].
    let redacted: [String: Int]

    /// Nil for a take that is not shared at all: not inserted, empty, or
    /// dictated into an excluded app.
    static func make(
        from entry: DictationLogEntry,
        hideNames: Bool,
        excludedApps: [String],
        appVersion: String
    ) -> SharedTake? {
        let raw = entry.raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let polished = entry.polished.trimmingCharacters(in: .whitespacesAndNewlines)
        guard entry.outcome == .success, !raw.isEmpty, !polished.isEmpty,
              !DataSharing.isExcluded(appName: entry.appName, excluded: excludedApps) else { return nil }
        let topics = entry.autoContext ?? []
        let redaction = TakeRedactor(hideNames: hideNames).redact([raw, polished] + topics)
        return SharedTake(
            id: entry.id,
            day: dayFormatter.string(from: entry.date),
            appVersion: appVersion,
            language: entry.language,
            appKind: TargetAppContext.kind(bundleID: nil, name: entry.appName).rawValue,
            speechModel: entry.speechModel,
            polishModel: entry.polishModel,
            stages: entry.stages.filter { !$0.hasPrefix("insert:") },
            raw: redaction.texts[0],
            polished: redaction.texts[1],
            contextTopics: entry.autoContext == nil ? nil : Array(redaction.texts.dropFirst(2)),
            audioSeconds: entry.audioSeconds.map { ($0 * 10).rounded() / 10 },
            cleanupNote: entry.cleanupNote,
            redacted: redaction.counts
        )
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

/// Replaces what identifies someone with numbered placeholders, before a take
/// leaves the Mac. The same thing gets the same placeholder in every field of
/// a take, so the raw and polished text still line up: "Send it to [NAME_1]"
/// in both.
///
/// A name found in one field is replaced in all of them, whatever its case —
/// the recogniser's lowercase "joaquin" as well as polish's "Joaquin". Names
/// come from Apple's on-device tagger, which does not read every language:
/// Korean names, for one, are not caught.
struct TakeRedactor {
    enum Kind: String, CaseIterable {
        // In order of precedence, for two finds over the same words: a
        // resident number is an id even when it happens to pass as a card.
        case secret, id, card, email, url, phone, address, name
    }

    struct Result: Equatable {
        let texts: [String]
        let counts: [String: Int]
    }

    let hideNames: Bool

    func redact(_ texts: [String]) -> Result {
        var found = texts.map(spans(in:))
        if hideNames {
            // Every name any field produced, looked for again in every field.
            let names = Set(found.joined().filter { $0.kind == .name }.map { $0.text.lowercased() })
            for index in texts.indices {
                for name in names {
                    found[index] += occurrences(of: name, in: texts[index]).map { Span(range: $0, kind: .name, text: String(texts[index][$0])) }
                }
            }
        }
        found = found.map(Self.resolved)

        // One placeholder per distinct thing, numbered in reading order.
        var numbers: [Kind: [String: Int]] = [:]
        var counts: [String: Int] = [:]
        for span in found.joined() {
            let key = Self.normalized(span.text, kind: span.kind)
            if numbers[span.kind]?[key] == nil {
                numbers[span.kind, default: [:]][key] = (numbers[span.kind]?.count ?? 0) + 1
            }
            counts[span.kind.rawValue, default: 0] += 1
        }
        let redacted = zip(texts, found).map { text, spans in
            var text = text
            for span in spans.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
                let number = numbers[span.kind]?[Self.normalized(span.text, kind: span.kind)] ?? 1
                text.replaceSubrange(span.range, with: "[\(span.kind.rawValue.uppercased())_\(number)]")
            }
            return text
        }
        return Result(texts: redacted, counts: counts)
    }

    private struct Span {
        let range: Range<String.Index>
        let kind: Kind
        let text: String
    }

    private func spans(in text: String) -> [Span] {
        var spans: [Span] = []
        let whole = NSRange(text.startIndex..., in: text)
        if let detector = Self.detector {
            for match in detector.matches(in: text, range: whole) {
                guard let range = Range(match.range, in: text) else { continue }
                let kind: Kind
                switch match.resultType {
                case .link: kind = match.url?.scheme?.lowercased() == "mailto" ? .email : .url
                case .phoneNumber: kind = .phone
                case .address: kind = .address
                default: continue
                }
                spans.append(Span(range: range, kind: kind, text: String(text[range])))
            }
        }
        for (kind, regex) in Self.patterns {
            for match in regex.matches(in: text, range: whole) {
                guard let range = Range(match.range, in: text) else { continue }
                let found = String(text[range])
                if kind == .card, !Self.passesLuhn(found) { continue }
                spans.append(Span(range: range, kind: kind, text: found))
            }
        }
        if hideNames {
            let tagger = NLTagger(tagSchemes: [.nameType])
            tagger.string = text
            tagger.enumerateTags(
                in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
                options: [.omitWhitespace, .omitPunctuation, .joinNames]
            ) { tag, range in
                if tag == .personalName {
                    spans.append(Span(range: range, kind: .name, text: String(text[range])))
                }
                return true
            }
        }
        return spans
    }

    /// Whole-word, case-insensitive.
    private func occurrences(of name: String, in text: String) -> [Range<String.Index>] {
        guard let regex = try? NSRegularExpression(
            pattern: "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: name) + "(?![\\p{L}\\p{N}])",
            options: [.caseInsensitive]
        ) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text) }
    }

    /// Keeps one find where two overlap: the earlier, then the longer, then
    /// the kind that matters more.
    private static func resolved(_ spans: [Span]) -> [Span] {
        let ordered = spans.sorted {
            if $0.range.lowerBound != $1.range.lowerBound { return $0.range.lowerBound < $1.range.lowerBound }
            let a = $0.text.count, b = $1.text.count
            if a != b { return a > b }
            return Kind.allCases.firstIndex(of: $0.kind)! < Kind.allCases.firstIndex(of: $1.kind)!
        }
        var kept: [Span] = []
        for span in ordered where !kept.contains(where: { $0.range.overlaps(span.range) }) {
            kept.append(span)
        }
        return kept
    }

    private static func normalized(_ text: String, kind: Kind) -> String {
        switch kind {
        case .phone, .card, .id: return text.filter(\.isNumber)
        default: return text.lowercased().trimmingCharacters(in: .whitespaces)
        }
    }

    private static func passesLuhn(_ text: String) -> Bool {
        let digits = text.compactMap(\.wholeNumberValue)
        guard (13...19).contains(digits.count) else { return false }
        let sum = digits.reversed().enumerated().reduce(0) { sum, pair in
            let (index, digit) = pair
            guard index % 2 == 1 else { return sum + digit }
            let doubled = digit * 2
            return sum + (doubled > 9 ? doubled - 9 : doubled)
        }
        return sum % 10 == 0
    }

    private static let detector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
            | NSTextCheckingResult.CheckingType.phoneNumber.rawValue
            | NSTextCheckingResult.CheckingType.address.rawValue
    )

    private static let patterns: [(Kind, NSRegularExpression)] = [
        // Keys and tokens: the prefixes services use, then any long mix of letters and digits.
        (.secret, #"\b(?:sk-[A-Za-z0-9_\-]{16,}|sk_(?:live|test|car)_[A-Za-z0-9]{12,}|gh[pousr]_[A-Za-z0-9]{20,}|xox[abprs]-[A-Za-z0-9\-]{10,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_\-]{35})\b"#),
        (.secret, #"\b(?=[A-Za-z0-9_\-]*\d)(?=[A-Za-z0-9_\-]*[A-Za-z])[A-Za-z0-9_\-]{24,}\b"#),
        (.card, #"\b(?:\d[ \-]?){12,18}\d\b"#),
        // Korean resident registration numbers, US social security numbers.
        (.id, #"\b\d{6}[\- ]?[1-8]\d{6}\b"#),
        (.id, #"\b\d{3}-\d{2}-\d{4}\b"#),
        (.email, #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#),
    ].compactMap { kind, pattern in
        (try? NSRegularExpression(pattern: pattern)).map { (kind, $0) }
    }
}

enum DataSharingError: LocalizedError, Equatable {
    case serverURL(String)
    case notJoined
    case unreachable(String)
    case rejected(Int, String)

    var errorDescription: String? {
        switch self {
        case .serverURL(let reason): return reason
        case .notJoined: return "Not joined."
        case .unreachable(let reason): return "Could not reach the server: \(reason)"
        case .rejected(let status, let message): return "The server said no (\(status)): \(message)"
        }
    }
}

/// The requests to the data-sharing server. HTTPS, except to this Mac, where
/// the local test server runs.
struct DataSharingClient: Sendable {
    let baseURL: URL
    var token: String? = nil

    struct Enrollment: Codable, Equatable, Sendable {
        let installId: String
        let token: String
    }

    struct Accepted: Codable, Sendable {
        let accepted: [UUID]
        let duplicates: [UUID]
    }

    private struct Deleted: Codable { let deletedTakes: Int }

    /// Only https, or plain http to this Mac: takes never cross a network unencrypted.
    static func serverURL(_ text: String) throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else {
            throw DataSharingError.serverURL("That is not a server address.")
        }
        let local = ["localhost", "127.0.0.1", "::1"].contains(host)
        guard scheme == "https" || (scheme == "http" && local) else {
            throw DataSharingError.serverURL("The server must use https, except on this Mac.")
        }
        return url
    }

    func enroll(consent: DataSharingConsent, appVersion: String) async throws -> Enrollment {
        struct Body: Encodable { let consent: DataSharingConsent; let appVersion: String }
        return try await send("POST", "v1/enroll", body: Body(consent: consent, appVersion: appVersion), authorized: false)
    }

    func submit(_ takes: [SharedTake], consent: DataSharingConsent) async throws -> Accepted {
        struct Body: Encodable { let consent: DataSharingConsent; let takes: [SharedTake] }
        return try await send("POST", "v1/takes", body: Body(consent: consent, takes: takes))
    }

    func updateConsent(_ consent: DataSharingConsent) async throws {
        struct Ok: Decodable { let ok: Bool }
        let _: Ok = try await send("PUT", "v1/consent", body: consent)
    }

    /// Everything the server holds for this install, as it sent it.
    func export() async throws -> Data {
        try await raw("GET", "v1/export", body: nil as Data?)
    }

    func deleteEverything() async throws -> Int {
        let deleted: Deleted = try await send("DELETE", "v1/me", body: nil as Data?)
        return deleted.deletedTakes
    }

    // MARK: -

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private func send<Body: Encodable, Response: Decodable>(
        _ method: String, _ path: String, body: Body?, authorized: Bool = true
    ) async throws -> Response {
        let data = try await raw(method, path, body: body, authorized: authorized)
        return try Self.decoder.decode(Response.self, from: data)
    }

    private func raw<Body: Encodable>(_ method: String, _ path: String, body: Body?, authorized: Bool = true) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = 20
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try Self.encoder.encode(body)
        }
        if authorized {
            guard let token else { throw DataSharingError.notJoined }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw DataSharingError.unreachable(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw DataSharingError.rejected(status, message ?? String(decoding: data.prefix(200), as: UTF8.self))
        }
        return data
    }
}
