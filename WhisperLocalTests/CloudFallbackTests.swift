import XCTest

/// Records what it was asked to do and fails on demand, so the pipeline's
/// cloud → on-device → raw ladder can be exercised without a network.
private final class StubPolisher: TextPolisher, @unchecked Sendable {
    let name: String
    private let error: Error?
    private let transform: (String) -> String
    private(set) var calls = 0

    init(name: String, failWith error: Error? = nil, transform: @escaping (String) -> String = { "polished(\($0))" }) {
        self.name = name
        self.error = error
        self.transform = transform
    }

    func polish(
        _ text: String,
        dictionary: [String],
        personalContext: String,
        targetApp: String?,
        recentDictations: String,
        sessionIntent: String,
        task: PolishTask
    ) async throws -> PolishedText {
        calls += 1
        if let error { throw error }
        return PolishedText(text: transform(text))
    }
}

final class PolishFailureKindTests: XCTestCase {
    func testOfflineIsItsOwnKind() {
        XCTAssertEqual(PolishFailureKind(URLError(.notConnectedToInternet)), .offline)
    }

    func testOtherTransportErrorsAreProviderLevel() {
        XCTAssertEqual(PolishFailureKind(URLError(.timedOut)), .providerUnavailable)
        XCTAssertEqual(PolishFailureKind(URLError(.cannotFindHost)), .providerUnavailable)
    }

    func testServerAndKeyProblemsStopFurtherAttempts() {
        for code in [500, 502, 503, 429, 401, 403] {
            let kind = PolishFailureKind(PolisherError.http(code, ""))
            XCTAssertEqual(kind, .providerUnavailable, "HTTP \(code) should be provider-level")
            XCTAssertTrue(kind.stopsFurtherCloudAttempts)
        }
        XCTAssertEqual(PolishFailureKind(PolisherError.missingAPIKey("OpenAI")), .providerUnavailable)
    }

    func testPerRequestFailuresDoNotStopTheRest() {
        // A truncated or malformed piece says nothing about the provider's health.
        for error in [PolisherError.truncated, .emptyResponse, .http(400, "")] {
            let kind = PolishFailureKind(error)
            XCTAssertEqual(kind, .requestFailed)
            XCTAssertFalse(kind.stopsFurtherCloudAttempts)
        }
    }

    func testNotesNameTheActualCause() {
        XCTAssertTrue(PolishFailureKind.offline.fallbackNote.contains("Offline"))
        XCTAssertTrue(PolishFailureKind.offline.rawNote.contains("Offline"))
        XCTAssertNotEqual(PolishFailureKind.offline.rawNote, PolishFailureKind.requestFailed.rawNote)
    }
}

final class PolishFallbackTests: XCTestCase {
    private func pipeline(
        cloud: StubPolisher?,
        local: StubPolisher?,
        localIsReady: Bool,
        online: Bool = true
    ) -> PolishPipeline {
        PolishPipeline(
            localLLM: local,
            cloud: cloud,
            // Mirrors SettingsStore.shouldRunOnDevicePolish, which is false whenever
            // cloud polish is selected. Passing true here let the fallback tests
            // pass through the primary path and hid a real bug.
            useLocalLLM: cloud == nil && local != nil,
            localIsReady: localIsReady,
            isOnline: { online },
            enableTextCleanup: true,
            dictionary: []
        )
    }

    func testCloudSuccessDoesNotTouchTheLocalModel() async {
        let cloud = StubPolisher(name: "Cloud")
        let local = StubPolisher(name: "Local")
        let result = await pipeline(cloud: cloud, local: local, localIsReady: true).run("hello")
        XCTAssertEqual(result.text, "polished(hello)")
        XCTAssertEqual(local.calls, 0, "local must not run when cloud succeeded")
        XCTAssertFalse(result.cleanupFailed)
        XCTAssertFalse(result.cloudUnavailable)
    }

