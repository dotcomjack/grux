import XCTest
@testable import Grux

/// What a user is told when a send fails.
///
/// This is the highest-stakes copy in the app: it is read at the exact moment
/// something is broken, by somebody deciding whether the product works.
final class ChatErrorMessageTests: XCTestCase {

    /// The real body Anthropic returns when an account has no credit left. It
    /// arrives as HTTP 400 invalid_request_error, which is the whole trap.
    private let creditBody = """
    {"type":"error","error":{"type":"invalid_request_error","message":"Your credit balance is too low to access the Anthropic API. Please go to Plans & Billing to upgrade or purchase credits."}}
    """

    /// THE BUG, taken from a real log. Five consecutive turns failed, and every
    /// one was labelled "rejected as malformed, the conversation may have grown
    /// too long to send, start a new chat". The account had simply run out of
    /// credit. So the user was told to do the one thing that could not help, was
    /// offered a Retry that could only fail again, and the true reason was
    /// sitting in the response body this function discarded.
    func testAnExhaustedCreditBalanceIsNotReportedAsAMalformedRequest() {
        let msg = ChatService.humanMessage(for: ClaudeError.http(400, creditBody))

        XCTAssertTrue(msg.contains("credit balance"),
                      "the provider said exactly what was wrong and the user must be told it")
        XCTAssertFalse(msg.lowercased().contains("malformed"),
                       "nothing was malformed; saying so sends the user hunting for a fault that is not there")
        XCTAssertFalse(msg.lowercased().contains("too long"),
                       "the conversation length was never the problem and this was pure guesswork")
        XCTAssertFalse(msg.lowercased().contains("start a new chat"),
                       "a new chat fails identically, so this is an instruction that cannot work")
    }

    /// The parser has to be safe on the shapes that are NOT a tidy Anthropic
    /// error, or it turns one bad message into a crash or a wall of JSON.
    func testTheParserIsSafeOnEverythingThatIsNotATidyError() {
        XCTAssertNil(ChatService.providerMessage(from: ""))
        XCTAssertNil(ChatService.providerMessage(from: "<html>502 Bad Gateway</html>"))
        XCTAssertNil(ChatService.providerMessage(from: #"{"error":{"type":"x"}}"#),
                     "an error object with no message must not produce an empty bubble")
        XCTAssertNil(ChatService.providerMessage(from: #"{"error":{"message":"   "}}"#),
                     "whitespace is not a message")
        XCTAssertNil(ChatService.providerMessage(
            from: #"{"error":{"message":""# + String(repeating: "x", count: 400) + #""}}"#),
                     "a 400 character wall of provider text is a log entry, not a chat bubble")
        XCTAssertEqual(ChatService.providerMessage(from: #"{"error":{"message":"Nope."}}"#), "Nope.")
    }

    /// With no usable body it must still say something a person can act on, and
    /// must NOT reintroduce the guess.
    func testAnUnexplained400StillGivesAnHonestSentence() {
        let msg = ChatService.humanMessage(for: ClaudeError.http(400, "not json at all"))
        XCTAssertTrue(msg.contains("400"))
        XCTAssertFalse(msg.lowercased().contains("too long"),
                       "with no information from the provider, inventing a cause is worse than admitting none")
    }

    /// The other codes still answer for themselves, so this change did not
    /// quietly hand every failure over to the provider's wording.
    func testTheOtherStatusCodesAreUnchanged() {
        XCTAssertTrue(ChatService.humanMessage(for: ClaudeError.http(401, "{}")).contains("key"))
        XCTAssertTrue(ChatService.humanMessage(for: ClaudeError.http(429, "{}")).lowercased().contains("rate limited"))
        XCTAssertTrue(ChatService.humanMessage(for: ClaudeError.http(413, "{}")).lowercased().contains("too large"))
        XCTAssertTrue(ChatService.humanMessage(for: ClaudeError.http(503, "{}")).lowercased().contains("provider"))
    }

    /// And the banner offers something that can actually work. A plain Retry
    /// against an empty balance loops forever; switching account is a real fix,
    /// which is what the limitHit affordance already provides.
    @MainActor
    func testTheBannerForNoCreditOffersSomethingThatCanWork() {
        let recovery = ChatService.classifyChatFailure(
            error: ClaudeError.http(400, creditBody),
            userText: "hello", imageData: nil, imageMediaType: nil)

        XCTAssertEqual(recovery.kind, .limitHit,
                       "a plain retry against an empty balance can only fail again")
        XCTAssertTrue(recovery.message.lowercased().contains("credit"),
                      "the banner has to name the real cause too, not just the bubble")
        XCTAssertEqual(recovery.retryText, "hello", "the user's text must survive for a retry after topping up")
    }
}
