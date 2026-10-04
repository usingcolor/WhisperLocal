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
        XCTAssertEqual(CloudModelCatalog.rejectedField(body), "temperature")
    }

    func testRecognisesARejectedThinkingField() {
        let body = Data(#"{"type":"error","error":{"type":"invalid_request_error","message":"thinking: unsupported for this model"}}"#.utf8)
        XCTAssertEqual(CloudModelCatalog.rejectedField(body), "thinking")
    }

    func testLeavesOtherBadRequestsAlone() {
        let body = Data(#"{"type":"error","error":{"type":"invalid_request_error","message":"max_tokens: must be greater than 0"}}"#.utf8)
        XCTAssertNil(CloudModelCatalog.rejectedField(body))
        XCTAssertNil(CloudModelCatalog.rejectedField(Data()))
    }
}

/// GPT-6 Luna answered `temperature` with a 400, as GPT-5 does, and the rule only
/// knew the `gpt-5` prefix — so picking it failed every take.
final class OpenAITemperatureTests: XCTestCase {
    func testGPT5AndLaterGetNoTemperature() {
        XCTAssertFalse(CloudModelCatalog.supportsChatTemperature("gpt-6-luna"))
        XCTAssertFalse(CloudModelCatalog.supportsChatTemperature("gpt-6-sol"))
        XCTAssertFalse(CloudModelCatalog.supportsChatTemperature("gpt-5.6-luna"))
        XCTAssertFalse(CloudModelCatalog.supportsChatTemperature("gpt-5-mini-2025-08-07"))
        XCTAssertFalse(CloudModelCatalog.supportsChatTemperature("o4-mini"))
    }

    func testOlderModelsKeepIt() {
        XCTAssertTrue(CloudModelCatalog.supportsChatTemperature("gpt-4.1-mini"))
        XCTAssertTrue(CloudModelCatalog.supportsChatTemperature("gpt-4o"))
        XCTAssertTrue(CloudModelCatalog.supportsChatTemperature("gpt-4o-mini-2024-07-18"))
        XCTAssertTrue(CloudModelCatalog.supportsChatTemperature("gpt-3.5-turbo"))
    }

    /// Verbatim from the API, so the retry fires on the real message.
    func testRecognisesTheRealRejection() {
        let body = Data(#"{"error":{"message":"Unsupported value: 'temperature' does not support 0.2 with this model. Only the default (1) value is supported.","type":"invalid_request_error","param":"temperature","code":"unsupported_value"}}"#.utf8)
        XCTAssertEqual(CloudModelCatalog.rejectedField(body), "temperature")
    }
}

/// A default the picker cannot show is a default nobody can get back to.
final class CloudDefaultModelTests: XCTestCase {
    @MainActor
    func testDefaultsAreModelsThePickerOffers() {
        XCTAssertTrue(CloudModelCatalog.openAIRecommended.contains { $0.id == CloudModelCatalog.openAIDefault })
        XCTAssertTrue(CloudModelCatalog.anthropicRecommended.contains { $0.id == CloudModelCatalog.anthropicDefault })
    }

    @MainActor
    func testTheRetiredModelIsGone() {
        XCTAssertFalse(CloudModelCatalog.anthropicRecommended.contains { $0.id.contains("3-5-haiku") })
    }
}
