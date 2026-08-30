import XCTest
@testable import Grux

/// 563 CALLS INTO A WALL, AND IT READ THE ERROR OUT LOUD 190 TIMES.
///
/// Measured from the owner's own logs, 2026-08-23, after the Anthropic API
/// credit balance reached zero:
///
///     253  reply FAILED: Anthropic HTTP 400
///     184  ambient extractor FAILED: Anthropic HTTP 400
///      64  jax briefing compose FAILED: Anthropic HTTP 400
///      62  stuck compose FAILED: Anthropic HTTP 400
///     190  elevenlabs -> "That turn was rejected as malformed. The conversation
///                         may have grown too long"
///      11  elevenlabs -> "Anthropic HTTP 400: {"     (raw JSON, spoken aloud)
///
/// Four autonomous loops kept firing at an account that had told them, in a
/// plain sentence, that it had no money. Every failure was then SPOKEN through
/// ElevenLabs, so a dead Anthropic balance spent a second paid credit to
/// announce itself, in wording that blamed the conversation length.
///
/// "Your credit balance is too low" is not a transient error. Retrying cannot
/// help, and only a human with a billing page can clear it. Nothing in the app
/// modelled that, so nothing could stop.
///
/// THE RULE: a non-transient, account-level refusal trips a breaker. Background
/// work checks it and stands down. A person can still push the button, because
/// they might have just topped up and their intent outranks our cache.
final class ProviderHealthTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ProviderHealth.shared.resetForTesting()
    }

    override func tearDown() {
        ProviderHealth.shared.resetForTesting()
        super.tearDown()
    }

    /// Healthy by default, or a fresh install would refuse to work.
    func testStartsHealthy() {
        XCTAssertFalse(ProviderHealth.shared.isCreditExhausted)
        XCTAssertTrue(ProviderHealth.shared.mayStartBackgroundWork)
    }

    /// THE TRIP. The provider's own sentence is the signal.
    func testTheCreditSentenceTripsTheBreaker() {
        ProviderHealth.shared.record(
            failureBody: #"{"type":"error","error":{"type":"invalid_request_error","message":"Your credit balance is too low to access the Anthropic API. Please go to Plans & Billing to upgrade or purchase credits."}}"#,
            statusCode: 400)
        XCTAssertTrue(ProviderHealth.shared.isCreditExhausted)
        XCTAssertFalse(ProviderHealth.shared.mayStartBackgroundWork,
                       "background loops would keep firing at an account with no money")
    }

    /// AND ONLY THAT. A rate limit clears on its own and a network blip is not
    /// an account problem, so neither may latch the breaker: doing so would
    /// silently disable every background feature after one bad minute.
    func testTransientFailuresDoNotTripIt() {
        ProviderHealth.shared.record(failureBody: "rate_limit_error: too many requests", statusCode: 429)
        XCTAssertFalse(ProviderHealth.shared.isCreditExhausted, "a rate limit is transient")

        ProviderHealth.shared.record(failureBody: "upstream connect error", statusCode: 503)
        XCTAssertFalse(ProviderHealth.shared.isCreditExhausted, "a 503 is transient")

        ProviderHealth.shared.record(failureBody: "overloaded_error", statusCode: 529)
        XCTAssertFalse(ProviderHealth.shared.isCreditExhausted)
    }

    /// A HUMAN CAN ALWAYS STILL TRY. They may have just added credit, and their
    /// intent outranks our cached belief. Blocking the button would turn a
    /// stuck balance into a stuck app.
    func testAPersonMayStillSendWhileTripped() {
        ProviderHealth.shared.record(failureBody: "Your credit balance is too low", statusCode: 400)
        XCTAssertTrue(ProviderHealth.shared.mayStartUserInitiatedWork,
                      "a person who just topped up must be able to retry")
        XCTAssertFalse(ProviderHealth.shared.mayStartBackgroundWork)
    }

    /// AND SUCCESS CLEARS IT. Otherwise topping up leaves every background
    /// feature dead until relaunch, which is a worse bug than the one this
    /// closes.
    func testASuccessfulCallClearsIt() {
        ProviderHealth.shared.record(failureBody: "Your credit balance is too low", statusCode: 400)
        XCTAssertTrue(ProviderHealth.shared.isCreditExhausted)
        ProviderHealth.shared.recordSuccess()
        XCTAssertFalse(ProviderHealth.shared.isCreditExhausted)
        XCTAssertTrue(ProviderHealth.shared.mayStartBackgroundWork)
    }

    /// Changing the credential is the other honest reset: a different key has a
    /// different balance, and our belief was about the old one.
    func testChangingTheKeyClearsIt() {
        ProviderHealth.shared.record(failureBody: "Your credit balance is too low", statusCode: 400)
        ProviderHealth.shared.credentialChanged()
        XCTAssertFalse(ProviderHealth.shared.isCreditExhausted)
    }

    /// SPEAKING IT ALOUD IS ITS OWN COST. The same failure was announced 190
    /// times through a paid voice API. Once is information; the rest is a bill.
    func testTheSameFailureIsAnnouncedOnce() {
        let body = "Your credit balance is too low"
        ProviderHealth.shared.record(failureBody: body, statusCode: 400)
        XCTAssertTrue(ProviderHealth.shared.shouldAnnounce(), "the first one is worth hearing")
        ProviderHealth.shared.record(failureBody: body, statusCode: 400)
        XCTAssertFalse(ProviderHealth.shared.shouldAnnounce(),
                       "announcing the identical unfixed failure again only spends voice credit")
    }

    /// A DIFFERENT failure is worth hearing, even while tripped, or the breaker
    /// would mask a genuinely new problem.
    func testADifferentFailureIsStillAnnounced() {
        ProviderHealth.shared.record(failureBody: "Your credit balance is too low", statusCode: 400)
        _ = ProviderHealth.shared.shouldAnnounce()
        ProviderHealth.shared.record(failureBody: "invalid x-api-key", statusCode: 401)
        XCTAssertTrue(ProviderHealth.shared.shouldAnnounce(),
                      "a new kind of failure was swallowed by the de-duplication")
    }
}

