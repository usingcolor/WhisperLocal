import CryptoKit
import Foundation
import Security

struct CBError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Command-line entry. Everything runs from the repository root.
enum ContextBench {
    /// Bump when the harness changes how a take is run, so cached outputs from
    /// the old behaviour are not mixed with new ones.
    static let harnessVersion = "1"

    static let usage = """
    usage: context-bench <command> [options]

    Measures automatic context: whether it helps polish recover names, what it
    costs, and how well the topics are kept. See Benchmarks/ContextBench/README.md.

    commands
      validate     Check the session cases against themselves. Free, no network.
      seed-check   Ask whether the model repeats itself given a fixed seed.
      sessions     Run the scripted sessions through every arm and score them.
      real-log     Replay the Dev dictation log and write the blind comparison page.
      blind-score  Score the choices saved from the blind comparison page.
      report       Rebuild a sessions run's report from its saved steps. Free.

    options
      --model      OpenAI model (default: the Dev app's, else gpt-6-luna)
      --polish     cloud or apple: who polishes (default cloud)
      --updater    cloud or apple: who keeps the topics (default: the polisher)
      --arms       plain,oracle,separate (default all)
      --sessions   only these, as s01,s02 (default all)
      --cases      session JSON file (default cases/sessions.json)
      --samples    runs per take per arm (default 3; 1 when --seed repeats
                   or Apple Intelligence polishes)
      --seed       fixed seed sent with every request
      --parallel   sessions in flight (default 6)
      --name       run name (default: today's date and time)
      --fresh      ignore cached outputs
      --keychain   read the API key WhisperLocal saved when OPENAI_API_KEY is unset
      --pairs      real-log: most context pairs on the page (default 40)
      --noise      real-log: most noise pairs mixed in (default 10)
      --results    blind-score: the JSON the page saved
    """

    static func main(_ arguments: [String]) async throws {
        let options = try CBOptions(arguments)
        let paths = CBPaths(
            root: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            casesOverride: options.values["cases"].map { URL(fileURLWithPath: $0) }
        )
        switch options.command {
        case "validate": try Validate.run(paths: paths)
        case "seed-check": try await SeedCheck.run(options, paths: paths)
        case "sessions": try await SessionsCommand.run(options, paths: paths)
        case "real-log": try await RealLog.run(options, paths: paths)
        case "blind-score": try BlindScore.run(options, paths: paths)
        case "report": try SessionsCommand.report(options, paths: paths)
        case "help", "-h", "--help": print(usage)
        default: throw CBError("unknown command \(options.command)\n\n\(usage)")
        }
    }
}

struct CBOptions {
    let command: String
    var values: [String: String] = [:]
    var flags: Set<String> = []

    init(_ arguments: [String]) throws {
        guard let first = arguments.first else { throw CBError(ContextBench.usage) }
        command = first
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            guard argument.hasPrefix("--") else { throw CBError("unexpected \(argument)") }
            let name = String(argument.dropFirst(2))
            if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
                values[name] = arguments[index + 1]
                index += 2
            } else {
                flags.insert(name)
                index += 1
            }
        }
    }

    func int(_ name: String, _ fallback: Int) -> Int {
        values[name].flatMap(Int.init) ?? fallback
    }

    var runName: String {
        if let name = values["name"] { return name }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return formatter.string(from: Date())
    }
}

struct CBPaths {
    let root: URL
    var casesOverride: URL? = nil
    var cases: URL { casesOverride ?? root.appending(path: "Benchmarks/ContextBench/cases/sessions.json") }
    var template: URL { root.appending(path: "Benchmarks/ContextBench/blind.html") }
    /// Under Benchmarks/results, which git ignores: real-log runs hold real dictation.
    var results: URL { root.appending(path: "Benchmarks/results/context") }
    var cache: URL { results.appending(path: "cache") }
    func run(_ name: String) -> URL { results.appending(path: name) }
}

enum CBKeys {
    /// The environment first. WhisperLocal's Keychain item only when asked for,
    /// because reading it makes macOS ask whoever is at the Mac to allow it.
    static func openAI(allowKeychain: Bool) throws -> String {
        if let value = ProcessInfo.processInfo.environment["OPENAI_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            return value
        }
        if allowKeychain {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: AppIdentity.publicBundleID,
                kSecAttrAccount as String: "openai_api_key",
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var item: CFTypeRef?
            if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
               let data = item as? Data,
               let key = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !key.isEmpty {
                return key
            }
        }
        throw CBError("no OpenAI key: set OPENAI_API_KEY, or pass --keychain to use WhisperLocal's")
    }
}

/// Outputs keyed by everything that went into them, one file each, so a rerun
/// pays only for what changed and parallel runs never write the same file.
struct CBCache {
    let directory: URL
    let fresh: Bool

    static func key(_ parts: [String]) -> String {
        let digest = SHA256.hash(data: Data(parts.joined(separator: "\u{1F}").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func load<T: Decodable>(_ key: String, as type: T.Type) -> T? {
        guard !fresh, let data = try? Data(contentsOf: directory.appending(path: key + ".json")) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    func save<T: Encodable>(_ value: T, key: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(value) {
            try? data.write(to: directory.appending(path: key + ".json"), options: .atomic)
        }
    }
}

/// The Dev app's own settings, for the real-log replay and the default model.
enum CBDevSettings {
    static let defaults = UserDefaults(suiteName: "com.usingcolor.WhisperLocal.dev")
    static var model: String { defaults?.string(forKey: "openAIModel") ?? "gpt-6-luna" }
    static var personalContext: String { defaults?.string(forKey: "cleanupPersonalContext") ?? "" }
    static var dictionary: [String] {
        let raw = defaults?.string(forKey: "dictionaryWords") ?? ""
        return CleanupPrompt.mergedDictionary(
            raw.split(whereSeparator: { $0 == "," || $0 == "\n" })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        )
    }
}
