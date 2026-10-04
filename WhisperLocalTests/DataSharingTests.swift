import XCTest

final class DataSharingTests: XCTestCase {
    func testVolunteerSharingIsOnlyAvailableInTheExactDevBundle() {
        XCTAssertFalse(DataSharing.isEnabled(bundleID: AppIdentity.publicBundleID))
        XCTAssertFalse(DataSharing.isEnabled(bundleID: "com.usingcolor.WhisperLocalTests"))
        XCTAssertFalse(DataSharing.isEnabled(bundleID: AppIdentity.publicBundleID + ".dev.preview"))
        XCTAssertTrue(DataSharing.isEnabled(bundleID: AppIdentity.devBundleID))
        XCTAssertTrue(AutoContext.isEnabled, "automatic context ships independently of sharing in 0.2.5")
    }

    func testStricterPrivacyInvalidatesAlreadyPreparedTakes() {
        let previous = DataSharingPrivacyPolicy(hideNames: false, excludedApps: ["1Password"])
        XCTAssertFalse(DataSharingPrivacyPolicy(hideNames: true, excludedApps: ["1Password"]).permits(previous))
        XCTAssertFalse(DataSharingPrivacyPolicy(hideNames: false, excludedApps: ["1Password", "Mail"]).permits(previous))
        XCTAssertFalse(previous.permits(nil), "legacy queues have no proof of which policy prepared them")
    }

    func testEquivalentOrLooserPrivacyRetainsAlreadyRedactedTakes() {
        let previous = DataSharingPrivacyPolicy(hideNames: true, excludedApps: [" Mail ", "1Password", "mail"])
        XCTAssertTrue(DataSharingPrivacyPolicy(hideNames: true, excludedApps: ["MAIL", "1password"]).permits(previous))
        XCTAssertTrue(DataSharingPrivacyPolicy(hideNames: false, excludedApps: ["Mail"]).permits(previous))
    }

    private func entry(
        raw: String,
        polished: String,
        app: String? = "Slack",
        outcome: DictationLogEntry.Outcome = .success,
        topics: [String]? = nil
    ) -> DictationLogEntry {
        DictationLogEntry(
            id: UUID(),
            date: Date(timeIntervalSinceReferenceDate: 800_000_000),
            raw: raw,
            polished: polished,
            stages: ["Fillers", "OpenAI", "insert:clipboard→\(app ?? "")"],
            cleanupNote: nil,
            appName: app,
            insertMethod: "clipboard",
            outcome: outcome,
            errorMessage: nil,
            audioSeconds: 3.14159,
            language: "en",
            microphone: "Test User's AirPods Pro",
            windowTitle: "Re: salary review — Mail",
            autoContext: topics,
            speechModel: "large-v3-v20240930_turbo",
            polishModel: "gpt-6-luna"
        )
    }

    private func share(_ entry: DictationLogEntry, hideNames: Bool = true, excluded: [String] = []) -> SharedTake? {
        SharedTake.make(from: entry, hideNames: hideNames, excludedApps: excluded, appVersion: "0.2.4 (22)")
    }

    // MARK: - What leaves the Mac

