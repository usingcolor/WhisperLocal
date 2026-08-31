import AppKit
import CryptoKit
import Foundation
import Security

/// Fetches the public GitHub Release DMG and replaces `/Applications/WhisperLocal.app`.
/// UserDefaults and Keychain are outside the bundle, so personal settings stay put.
@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(AppUpdateFeed.Release)
        case downloading
        case installing
        case failed(String)
    }

    @Published private(set) var status: Status = .idle

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    var isBusy: Bool {
        switch status {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    var menuTitle: String {
        if AppIdentity.isDevBuild {
            return "Updates (public app only)"
        }
        switch status {
        case .idle:
            return "Check for Updates…"
        case .checking:
            return "Checking for Updates…"
        case .upToDate:
            return "Up to Date (\(Self.currentVersion))"
        case .available(let release):
            return "Install \(release.version)…"
        case .downloading:
            return "Downloading Update…"
        case .installing:
            return "Installing Update…"
        case .failed:
            return "Update Failed — Try Again"
        }
    }

    private let installURL = URL(fileURLWithPath: "/Applications/WhisperLocal.app")

    func handleMenuClick() async {
        if AppIdentity.isDevBuild {
            alert(
                title: "Updates are for the public app",
                message: """
                This is WhisperLocal Dev (\(installURL.path) is not touched). \
                Use Check for Updates from WhisperLocal, or install a GitHub Release, to update the public copy.
                """
            )
            return
        }
        switch status {
        case .available(let release):
            confirmAndInstall(release)
        default:
            await checkAndPrompt()
        }
    }

    func checkAndPrompt() async {
        await check()
        promptForCurrentStatus()
    }

    func check() async {
        status = .checking
        do {
            let release = try await fetchLatestRelease()
            if AppUpdateFeed.isNewer(latest: release.version, current: Self.currentVersion) {
                status = .available(release)
            } else {
                status = .upToDate
            }
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func fetchLatestRelease() async throws -> AppUpdateFeed.Release {
        var request = URLRequest(url: AppUpdateFeed.latestReleaseURL)
        request.setValue("WhisperLocal/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(code) else {
            throw UpdateError.http(code)
        }
        return try await attachChecksum(try AppUpdateFeed.parseRelease(from: data))
    }

    /// Missing `SHA256SUMS` is non-fatal (releases before pinning). A listed file that will not parse is ignored.
    private func attachChecksum(_ release: AppUpdateFeed.Release) async -> AppUpdateFeed.Release {
        guard let url = release.sha256SumsURL else { return release }
        var request = URLRequest(url: url)
        request.setValue("WhisperLocal/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<300).contains(code),
                  let text = String(data: data, encoding: .utf8) else {
                return release
            }
            var updated = release
            updated.sha256 = AppUpdateFeed.parseSHA256SUMS(text, for: release.dmgName)
            return updated
        } catch {
            return release
        }
    }

    private func promptForCurrentStatus() {
        switch status {
        case .upToDate:
            alert(
                title: "WhisperLocal is up to date",
                message: "This Mac is running \(Self.currentVersion). Personal settings are not changed by an update."
            )
        case .available(let release):
            confirmAndInstall(release)
        case .failed(let message):
            alert(title: "Could not check for updates", message: message)
        default:
            break
        }
    }

    private func confirmAndInstall(_ release: AppUpdateFeed.Release) {
        let alert = NSAlert()
        alert.messageText = "Install WhisperLocal \(release.version)?"
        alert.informativeText = """
        Downloads the public DMG from GitHub (\(AppUpdateFeed.owner)/\(AppUpdateFeed.repo)) and replaces \(installURL.path).

        Custom instructions, dictionary, and other Settings stay on this Mac. They are not inside the app bundle.

        The public build is ad-hoc signed, not notarized. macOS may ask you to allow it under System Settings → Privacy & Security after install. Do not expect the update to launch silently. You may need to approve Accessibility again.
        """
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await install(release) }
    }

    private func install(_ release: AppUpdateFeed.Release) async {
        if AppIdentity.isDevBuild { return }
        status = .downloading
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperLocalUpdate-\(UUID().uuidString)", isDirectory: true)
        let mount = work.appendingPathComponent("mount", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let dmgName = URL(fileURLWithPath: release.dmgName).lastPathComponent
            guard dmgName.lowercased().hasSuffix(".dmg"),
                  dmgName != ".", dmgName != "..", !dmgName.isEmpty else {
                throw UpdateError.untrustedURL
            }
            let dmg = work.appendingPathComponent(dmgName)
            try await download(
                from: release.dmgURL,
                to: dmg,
                expectedBytes: release.dmgBytes,
                expectedSHA256: release.sha256
            )
            status = .installing
            try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
            try attach(dmg: dmg, mount: mount)
            let sourceApp = try findApp(on: mount)
            try verifyBundle(at: sourceApp)
            try ensureDestinationWritable(installURL)
            try spawnInstaller(
                dmg: dmg,
                mount: mount,
                sourceApp: sourceApp,
                destination: installURL
            )
            NSApplication.shared.terminate(nil)
        } catch {
            _ = try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
            try? FileManager.default.removeItem(at: work)
            status = .failed(error.localizedDescription)
            alert(title: "Update failed", message: error.localizedDescription)
        }
    }

    func presentPendingInstallFailureIfNeeded() {
        if case .failed(let detail) = UpdateInstallLog.readLastRun() {
            UpdateInstallLog.acknowledgeFailure()
            alert(
                title: "The last WhisperLocal update did not finish",
                message: """
                \(detail)

                The previous app should still be in \(installURL.path). Try Check for Updates again, or install the DMG from GitHub Releases. Details: \(UpdateInstallLog.fileURL.path)
                """
            )
        }
    }

    private func download(
        from url: URL,
        to destination: URL,
        expectedBytes: Int,
        expectedSHA256: String?
    ) async throws {
        guard AppUpdateFeed.isTrustedDownloadURL(url) else {
            throw UpdateError.untrustedURL
        }
        var request = URLRequest(url: url)
        request.setValue("WhisperLocal/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 300
        let (temp, response) = try await URLSession.shared.download(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(code) else { throw UpdateError.http(code) }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temp, to: destination)
        let values = try destination.resourceValues(forKeys: [.fileSizeKey])
        let size = values.fileSize ?? 0
        if size < 1_000_000 {
            throw UpdateError.dmgTooSmall
        }
        if expectedBytes > 0, size != expectedBytes {
            throw UpdateError.dmgSizeMismatch(expected: expectedBytes, actual: size)
        }
        if let expectedSHA256, !expectedSHA256.isEmpty {
            let actual = try sha256Hex(of: destination)
            if actual != expectedSHA256.lowercased() {
                throw UpdateError.digestMismatch
            }
        }
    }

    private func sha256Hex(of url: URL) throws -> String {
        var hasher = SHA256()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while true {
            let chunk = handle.readData(ofLength: 1_048_576)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func attach(dmg: URL, mount: URL) throws {
        try run("/usr/bin/hdiutil", [
            "attach", dmg.path,
            "-nobrowse",
            "-readonly",
            "-mountpoint", mount.path
        ])
    }

    private func findApp(on mount: URL) throws -> URL {
        let direct = mount.appendingPathComponent("WhisperLocal.app")
        if FileManager.default.fileExists(atPath: direct.path) {
            return direct
        }
        let contents = try FileManager.default.contentsOfDirectory(
            at: mount,
            includingPropertiesForKeys: nil
        )
        if let app = contents.first(where: { $0.pathExtension == "app" }) {
            return app
        }
        throw UpdateError.missingAppOnDMG
    }

    private func verifyBundle(at url: URL) throws {
        guard let bundle = Bundle(url: url),
              bundle.bundleIdentifier == "com.usingcolor.WhisperLocal" else {
            throw UpdateError.wrongBundle
        }
        // Ad-hoc signing has no stable publisher identity. This only rejects a bundle
        // whose code directory no longer matches its signature (corruption or
        // post-signing tampering). It does not authenticate who produced the release.
        var staticCode: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode)
        guard status == errSecSuccess, let staticCode else {
            throw UpdateError.invalidSignature
        }
        let validity = SecStaticCodeCheckValidity(staticCode, [], nil)
        guard validity == errSecSuccess else {
            throw UpdateError.invalidSignature
        }
    }

    /// `ditto` into a sibling then rename, so a mid-copy failure does not leave a half-written app.
    /// `LSFileQuarantineEnabled` marks this process's downloads, so Gatekeeper assesses the
    /// installed app. We do not strip quarantine. Ad-hoc builds still need Open Anyway.
    private func spawnInstaller(dmg: URL, mount: URL, sourceApp: URL, destination: URL) throws {
        try FileManager.default.createDirectory(
            at: UpdateInstallLog.directory,
            withIntermediateDirectories: true
        )
        let log = UpdateInstallLog.fileURL
        let script = """
        #!/bin/bash
        set -euo pipefail
        pid="$1"
        mount="$2"
        src="$3"
        dest="$4"
        work="$5"
        log="$6"
        new="${dest}.new"
        old="${dest}.old"

        mkdir -p "$(dirname "$log")"
        exec >>"$log" 2>&1
        echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) WhisperLocal update start pid=$pid ==="

        fail() {
          trap - ERR
          echo "UPDATE_FAILED ${1:-}"
          /usr/bin/hdiutil detach "$mount" -quiet || true
          if [[ ! -e "$dest" && -d "$old" ]]; then
            /bin/mv "$old" "$dest" || true
          else
            /bin/rm -rf "$old" || true
          fi
          /usr/bin/open "$dest" || true
          /bin/rm -rf "$work" "$new" || true
          exit 1
        }
        trap 'fail "status=$?"' ERR

        while /bin/kill -0 "$pid" 2>/dev/null; do
          sleep 0.2
        done
        sleep 0.4

        /bin/rm -rf "$new" "$old"
        /usr/bin/ditto "$src" "$new"
        if [[ -d "$dest" ]]; then
          /bin/mv "$dest" "$old"
          if ! /bin/mv "$new" "$dest"; then
            /bin/mv "$old" "$dest" || true
            fail "rollback"
          fi
          /bin/rm -rf "$old"
        else
          /bin/mv "$new" "$dest"
        fi
        /usr/bin/hdiutil detach "$mount" -quiet || true
        /usr/bin/open "$dest"
        /bin/rm -rf "$work"
        echo "UPDATE_OK"
        trap - ERR
        """
        let scriptURL = dmg.deletingLastPathComponent().appendingPathComponent("install.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            scriptURL.path,
            String(ProcessInfo.processInfo.processIdentifier),
            mount.path,
            sourceApp.path,
            destination.path,
            dmg.deletingLastPathComponent().path,
            log.path
        ]
        try process.run()
    }

    private func ensureDestinationWritable(_ dest: URL) throws {
        let parent = dest.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw UpdateError.destinationNotWritable
        }
        if FileManager.default.fileExists(atPath: dest.path),
           !FileManager.default.isWritableFile(atPath: dest.path) {
            throw UpdateError.destinationNotWritable
        }
    }

    @discardableResult
    private func run(_ launchPath: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw UpdateError.commandFailed(launchPath, err)
        }
        return String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    private func alert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.runModal()
    }

    enum UpdateError: LocalizedError {
        case http(Int)
        case untrustedURL
        case dmgTooSmall
        case missingAppOnDMG
        case wrongBundle
        case destinationNotWritable
        case dmgSizeMismatch(expected: Int, actual: Int)
        case digestMismatch
        case invalidSignature
        case commandFailed(String, String)

        var errorDescription: String? {
            switch self {
            case .http(let code):
                return "GitHub returned HTTP \(code)."
            case .untrustedURL:
                return "The download URL was not a GitHub release asset."
            case .dmgTooSmall:
                return "The downloaded file was too small to be a WhisperLocal DMG."
            case .dmgSizeMismatch(let expected, let actual):
                return "The downloaded DMG was \(actual) bytes; GitHub listed \(expected)."
            case .digestMismatch:
                return "The downloaded DMG did not match the published SHA-256 checksum."
            case .missingAppOnDMG:
                return "The disk image did not contain WhisperLocal.app."
            case .wrongBundle:
                return "The disk image app is not com.usingcolor.WhisperLocal."
            case .invalidSignature:
                return "The update’s code signature is invalid or the bundle was modified after signing."
            case .destinationNotWritable:
                return "Cannot write /Applications/WhisperLocal.app. Check that the app lives in Applications and is not locked."
            case .commandFailed(let command, let err):
                let detail = err.trimmingCharacters(in: .whitespacesAndNewlines)
                if detail.isEmpty { return "\(command) failed." }
                return "\(command) failed: \(detail)"
            }
        }
    }
}
