import XCTest

final class DictationLogExportTests: XCTestCase {
    private let entry = DictationLogEntry(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        date: Date(timeIntervalSince1970: 1_720_000_000),
        raw: "um hello, \"world\"",
        polished: "Hello, world.",
        stages: ["Heuristic", "Apple Intelligence"],
        cleanupNote: "Pasted without AI cleanup",
        appName: "Notes",
        insertMethod: "clipboard",
        outcome: .success,
        errorMessage: nil,
        audioSeconds: 1.5
    )

    func testCSVEscapesCommasAndQuotes() {
        let csv = DictationLogExport.csv(entries: [entry])
        XCTAssertTrue(csv.hasPrefix("date,outcome,app,insert,audio_seconds,stages,cleanup_note,error,raw,polished\n"))
        XCTAssertTrue(csv.contains("success"))
        XCTAssertTrue(csv.contains("Notes"))
        XCTAssertTrue(csv.contains("\"um hello, \"\"world\"\"\""))
        XCTAssertTrue(csv.contains("1.5"))
    }

    func testJSONRoundTrip() throws {
        let data = try DictationLogExport.jsonData(entries: [entry])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([DictationLogEntry].self, from: data)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].raw, entry.raw)
        XCTAssertEqual(decoded[0].polished, entry.polished)
        XCTAssertEqual(decoded[0].outcome, .success)
        XCTAssertEqual(decoded[0].appName, "Notes")
    }

    func testPlainTextIncludesRawAndPolished() {
        let text = DictationLogExport.plainText(entries: [entry])
        XCTAssertTrue(text.contains("Inserted"))
        XCTAssertTrue(text.contains("App: Notes"))
        XCTAssertTrue(text.contains("Raw:"))
        XCTAssertTrue(text.contains("um hello, \"world\""))
        XCTAssertTrue(text.contains("Polished:"))
        XCTAssertTrue(text.contains("Hello, world."))
        XCTAssertTrue(text.contains("Heuristic → Apple Intelligence"))
    }

    func testEmptyPlainText() {
        XCTAssertEqual(DictationLogExport.plainText(entries: []), "")
    }
}