    func testASharedTakeLeavesOutWhatPolishQualityDoesNotNeed() throws {
        let take = try XCTUnwrap(share(entry(raw: "um send the notes", polished: "Send the notes.")))
        let json = String(decoding: try DataSharingClient.encoder.encode(take), as: UTF8.self)
        XCTAssertFalse(json.contains("Slack"), "no app name, not even in the insert step")
        XCTAssertFalse(json.contains("AirPods"), "no microphone")
        XCTAssertFalse(json.contains("salary"), "no window title")
        XCTAssertEqual(take.appKind, "chat app")
        XCTAssertEqual(take.stages, ["Fillers", "OpenAI"])
        XCTAssertNotNil(take.day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression), "the day, not the time")
        XCTAssertEqual(take.audioSeconds, 3.1)
        XCTAssertEqual(take.polishModel, "gpt-6-luna")
        XCTAssertEqual(take.polished, "Send the notes.")
    }

    func testSomeTakesAreNeverShared() {
        XCTAssertNil(share(entry(raw: "the vault code", polished: "The vault code.", app: "1Password 7"),
                           excluded: DataSharing.defaultExcludedApps), "an excluded app, matched loosely")
        XCTAssertNil(share(entry(raw: "hello", polished: "Hello.", outcome: .insertFailed)), "never inserted")
        XCTAssertNil(share(entry(raw: " ", polished: "")), "nothing said")
    }

    // MARK: - Taken out first

    private func redact(_ texts: [String], names: Bool = true) -> TakeRedactor.Result {
        TakeRedactor(hideNames: names).redact(texts)
    }

    func testContactDetailsAreTakenOut() {
        let result = redact(["Mail it to jo.kim@example.com or call +1 415-555-0132, the doc is at https://example.com/plan?id=7"])
        let text = result.texts[0]
        XCTAssertFalse(text.contains("jo.kim"), text)
        XCTAssertFalse(text.contains("555-0132"), text)
        XCTAssertFalse(text.contains("example.com/plan"), text)
        XCTAssertTrue(text.contains("[EMAIL_1]"), text)
        XCTAssertTrue(text.contains("[PHONE_1]"), text)
        XCTAssertTrue(text.contains("[URL_1]"), text)
    }

    func testNumbersThatIdentifySomeoneAreTakenOut() {
        let card = redact(["My card is 4242 4242 4242 4242, thanks."]).texts[0]
        XCTAssertEqual(card, "My card is [CARD_1], thanks.")
        let korean = redact(["주민번호는 900101-1234567 입니다"]).texts[0]
        XCTAssertEqual(korean, "주민번호는 [ID_1] 입니다")
        let key = redact(["paste sk-proj-abcdefghijklmnopqrstuvwx1234 into settings"]).texts[0]
        XCTAssertEqual(key, "paste [SECRET_1] into settings")
    }

    func testANameGetsTheSamePlaceholderEverywhereInTheTake() {
        let result = redact([
            "can we set up an interview with joaquin reyes for thursday",
            "Can we set up an interview with Joaquin Reyes for Thursday?",
            "Interview with Joaquin Reyes",
        ])
        XCTAssertEqual(result.texts[1], "Can we set up an interview with [NAME_1] for Thursday?")
        XCTAssertEqual(result.texts[0], "can we set up an interview with [NAME_1] for thursday",
                       "found in the polished text, taken out of the lowercase raw text too")
        XCTAssertEqual(result.texts[2], "Interview with [NAME_1]")
        XCTAssertEqual(result.counts["name"], 3)
    }

    func testNamesStayWhenAskedTo() {
        let result = redact(["Can we set up an interview with Joaquin Reyes for Thursday?"], names: false)
        XCTAssertEqual(result.texts[0], "Can we set up an interview with Joaquin Reyes for Thursday?")
        XCTAssertNil(result.counts["name"])
    }

    // MARK: - The server

    func testTakesOnlyCrossANetworkEncrypted() {
        XCTAssertNoThrow(try DataSharingClient.serverURL("https://data.whisperlocal.app"))
        XCTAssertNoThrow(try DataSharingClient.serverURL("http://127.0.0.1:8787"))
        XCTAssertNoThrow(try DataSharingClient.serverURL("http://localhost:8787"))
        XCTAssertThrowsError(try DataSharingClient.serverURL("http://data.whisperlocal.app"))
        XCTAssertThrowsError(try DataSharingClient.serverURL("ftp://127.0.0.1"))
        XCTAssertThrowsError(try DataSharingClient.serverURL("not a server"))
    }

    /// Against scripts/data-sharing-server.py, only when its address is given:
    /// TEST_RUNNER_WL_DATA_SHARING_SERVER=http://127.0.0.1:8787 xcodebuild test …
    func testARoundTripAgainstTheLocalServer() async throws {
        guard let address = ProcessInfo.processInfo.environment["WL_DATA_SHARING_SERVER"] else {
            throw XCTSkip("no local server given")
        }
        let base = try DataSharingClient.serverURL(address)
        var consent = DataSharingConsent(version: DataSharing.consentVersion, scopes: [.improve], acceptedAt: Date())
        let enrollment = try await DataSharingClient(baseURL: base).enroll(consent: consent, appVersion: "test")
        let client = DataSharingClient(baseURL: base, token: enrollment.token)

        let takes = try [
            XCTUnwrap(share(entry(raw: "um send it to joaquin reyes", polished: "Send it to Joaquin Reyes."))),
            XCTUnwrap(share(entry(raw: "call 415 555 0132", polished: "Call 415-555-0132."))),
        ]
        let first = try await client.submit(takes, consent: consent)
        XCTAssertEqual(Set(first.accepted), Set(takes.map(\.id)))
        let again = try await client.submit(takes, consent: consent)
        XCTAssertEqual(Set(again.duplicates), Set(takes.map(\.id)), "the same take is never stored twice")

        consent.scopes = [.improve, .train]
        try await client.updateConsent(consent)
        let exported = try JSONSerialization.jsonObject(with: try await client.export()) as? [String: Any]
        XCTAssertEqual((exported?["takes"] as? [Any])?.count, 2)
        XCTAssertEqual((exported?["consents"] as? [Any])?.count, 2)

        do {
            _ = try await client.submit(takes, consent: DataSharingConsent(version: "old", scopes: [.improve], acceptedAt: Date()))
            XCTFail("a take sent under a consent the server does not hold must be refused")
        } catch DataSharingError.rejected(let status, _) {
            XCTAssertEqual(status, 409)
        }

        consent.scopes = []
        try await client.updateConsent(consent)
        do {
            _ = try await client.submit(takes, consent: consent)
            XCTFail("withdrawn consent must refuse uploads")
        } catch DataSharingError.rejected(let status, _) {
            XCTAssertEqual(status, 403)
        }
        let stoppedExport = try JSONSerialization.jsonObject(with: try await client.export()) as? [String: Any]
        XCTAssertEqual((stoppedExport?["takes"] as? [Any])?.count, 2, "stopping still allows download and deletion")

        let deleted = try await client.deleteEverything()
        XCTAssertEqual(deleted, 2)
        do {
            _ = try await client.export()
            XCTFail("the token must stop working once everything is deleted")
        } catch DataSharingError.rejected(let status, _) {
            XCTAssertEqual(status, 401)
        }
    }
}