/// PROVES THE CLIENT ACTUALLY CONSULTS THE BREAKER.
///
/// The eight tests above all passed with the gate in `Claude.swift` neutered to
/// `if false`, because they only exercised the state machine. A rule nothing
/// calls is the defect this whole change exists to fix, so it would have been a
/// poor joke to ship it here.
final class ProviderHealthGateIntegrationTests: XCTestCase {

    override func setUp() { super.setUp(); ProviderHealth.shared.resetForTesting() }
    override func tearDown() { ProviderHealth.shared.resetForTesting(); super.tearDown() }

    /// The predicate itself, both directions.
    func testThePredicateOnlySkipsBackgroundWorkWhileTripped() {
        // INVERTED after review: background is now OPT-IN. The old flag was
        // `userInitiated`, defaulting false, and it was set at exactly one of
        // thirty seven call sites, so every user-pressed button was treated as a
        // loop and refused while latched.
        XCTAssertFalse(ProviderHealth.shared.shouldSkipCall(backgroundWork: true), "healthy: must not skip")
        ProviderHealth.shared.record(failureBody: "Your credit balance is too low", statusCode: 400)
        XCTAssertTrue(ProviderHealth.shared.shouldSkipCall(backgroundWork: true), "tripped: background must skip")
        XCTAssertFalse(ProviderHealth.shared.shouldSkipCall(backgroundWork: false), "a person is never skipped")
    }

    /// THE INTEGRATION. `complete()` must refuse locally, with no network call.
    /// Asserting the message proves the refusal came from the gate rather than
    /// from a request that went out and failed, and the elapsed time proves no
    /// round trip happened.
    func testCompleteRefusesLocallyWhileTripped() async {
        ProviderHealth.shared.record(failureBody: "Your credit balance is too low", statusCode: 400)
        let client = ClaudeClient()
        let started = Date()
        do {
            // Must opt in now. Background is no longer the default, so a call
            // that says nothing is treated as a person and is NOT skipped. That
            // inversion is the fix for the exemption covering one call site in
            // thirty seven, and this line is what proves the new contract.
            _ = try await ProviderHealth.$backgroundWork.withValue(true) {
                try await client.complete(apiKey: "sk-ant-not-a-real-key",
                                          model: "claude-haiku-4-5-20251001",
                                          system: nil,
                                          messages: [ClaudeMessage(role: "user", content: "hi")],
                                          maxTokens: 1)
            }
            XCTFail("complete() went ahead while the breaker was tripped")
        } catch {
            // Assert the CASE, not a rendered string. `standDown` is its own
            // error now precisely so a locally skipped call cannot be mistaken
            // for an HTTP 400 from Anthropic, in the UI or in the logs the
            // incident was diagnosed from.
            guard case ClaudeError.standDown = error else {
                return XCTFail("refused for the wrong reason, so the gate is not what stopped it: \(error)")
            }
            XCTAssertLessThan(Date().timeIntervalSince(started), 1.0,
                              "took long enough that a network round trip probably happened")
        }
    }
}

