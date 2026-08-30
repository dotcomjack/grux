import XCTest
@testable import Grux

// ChatService.classifyChatFailure turns a caught send() error into an
// actionable ChatRecovery so interactive chat stops dead-ending on a bare
// "⚠️" bubble. These lock the classification the recovery banner switches on:
// a 429/usage-limit offers account switch + snooze, a network drop while
// offline-with-no-local-model names that real cause, and an unknown error
// falls back to a plain retry. All branches carry the original user text so
// Retry can re-send it.
@MainActor
final class ChatRecoveryTests: XCTestCase {

    override func setUp() {
        super.setUp()
        AppState.shared.offlineMode = false
        // Discovered local-model state is shared and survives between tests, so
        // whichever test triggers discovery first decides what this one sees.
        // Clearing it makes the offline-with-no-local-model assertions below
        // deterministic instead of order-dependent.
        ModelRegistry.shared.resetLocalForTest()
    }

    override func tearDown() {
        AppState.shared.offlineMode = false
        super.tearDown()
    }

    func testHttp429ClassifiesAsLimitHit() {
        let err = ClaudeError.http(429, "rate_limit_error: too many requests")
        let r = ChatService.classifyChatFailure(
            error: err, userText: "hello there", imageData: nil, imageMediaType: nil
        )
        XCTAssertEqual(r.kind, .limitHit)
        XCTAssertEqual(r.retryText, "hello there")
        // Was `contains("usage limit")`, which encoded the old conflation: this
        // body literally says rate_limit_error, and a per-minute rate limit is
        // not an account usage cap. Waiting clears one and not the other, so
        // one sentence for both was telling somebody on a monthly cap to retry
        // shortly. Asserting the accurate word is stricter, not weaker.
        XCTAssertTrue(r.message.lowercased().contains("rate limit"))
        XCTAssertFalse(r.message.lowercased().contains("switch account"))
    }

    func testUsageLimitBodyClassifiesAsLimitHitEvenWithoutA429Code() {
        // Anthropic surfaces the monthly subscription limit on non-429 codes
        // with a body string; the classifier must catch that too.
        let err = ClaudeError.http(403, "You have hit your org's monthly usage limit")
        let r = ChatService.classifyChatFailure(
            error: err, userText: "x", imageData: nil, imageMediaType: nil
        )
        XCTAssertEqual(r.kind, .limitHit)
        // And it must NOT be described as something a moment's wait fixes.
        let m = r.message.lowercased()
        XCTAssertTrue(m.contains("usage limit"), "an account usage cap is not a per-minute rate limit")
        XCTAssertFalse(m.contains("wait a moment"), "a monthly cap does not clear by waiting a moment")
    }

    func testNetworkErrorWhileOfflineWithNoLocalModelNamesTheRealCause() {
        AppState.shared.offlineMode = true   // and no discoverLocal() ran, so local == nil
        let err = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        let r = ChatService.classifyChatFailure(
            error: err, userText: "still there?", imageData: nil, imageMediaType: nil
        )
        XCTAssertEqual(r.kind, .offlineNoModel,
                       "offline on + no local model + cloud unreachable must collapse into one honest cause, not a generic error")
        XCTAssertTrue(r.message.lowercased().contains("no local model"))
        XCTAssertEqual(r.retryText, "still there?")
    }

    func testNetworkErrorWithCloudOnlyIsRecoverableRetry() {
        // offlineMode off, no local model: a plain network retry, not offlineNoModel.
        let err = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        let r = ChatService.classifyChatFailure(
            error: err, userText: "ping", imageData: nil, imageMediaType: nil
        )
        XCTAssertTrue(r.kind == .network || r.kind == .generic)
        XCTAssertNotEqual(r.kind, .offlineNoModel)
    }

    func testUnknownErrorFallsBackToGenericRetryWithTextPreserved() {
        struct Weird: Error {}
        let r = ChatService.classifyChatFailure(
            error: Weird(), userText: "carry me", imageData: Data([1, 2, 3]), imageMediaType: "image/png"
        )
        XCTAssertEqual(r.kind, .generic)
        XCTAssertEqual(r.retryText, "carry me")
        XCTAssertEqual(r.retryImageData, Data([1, 2, 3]))
        XCTAssertEqual(r.retryImageMediaType, "image/png")
    }

    // The generic branch used to hand back error.localizedDescription, which for
    // ClaudeError.http is "Anthropic HTTP <code>: " plus 200 characters of the
    // provider's raw JSON body. That string does not stay in the chat log:
    // ChatService appends it as an assistant message, and ReactorVoiceDock's
    // caption falls back to the last assistant message, so the raw payload was
    // reprinted on the Reactor tab as
    // 'Anthropic HTTP 400: {"type":"error","error":{"type":"invalid_reque'.
    func testHttp400DoesNotLeakTheRawProviderBody() {
        let body = #"{"type":"error","error":{"type":"invalid_request_error","message":"prompt is too long"}}"#
        let r = ChatService.classifyChatFailure(
            error: ClaudeError.http(400, body), userText: "hi", imageData: nil, imageMediaType: nil
        )
        XCTAssertEqual(r.kind, .generic)
        XCTAssertFalse(r.message.contains("{"), "raw JSON reached the user: \(r.message)")
        XCTAssertFalse(r.message.contains("invalid_request_error"), "raw provider code reached the user: \(r.message)")
        // Still has to say what happened and what to do about it.
        XCTAssertTrue(r.message.contains("400"))
        XCTAssertTrue(r.message.lowercased().contains("retry"))
        XCTAssertEqual(r.retryText, "hi")
    }

    func testEveryHttpStatusGetsAnActionableMessageWithNoBody() {
        let body = #"{"secret":"do not print me"}"#
        for code in [400, 401, 403, 404, 413, 429, 500, 503, 418] {
            let msg = ChatService.humanMessage(for: ClaudeError.http(code, body))
            XCTAssertFalse(msg.contains("do not print me"), "body leaked for \(code): \(msg)")
            XCTAssertFalse(msg.contains("{"), "JSON leaked for \(code): \(msg)")
            XCTAssertTrue(msg.contains("\(code)"), "status not named for \(code): \(msg)")
        }
    }

    // A non-HTTP error has no provider body to leak, so it keeps its own
    // description rather than being flattened into a vague sentence.
    func testNonHttpErrorKeepsItsOwnDescription() {
        struct Weird: LocalizedError { var errorDescription: String? { "the disk fell off" } }
        XCTAssertEqual(ChatService.humanMessage(for: Weird()), "the disk fell off")
    }

    func testIsNetworkErrorOnlyTrueForURLErrorDomain() {
        XCTAssertTrue(ChatService.isNetworkError(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost)))
        XCTAssertFalse(ChatService.isNetworkError(
            NSError(domain: "SomeOtherDomain", code: NSURLErrorTimedOut)))
        XCTAssertFalse(ChatService.isNetworkError(ClaudeError.http(500, "boom")))
    }
}
