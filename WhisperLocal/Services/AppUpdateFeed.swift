import Foundation

/// Public OSS releases: https://github.com/usingcolor/WhisperLocal/releases
enum AppUpdateFeed {
    static let owner = "usingcolor"
    static let repo = "WhisperLocal"
    static let latestReleaseURL = URL(
        string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest"
    )!

    struct Release: Equatable, Sendable {
        var version: String
        var tag: String
        var pageURL: URL
        var dmgURL: URL
        var dmgName: String
        var dmgBytes: Int
    }

    struct SemanticVersion: Comparable, Equatable {
        var major: Int
        var minor: Int
        var patch: Int

        static func parse(_ raw: String) -> SemanticVersion? {
            var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.lowercased().hasPrefix("v") {
                text.removeFirst()
            }
            let numeric = text.split(separator: "-").first.map(String.init) ?? text
            let parts = numeric.split(separator: ".").prefix(3).compactMap { Int($0) }
            guard let major = parts.first else { return nil }
            return SemanticVersion(
                major: major,
                minor: parts.count > 1 ? parts[1] : 0,
                patch: parts.count > 2 ? parts[2] : 0
            )
        }

        static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
            if lhs.major != rhs.major { return lhs.major < rhs.major }
            if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
            return lhs.patch < rhs.patch
        }
    }

    static func isNewer(latest: String, current: String) -> Bool {
        guard let latestVersion = SemanticVersion.parse(latest),
              let currentVersion = SemanticVersion.parse(current) else {
            return false
        }
        return latestVersion > currentVersion
    }

    static func parseRelease(from data: Data) throws -> Release {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let json else { throw FeedError.invalidJSON }
        let tag = (json["tag_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let version = SemanticVersion.parse(tag).map({ "\($0.major).\($0.minor).\($0.patch)" }) else {
            throw FeedError.missingTag
        }
        let page = (json["html_url"] as? String).flatMap(URL.init(string:))
            ?? URL(string: "https://github.com/\(owner)/\(repo)/releases")!
        let assets = json["assets"] as? [[String: Any]] ?? []
        guard let asset = pickDMG(from: assets) else {
            throw FeedError.missingDMG
        }
        return Release(
            version: version,
            tag: tag,
            pageURL: page,
            dmgURL: asset.url,
            dmgName: asset.name,
            dmgBytes: asset.size
        )
    }

    static func pickDMG(from assets: [[String: Any]]) -> (name: String, url: URL, size: Int)? {
        let dmgs = assets.compactMap { asset -> (name: String, url: URL, size: Int)? in
            let name = asset["name"] as? String ?? ""
            guard name.lowercased().hasSuffix(".dmg") else { return nil }
            guard name.lowercased().hasPrefix("whisperlocal") else { return nil }
            guard let urlString = asset["browser_download_url"] as? String,
                  let url = URL(string: urlString),
                  isTrustedDownloadURL(url) else { return nil }
            let size = asset["size"] as? Int ?? 0
            return (name, url, size)
        }
        if let arm = dmgs.first(where: { $0.name.lowercased().contains("arm64") }) {
            return arm
        }
        return dmgs.first
    }

    static func isTrustedDownloadURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https" else { return false }
        guard let host = url.host?.lowercased() else { return false }
        let allowedHosts: Set<String> = [
            "github.com",
            "objects.githubusercontent.com",
            "github-releases.githubusercontent.com",
            "release-assets.githubusercontent.com"
        ]
        guard allowedHosts.contains(host) else { return false }
        let path = url.path.lowercased()
        if host == "github.com" {
            return path.contains("/\(owner.lowercased())/\(repo.lowercased())/")
        }
        return true
    }

    enum FeedError: LocalizedError {
        case invalidJSON
        case missingTag
        case missingDMG

        var errorDescription: String? {
            switch self {
            case .invalidJSON:
                return "The GitHub release listing was not valid JSON."
            case .missingTag:
                return "The GitHub release has no version tag."
            case .missingDMG:
                return "That GitHub release has no WhisperLocal DMG."
            }
        }
    }
}