/// THE LIVELOCK, WHICH THIS CHANGE ALMOST SHIPPED.
///
/// Gating background work on the breaker creates a trap: background can never
/// produce the success that clears it, because it is the thing being blocked.
/// If every path that reports success is also gated, the breaker latches
/// forever and a user who tops up gets working chat and permanently dead
/// background work, recoverable only by happening to press Test Key.
///
/// So at least one UNGATED path must feed recordSuccess(). Chat is that path:
/// it streams through `streamCompleteWithTools`, which the gate does not cover.
final class ProviderHealthLivelockTests: XCTestCase {

    override func setUp() { super.setUp(); ProviderHealth.shared.resetForTesting() }
    override func tearDown() { ProviderHealth.shared.resetForTesting(); super.tearDown() }

    /// The invariant, stated as behaviour: something a gated caller cannot do
    /// must still be able to clear the latch.
    func testAnUngatedSuccessCanClearTheLatch() {
        ProviderHealth.shared.record(failureBody: "Your credit balance is too low", statusCode: 400)
        XCTAssertTrue(ProviderHealth.shared.shouldSkipCall(backgroundWork: true),
                      "precondition: background is gated")
        // Chat is not gated, so its success reaches here.
        ProviderHealth.shared.recordSuccess()
        XCTAssertFalse(ProviderHealth.shared.shouldSkipCall(backgroundWork: true),
                       "background is still gated after an ungated success, so it can never recover")
    }

    /// And the wiring that makes chat that path. Source-level because faking a
    /// streaming HTTP response here would test the fake, not the client; the
    /// behavioural half is the test above.
    func testTheChatStreamingPathReportsToTheBreaker() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/Claude.swift"), encoding: .utf8)
        guard let r = src.range(of: "func streamCompleteWithTools") else {
            return XCTFail("the streaming entry point was renamed")
        }
        var body = String(src[r.upperBound...].prefix(4000))
        // STRIP COMMENTS FIRST. A reviewer defeated the original by moving
        // recordSuccess() to BEFORE the network call, which clears the breaker
        // on every attempt regardless of outcome and disables the circuit
        // breaker entirely, while this test stayed green because the token was
        // still somewhere in the window. Matching prose is not matching code.
        body = body.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        let guardIdx = body.range(of: "guard (200..<300).contains(http.statusCode)")
        let successIdx = body.range(of: "ProviderHealth.shared.recordSuccess()")
        let failureIdx = body.range(of: "ProviderHealth.shared.record(failureBody:")

        let g = try XCTUnwrap(guardIdx, "the status-code guard moved, so position cannot be checked")
        let ok = try XCTUnwrap(successIdx, "chat's streaming path never reports success, so a latched breaker can never clear")
        let bad = try XCTUnwrap(failureIdx, "chat's streaming path never reports failure, so a credit error there is invisible")

        // POSITION IS THE POINT. Success must be recorded only AFTER the status
        // check has passed; recording it before the request means every attempt
        // clears the latch and the breaker never holds.
        XCTAssertTrue(ok.lowerBound > g.lowerBound,
                      "recordSuccess() runs before the status check, so a FAILED call clears the breaker")
        XCTAssertTrue(bad.lowerBound > g.lowerBound,
                      "the failure is recorded before the status is known")
    }
}

/// OUR OWN REFUSAL MUST NOT LOOK LIKE A FRESH PROVIDER FAILURE.
///
/// The gate throws a SYNTHETIC 400 carrying `standDownMessage`, and that string
/// then travels the same paths a real provider body does. The first draft read
/// "Anthropic credit balance is exhausted", which contains the exact phrase
/// `record` latches on, so any downstream classifier could read our own refusal
/// as new evidence of the thing it was refusing about.
final class ProviderHealthSelfClassificationTests: XCTestCase {

    override func setUp() { super.setUp(); ProviderHealth.shared.resetForTesting() }
    override func tearDown() { ProviderHealth.shared.resetForTesting(); super.tearDown() }

    func testTheStandDownMessageDoesNotRelatchTheBreaker() {
        ProviderHealth.shared.record(failureBody: ProviderHealth.standDownMessage, statusCode: 400)
        XCTAssertFalse(ProviderHealth.shared.isCreditExhausted,
                       "our own stand-down message latched the breaker, which is self-reinforcing")
    }

    /// And it must not be classified as a credit failure by the chat classifier
    /// either, which would show a billing message for a call we simply declined
    /// to make.
    @MainActor
    func testTheStandDownMessageIsNotClassifiedAsACreditFailure() {
        let err = ClaudeError.http(400, ProviderHealth.standDownMessage)
        let r = ChatService.classifyChatFailure(error: err, userText: "x", imageData: nil, imageMediaType: nil)
        XCTAssertFalse(r.message.lowercased().contains("out of credit"),
                       "a locally skipped call is reported to the user as a billing problem")
    }
}
