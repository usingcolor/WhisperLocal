import XCTest

final class DictationLogExportTests: XCTestCase {
    private let entry = DictationLogEntry(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        date: Date(timeIntervalSince1970: 1_720_000_000),
        raw: "um hello, \"world\"",
        polished: "Hello, world.",
        stages: ["Fillers", "Apple Intelligence"],
        cleanupNote: "Pasted without AI cleanup",
        appName: "Notes",
        insertMethod: "clipboard",
        outcome: .success,
        errorMessage: nil,
        audioSeconds: 1.5
    )

    func testCSVEscapesCommasAndQuotes() {
        let csv = DictationLogExport.csv(entries: [entry])
        XCTAssertTrue(csv.hasPrefix("date,outcome,app,insert,audio_seconds,language,microphone,stages,cleanup_note,error,raw,polished\n"))
        XCTAssertTrue(csv.contains("success"))
        XCTAssertTrue(csv.contains("Notes"))
        XCTAssertTrue(csv.contains("\"um hello, \"\"world\"\"\""))
        XCTAssertTrue(csv.contains("1.5"))
    }

    /// A column added to the header and not to the rows shifts every field after
    /// it, quietly, in a file people open in a spreadsheet.
    func testEveryRowHasAsManyFieldsAsTheHeader() {
        let csv = DictationLogExport.csv(entries: [entry])
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 2)
        let columns = { (line: Substring) -> Int in
            var count = 1
            var inQuotes = false
            for character in line {
                if character == "\"" { inQuotes.toggle() }
                if character == ",", !inQuotes { count += 1 }
            }
            return count
        }
        XCTAssertEqual(columns(lines[0]), columns(lines[1]))
    }

    func testTheLanguageAndMicrophoneAreExported() {
        var tagged = entry
        tagged.language = "Korean"
        tagged.microphone = "MacBook Air Microphone → AirPods Pro"
        XCTAssertTrue(DictationLogExport.csv(entries: [tagged]).contains("Korean"))
        let text = DictationLogExport.plainText(for: tagged)
        XCTAssertTrue(text.contains("Language: Korean"))
        XCTAssertTrue(text.contains("Microphone: MacBook Air Microphone → AirPods Pro"))
    }

    /// The store returns an empty array on any decoding failure, so a required
    /// field here would erase every take the user had already recorded the first
    /// time they ran the new version. Entries written before these existed must
    /// still load.
    func testAnEntryWrittenBeforeTheseFieldsStillDecodes() throws {
        let old = """
        [{
          "id": "00000000-0000-0000-0000-000000000002",
          "date": 760000000,
          "raw": "hello",
          "polished": "Hello.",
          "stages": ["Fillers"],
          "outcome": "success"
        }]
        """
        let entries = try JSONDecoder().decode([DictationLogEntry].self, from: Data(old.utf8))
        XCTAssertEqual(entries.count, 1)
        XCTAssertNil(entries[0].language)
        XCTAssertNil(entries[0].microphone)
        XCTAssertEqual(entries[0].raw, "hello")
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
        XCTAssertTrue(text.contains("Fillers → Apple Intelligence"))
    }

    func testEmptyPlainText() {
        XCTAssertEqual(DictationLogExport.plainText(entries: []), "")
    }

    func testCSVNeutralizesFormulaInjection() {
        XCTAssertEqual(DictationLogExport.escapeCSV("=CMD()"), "'=CMD()")
        XCTAssertEqual(DictationLogExport.escapeCSV("+1+1"), "'+1+1")
        XCTAssertEqual(DictationLogExport.escapeCSV("-SUM(A1)"), "'-SUM(A1)")
        XCTAssertEqual(DictationLogExport.escapeCSV("@SUM(A1)"), "'@SUM(A1)")
        XCTAssertEqual(DictationLogExport.escapeCSV("hello"), "hello")

        let formula = DictationLogEntry(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            date: Date(timeIntervalSince1970: 1_720_000_000),
            raw: "=HYPERLINK(\"http://evil.example\")",
            polished: "+cmd|'/C calc'",
            stages: [],
            cleanupNote: "@SUM(A1)",
            appName: "-Notes",
            insertMethod: "clipboard",
            outcome: .success,
            errorMessage: nil,
            audioSeconds: 1.5
        )
        let csv = DictationLogExport.csv(entries: [formula])
        XCTAssertTrue(csv.contains("'=HYPERLINK("))
        XCTAssertTrue(csv.contains("'+cmd|'/C calc'"))
        XCTAssertTrue(csv.contains("'@SUM(A1)"))
        XCTAssertTrue(csv.contains("'-Notes"))
        XCTAssertFalse(csv.contains("\n=HYPERLINK"))
    }
}

final class TextInserterSanitizeTests: XCTestCase {
    func testKeepsTrailingSpace() {
        XCTAssertEqual(TextInserter.sanitizeForPaste("Hello world. "), "Hello world. ")
    }

    func testDropsBellButKeepsText() {
        XCTAssertEqual(TextInserter.sanitizeForPaste("Hello\u{0007} world."), "Hello world.")
    }

    func testUnverifiedInsertMethodIsDistinctFromConfirmedAccessibility() {
        XCTAssertEqual(InsertionMethod.accessibility.rawValue, "accessibility")
        XCTAssertEqual(InsertionMethod.accessibilityUnverified.rawValue, "accessibility-unverified")
        XCTAssertEqual(InsertionMethod.clipboard.rawValue, "clipboard")
        XCTAssertEqual(InsertionMethod.clipboardUnverified.rawValue, "clipboard-unverified")
        XCTAssertNotEqual(InsertionMethod.clipboard.rawValue, InsertionMethod.clipboardUnverified.rawValue)
    }
}
