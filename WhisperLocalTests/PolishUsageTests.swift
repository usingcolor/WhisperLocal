import XCTest

/// The benchmark prices models from these numbers, so both providers must end up
/// meaning the same thing by "input" and "output".
final class PolishUsageTests: XCTestCase {
    func testOpenAICountsCachedAndReasoningInsideTheTotals() throws {
        let json = try decode("""
        {"usage": {
          "prompt_tokens": 1200, "completion_tokens": 340,
          "prompt_tokens_details": {"cached_tokens": 1024},
          "completion_tokens_details": {"reasoning_tokens": 300}
        }}
        """)
        let usage = try XCTUnwrap(PolishUsage.openAI(json["usage"] as? [String: Any]))
        XCTAssertEqual(usage, PolishUsage(
            inputTokens: 1200,
            outputTokens: 340,
            cachedInputTokens: 1024,
            reasoningTokens: 300
        ))
    }

    func testOpenAIWithoutDetailsStillCounts() throws {
        let json = try decode(#"{"usage": {"prompt_tokens": 90, "completion_tokens": 12}}"#)
        let usage = try XCTUnwrap(PolishUsage.openAI(json["usage"] as? [String: Any]))
        XCTAssertEqual(usage, PolishUsage(inputTokens: 90, outputTokens: 12))
    }

    func testAnthropicFoldsCacheReadsAndWritesIntoTheInput() throws {
        // Anthropic's input_tokens excludes both cache counts.
        let json = try decode("""
        {"usage": {"input_tokens": 150, "output_tokens": 40,
                   "cache_read_input_tokens": 1000, "cache_creation_input_tokens": 0}}
        """)
        let usage = try XCTUnwrap(PolishUsage.anthropic(json["usage"] as? [String: Any]))
        XCTAssertEqual(usage, PolishUsage(inputTokens: 1150, outputTokens: 40, cachedInputTokens: 1000))

        let first = try decode("""
        {"usage": {"input_tokens": 150, "output_tokens": 40,
                   "cache_read_input_tokens": 0, "cache_creation_input_tokens": 1000}}
        """)
        let written = try XCTUnwrap(PolishUsage.anthropic(first["usage"] as? [String: Any]))
        XCTAssertEqual(written.inputTokens, 1150)
        XCTAssertEqual(written.cacheWriteTokens, 1000)
        XCTAssertEqual(written.cachedInputTokens, 0)
    }

    func testMissingUsageIsNil() {
        XCTAssertNil(PolishUsage.openAI(nil))
        XCTAssertNil(PolishUsage.anthropic(nil))
    }

    private func decode(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}
