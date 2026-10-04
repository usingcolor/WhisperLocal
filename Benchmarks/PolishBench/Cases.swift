import Foundation

/// One test: what the speech model produced, and what should have been pasted.
struct BenchCase: Codable, Sendable {
    let id: String
    let category: String
    /// Transcript as the speech model hands it to polish.
    let raw: String
    /// One acceptable clean version. Judges are told it is not the only one.
    let reference: String
    /// Target-app line exactly as the app sends it, e.g. "Slack — chat app".
    var app: String?
    /// BCP-47 code. Absent means English.
    var language: String?
    /// Terms added to the default dictionary for this case.
    var dictionary: [String]?
    var sessionIntent: String?
    /// "dictation" (default) or "sessionContext".
    var task: String?
    /// Absent: a fresh install's default notes. Empty: no notes at all.
    var personalContext: String?
    var checks: CaseChecks?
    /// One of the ten pilot cases.
    var pilot: Bool?
    /// Why the case exists, for whoever edits it next.
    var note: String?
}

/// Rules a script can check. Anything subtler is left to the judges.
struct CaseChecks: Codable, Sendable {
    /// Text the output must contain: case-sensitive, with quotes and spaces normalised.
    var mustContain: [String]?
    /// Words or phrases that must not appear: case-insensitive, whole words.
    var mustNotContain: [String]?
    /// The output must equal the reference.
    var verbatim: Bool?
    /// Allowed output length against the reference, in non-space characters.
    var minRatio: Double?
    var maxRatio: Double?
}

extension BenchCase {
    var spokenLanguage: SpokenLanguage { SpokenLanguage(code: language ?? "en") }
    var polishTask: PolishTask { task == "sessionContext" ? .sessionContext : .dictation }

    /// The app always sends its default dictionary; a case can add to it.
    var promptDictionary: [String] {
        CleanupPrompt.mergedDictionary(CleanupPrompt.defaultDictionary + (dictionary ?? []))
    }

    var promptPersonalContext: String {
        personalContext ?? CleanupPrompt.defaultPersonalContext
    }

    /// Prompts are tuned on one half and reported on the other. Decided by the id
    /// alone, so adding cases never moves an existing one to the other half.
    var half: String { Self.fnv1a(id) % 2 == 0 ? "tune" : "test" }

    /// Korean is scored by characters: word spacing varies between correct answers.
    var scoresByCharacter: Bool {
        ["ko", "ja", "zh"].contains(spokenLanguage.base)
    }

    static func fnv1a(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}

struct CaseSet: Codable {
    var cases: [BenchCase]

    static func load(_ url: URL) throws -> [BenchCase] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw BenchError("can't read \(url.path)")
        }
        let set = try JSONDecoder().decode(CaseSet.self, from: data)
        var seen = Set<String>()
        for item in set.cases where !seen.insert(item.id).inserted {
            throw BenchError("duplicate case id \(item.id) in \(url.lastPathComponent)")
        }
        return set.cases
    }
}
