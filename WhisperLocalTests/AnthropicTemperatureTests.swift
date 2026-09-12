import XCTest

/// Claude 5 rejects `temperature` with a 400, so sending it failed every take on
/// Sonnet 5 and Opus 5 — two of the three models the picker recommends.
final class AnthropicTemperatureTests: XCTestCase {
    func testClaude5FamiliesGetNoTemperature() {
        XCTAssertFalse(CloudModelCatalog.supportsMessagesTemperature("claude-opus-5"))
        XCTAssertFalse(CloudModelCatalog.supportsMessagesTemperature("claude-sonnet-5"))
        XCTAssertFalse(CloudModelCatalog.supportsMessagesTemperature("claude-sonnet-5-20260801"))
        XCTAssertFalse(CloudModelCatalog.supportsMessagesTemperature("claude-haiku-6"))
    }

    func testOlderModelsKeepIt() {
        XCTAssertTrue(CloudModelCatalog.supportsMessagesTemperature("claude-haiku-4-5"))
        XCTAssertTrue(CloudModelCatalog.supportsMessagesTemperature("claude-sonnet-4-5"))
        XCTAssertTrue(CloudModelCatalog.supportsMessagesTemperature("claude-3-5-haiku-latest"))
        XCTAssertTrue(CloudModelCatalog.supportsMessagesTemperature("claude-3-opus-20240229"))
    }

    /// Cleaning a transcript is not a reasoning task, and thinking tokens count
    /// against max_tokens — a long piece spent its budget thinking and came back
    /// cut short, so the take was pasted without cleanup.
    func testClaude5ThinksUnlessToldNotTo() {
        XCTAssertTrue(CloudModelCatalog.thinksByDefault("claude-sonnet-5"))
        XCTAssertTrue(CloudModelCatalog.thinksByDefault("claude-opus-5"))
        XCTAssertFalse(CloudModelCatalog.thinksByDefault("claude-haiku-4-5"))
        XCTAssertFalse(CloudModelCatalog.thinksByDefault("claude-3-5-haiku-latest"))
        XCTAssertFalse(CloudModelCatalog.thinksByDefault("gpt-4o-mini"))
    }

    /// Verbatim from the API, so the retry fires on the real message.
    func testRecognisesTheRealRejection() {
        let body = Data(#"{"type":"error","error":{"type":"invalid_request_error","message":"`temperature` is deprecated for this model."}}"#.utf8)
        XCTAssertEqual(AnthropicPolisher.rejectedField(body), "temperature")
    }

    func testRecognisesARejectedThinkingField() {
        let body = Data(#"{"type":"error","error":{"type":"invalid_request_error","message":"thinking: unsupported for this model"}}"#.utf8)
        XCTAssertEqual(AnthropicPolisher.rejectedField(body), "thinking")
    }

    func testLeavesOtherBadRequestsAlone() {
        let body = Data(#"{"type":"error","error":{"type":"invalid_request_error","message":"max_tokens: must be greater than 0"}}"#.utf8)
        XCTAssertNil(AnthropicPolisher.rejectedField(body))
        XCTAssertNil(AnthropicPolisher.rejectedField(Data()))
    }
}

