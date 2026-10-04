import XCTest

/// The DMG's digest used to arrive as a `SHA256SUMS` asset. Releases stopped
/// carrying that file — the DMG is the only asset now, so the downloads badge
/// counts downloads rather than checksum fetches — and the digest is printed in
/// the release notes instead. The updater has to find it there or it silently
/// stops checking what it downloaded.
final class AppUpdateFeedNotesTests: XCTestCase {
    private let dmg = "WhisperLocal-0.2.3-arm64.dmg"
    private let digest = "56fced70930854cd9c2eaa5141989828be7dd291d3b4cd3efa85e5d550d8fd9f"

    func testReadsTheDigestTheWorkflowPrints() {
        let notes = """
        ## 0.2.3

        - Something changed.

        ---

        SHA-256 of `\(dmg)`:

            \(digest)
        """
        XCTAssertEqual(AppUpdateFeed.parseSHA256(fromNotes: notes, for: dmg), digest)
    }

    func testUppercaseIsNormalised() {
        let notes = "SHA-256 of `\(dmg)`:\n\n    \(digest.uppercased())\n"
        XCTAssertEqual(AppUpdateFeed.parseSHA256(fromNotes: notes, for: dmg), digest)
    }

    /// Notes with no digest at all — every release before this change. Nil, not a
    /// wrong answer: the signature and publisher checks still gate the install.
    func testNotesWithoutADigest() {
        XCTAssertNil(AppUpdateFeed.parseSHA256(fromNotes: "## 0.1.0\n\n- First release.", for: dmg))
        XCTAssertNil(AppUpdateFeed.parseSHA256(fromNotes: nil, for: dmg))
        XCTAssertNil(AppUpdateFeed.parseSHA256(fromNotes: "", for: dmg))
    }

    /// The digest after *this* DMG's name, not whichever came first — otherwise a
    /// release listing two files would verify the download against the wrong one.
    func testTheDigestIsMatchedToTheRightFile() {
        let other = "0000000000000000000000000000000000000000000000000000000000000000"
        let notes = """
        SHA-256 of `WhisperLocal-0.2.3-x86_64.dmg`:

            \(other)

        SHA-256 of `\(dmg)`:

            \(digest)
        """
        XCTAssertEqual(AppUpdateFeed.parseSHA256(fromNotes: notes, for: dmg), digest)
    }

    /// Two digests and neither named: refuse rather than guess.
    func testAmbiguousNotesAreRefused() {
        let a = "1111111111111111111111111111111111111111111111111111111111111111"
        let b = "2222222222222222222222222222222222222222222222222222222222222222"
        XCTAssertNil(AppUpdateFeed.parseSHA256(fromNotes: "\(a)\n\(b)", for: dmg))
        XCTAssertEqual(AppUpdateFeed.parseSHA256(fromNotes: a, for: dmg), a)
    }

    /// A 63- or 65-character run is not a digest.
    func testNearMissesAreNotDigests() {
        XCTAssertNil(AppUpdateFeed.parseSHA256(fromNotes: String(repeating: "a", count: 63), for: dmg))
        XCTAssertNil(AppUpdateFeed.parseSHA256(fromNotes: String(repeating: "a", count: 65), for: dmg))
    }
}