    func testCloudFailureFallsBackToTheLocalModel() async {
        let cloud = StubPolisher(name: "Cloud", failWith: URLError(.timedOut))
        let local = StubPolisher(name: "Local", transform: { "local(\($0))" })
        let result = await pipeline(cloud: cloud, local: local, localIsReady: true).run("hello")
        XCTAssertEqual(result.text, "local(hello)")
        XCTAssertEqual(local.calls, 1)
        XCTAssertFalse(result.cleanupFailed, "the text was cleaned, just not by the cloud")
        XCTAssertEqual(result.cleanupNote, "Cloud failed — polished on this Mac")
        XCTAssertTrue(result.cloudUnavailable)
    }

    func testOfflineSkipsTheCloudEntirely() async {
        let cloud = StubPolisher(name: "Cloud")
        let local = StubPolisher(name: "Local", transform: { "local(\($0))" })
        let result = await pipeline(cloud: cloud, local: local, localIsReady: true, online: false).run("hello")
        XCTAssertEqual(cloud.calls, 0, "offline must not pay the request timeout")
        XCTAssertEqual(result.text, "local(hello)")
        XCTAssertEqual(result.cleanupNote, "Offline — polished on this Mac")
    }

    func testUnreadyLocalModelIsNotColdStarted() async {
        // Gemma is unloaded whenever cloud is selected; a 2.7 GB cold start
        // mid-dictation is worse than pasting uncleaned.
        let cloud = StubPolisher(name: "Cloud", failWith: URLError(.timedOut))
        let local = StubPolisher(name: "Local")
        let result = await pipeline(cloud: cloud, local: local, localIsReady: false).run("hello")
        XCTAssertEqual(local.calls, 0, "must not wake an unloaded local model")
        XCTAssertEqual(result.text, "hello", "raw text is still pasted")
        XCTAssertTrue(result.cleanupFailed)
        XCTAssertEqual(result.cleanupNote, "Cloud unavailable — pasted without cleanup")
    }

    func testBothFailingStillPastesTheTranscript() async {
        let cloud = StubPolisher(name: "Cloud", failWith: URLError(.timedOut))
        let local = StubPolisher(name: "Local", failWith: PolisherError.notAvailable("nope"))
        let result = await pipeline(cloud: cloud, local: local, localIsReady: true).run("hello there")
        XCTAssertEqual(result.text, "hello there", "never blank")
        XCTAssertTrue(result.cleanupFailed)
    }

    func testNoCloudConfiguredStillUsesTheLocalModel() async {
        let local = StubPolisher(name: "Local", transform: { "local(\($0))" })
        let result = await pipeline(cloud: nil, local: local, localIsReady: false).run("hello")
        XCTAssertEqual(result.text, "local(hello)", "primary local path must not need localIsReady")
        XCTAssertEqual(local.calls, 1)
    }

    func testCircuitBreakerStopsRetryingADeadProvider() async {
        let cloud = StubPolisher(name: "Cloud", failWith: URLError(.timedOut))
        let local = StubPolisher(name: "Local", transform: { "local(\($0))" })
        // Long enough to split into several pieces.
        let long = String(repeating: "alpha beta gamma delta epsilon. ", count: 400)
        let result = await pipeline(cloud: cloud, local: local, localIsReady: true).runChunked(long)

        let pieces = PolishChunker.split(long).count
        XCTAssertGreaterThan(pieces, 1, "test needs a multi-piece transcript")
        XCTAssertEqual(cloud.calls, 1, "cloud must be tried once, not once per piece")
        XCTAssertEqual(local.calls, pieces, "every piece still gets cleaned locally")
        XCTAssertFalse(result.text.isEmpty)
        XCTAssertTrue(result.cloudUnavailable)
    }

    func testPerRequestFailureDoesNotTripTheBreaker() async {
        // A truncated piece is not evidence the provider is down.
        let cloud = StubPolisher(name: "Cloud", failWith: PolisherError.truncated)
        let local = StubPolisher(name: "Local", transform: { "local(\($0))" })
        let long = String(repeating: "alpha beta gamma delta epsilon. ", count: 400)
        _ = await pipeline(cloud: cloud, local: local, localIsReady: true).runChunked(long)

        let pieces = PolishChunker.split(long).count
        XCTAssertEqual(cloud.calls, pieces, "each piece should still get its own cloud attempt")
    }
}
