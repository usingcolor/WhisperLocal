import Foundation

/// Installer script output. Survives the pre-quit handoff so the next launch can show a failure.
enum UpdateInstallLog {
    static var directory: URL {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return library.appendingPathComponent("Logs/WhisperLocal", isDirectory: true)
    }

    static var fileURL: URL {
        directory.appendingPathComponent("update.log")
    }

    enum LastRun: Equatable {
        case none
        case succeeded
        case failed(String)
        case acknowledgedFailure
    }

    static func parse(_ text: String) -> LastRun {
        let blocks = text.components(separatedBy: "=== ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let last = blocks.last else { return .none }
        if last.contains("UPDATE_FAILURE_ACK") { return .acknowledgedFailure }
        if last.contains("UPDATE_OK") { return .succeeded }
        if last.contains("UPDATE_FAILED") {
            let lines = last.split(whereSeparator: \.isNewline).map(String.init)
            let detail = lines.filter {
                $0.contains("UPDATE_FAILED") || $0.localizedCaseInsensitiveContains("error")
            }.joined(separator: "\n")
            return .failed(detail.isEmpty ? String(last.suffix(400)) : detail)
        }
        return .none
    }

    static func readLastRun() -> LastRun {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return .none }
        return parse(text)
    }

    static func acknowledgeFailure() {
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data("UPDATE_FAILURE_ACK\n".utf8))
    }
}
