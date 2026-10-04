import XCTest

@MainActor
final class DictationLogRecoveryTests: XCTestCase {
    private func entry(_ raw: String) -> DictationLogEntry {
        DictationLogEntry(
            id: UUID(), date: Date(), raw: raw, polished: raw,
            stages: [], cleanupNote: nil, appName: nil, insertMethod: nil,
            outcome: .success, errorMessage: nil, audioSeconds: nil
        )
    }

    func testPartiallyInvalidHistoryPreservesOriginalAndRecoversValidTakes() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("dictation-log.json")
        let original = entry("keep this take")
        let valid = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original))
        let data = try JSONSerialization.data(withJSONObject: [valid, ["raw": "invalid entry"]])
        try data.write(to: url)
        let suite = "DictationLogRecoveryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DictationLogStore(fileURL: url, defaults: defaults)

        XCTAssertEqual(store.entries, [original])
        XCTAssertNotNil(store.recoveryMessage)
        let backup = try XCTUnwrap(store.preservedHistoryURL)
        XCTAssertEqual(try Data(contentsOf: backup), data)
        let permissions = try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        store.flushPendingWrites()
        XCTAssertEqual(DictationLogStore(fileURL: url, defaults: defaults).entries, [original],
                       "recovered takes must survive quitting before the next dictation")

        let added = entry("new take")
        store.append(added)
        store.flushPendingWrites()
        XCTAssertEqual(try JSONDecoder().decode([DictationLogEntry].self, from: Data(contentsOf: url)), [added, original])
        XCTAssertEqual(try Data(contentsOf: backup), data, "saving new takes must never overwrite the preserved history")
    }

    func testUnreadableJSONIsPreservedBeforeStartingANewHistory() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("dictation-log.json")
        let data = Data("[{interrupted write".utf8)
        try data.write(to: url)
        let suite = "DictationLogRecoveryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DictationLogStore(fileURL: url, defaults: defaults)

        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(store.preservedHistoryURL)), data)
        store.append(entry("after recovery"))
        store.flushPendingWrites()
        XCTAssertEqual(try JSONDecoder().decode([DictationLogEntry].self, from: Data(contentsOf: url)).count, 1)
    }
}
