import XCTest

/// Which apps must not be trusted to accept an accessibility write. Getting this
/// wrong is silent: the write reports success, the field stays empty, and the
/// dictation is gone.
final class TextInsertionRoutingTests: XCTestCase {
    private func clipboardFirst(_ bundleID: String?, _ name: String?) -> Bool {
        TextInserter.prefersClipboardPaste(bundleID: bundleID, appName: name)
    }

    /// /Applications/ChatGPT.app became com.openai.codex, which dropped it off the
    /// bundle list and sent dictation down the accessibility path, where it was
    /// discarded. Both OpenAI bundles have to route to the clipboard.
    func testBothChatGPTBundlesUseTheClipboard() {
        XCTAssertTrue(clipboardFirst("com.openai.codex", "ChatGPT"))
        XCTAssertTrue(clipboardFirst("com.openai.chat", "ChatGPT Classic"))
    }

    /// The name is the backstop for exactly the rename above: a vendor can change
    /// the bundle ID, but the app in the Dock keeps its name.
    func testAnUnknownBundleStillRoutesOnTheAppName() {
        XCTAssertTrue(clipboardFirst("com.openai.something-new", "ChatGPT"))
        XCTAssertTrue(clipboardFirst("com.example.unknown", "Slack"))
        XCTAssertTrue(clipboardFirst(nil, "Cursor"))
    }

    func testKnownWebViewAppsAreUnchanged() {
        for id in ["com.tinyspeck.slackmacgap", "com.hnc.Discord", "com.google.Chrome",
                   "com.anthropic.claudefordesktop", "com.anysphere.sand"] {
            XCTAssertTrue(clipboardFirst(id, nil), "\(id) should paste via the clipboard")
        }
    }

    /// Native AppKit fields take an accessibility write correctly, and that path is
    /// faster and leaves the clipboard alone. Do not drag them onto the slow path.
    func testNativeAppsKeepTheAccessibilityPath() {
        XCTAssertFalse(clipboardFirst("com.apple.Notes", "Notes"))
        XCTAssertFalse(clipboardFirst("com.apple.mail", "Mail"))
        XCTAssertFalse(clipboardFirst("com.apple.TextEdit", "TextEdit"))
    }

    /// The hints are substrings, so they have to be specific enough not to catch
    /// unrelated apps. "Notion" must not pull in "Notes".
    func testNameHintsDoNotOverreach() {
        XCTAssertFalse(clipboardFirst("com.apple.Notes", "Notes"))
        XCTAssertFalse(clipboardFirst("com.apple.dt.Xcode", "Xcode"))
    }
}

/// The app kind fed to the polish prompt, which is a separate lookup from the
/// insertion route and was not affected by the rename — the name still matches.
final class TargetAppKindTests: XCTestCase {
    func testBothChatGPTBundlesReadAsChatApps() {
        XCTAssertEqual(TargetAppContext.kind(bundleID: "com.openai.codex", name: "ChatGPT"), .chat)
        XCTAssertEqual(TargetAppContext.kind(bundleID: "com.openai.chat", name: "ChatGPT Classic"), .chat)
    }
}
