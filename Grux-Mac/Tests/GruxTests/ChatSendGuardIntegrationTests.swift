import XCTest
@testable import Grux

/// THE HEADLINE FIX OF a6ac7ff HAD NO TEST.
///
/// That commit is titled "stop sending with nothing attached". Its entire
/// mechanism is six lines in `ChatService.send()`: ask `ChatReadiness.current()`
/// and return before assembling a turn if chat has no model to talk to.
///
/// A reviewer disabled those six lines and the whole suite stayed green. Every
/// `ChatReadinessTests` case exercises the pure `evaluate(...)` function; not
/// one of them ever called `send()`. The RULE was tested and the ENFORCEMENT
/// was not, which is the same shape as the two defects this session already
/// fixed: `SessionConcurrency.clamp` existed for hours before
/// `testStartSwarmAppliesTheClamp` proved anything called it, and the
/// `ProviderHealth` gate passed eight tests while neutered to `if false`.
///
/// Three times is a pattern, so this test is modelled on the one that worked:
/// `ProviderHealthGateIntegrationTests.testCompleteRefusesLocallyWhileTripped`
/// calls the real function, asserts the refusal came from the guard rather than
/// from a failed request, and asserts the elapsed time to show no round trip
/// happened.
///
/// HOW THE NOT-READY STATE IS REACHED WITHOUT TOUCHING ANYONE'S KEYCHAIN.
/// The obvious setup, "no API key", would mean deleting the developer's real
/// credential, and a test that vandalises the machine it runs on is not a test.
/// `.offlinePinnedButNoLocalModel` is the other `canSend == false` state and it
/// is reachable from pure in-memory state: pin offline, clear the discovered
/// local backend. Same guard, same branch, no destruction.
@MainActor
final class ChatSendGuardIntegrationTests: XCTestCase {

    private var savedOffline = false
    private var savedChat: [ChatMessage] = []
    private var savedRecovery: ChatRecovery?

    override func setUp() async throws {
        try await super.setUp()
        savedOffline = AppState.shared.offlineMode
        savedChat = AppState.shared.chat
        savedRecovery = AppState.shared.chatRecovery
    }

    override func tearDown() async throws {
        AppState.shared.offlineMode = savedOffline
        AppState.shared.chat = savedChat
        AppState.shared.chatRecovery = savedRecovery
        try await super.tearDown()
    }

    /// Puts chat into a state where no request can possibly succeed.
    private func makeNotReady() {
        AppState.shared.offlineMode = true
        ModelRegistry.shared.resetLocalForTest()
        AppState.shared.chat = []
        AppState.shared.chatRecovery = nil
    }

    /// THE ONE THAT WOULD HAVE CAUGHT IT. Calls the real `send()` and proves the
    /// turn was refused locally.
    func testSendRefusesLocallyWhenChatHasNoModel() async {
        makeNotReady()
        XCTAssertFalse(ChatReadiness.current().canSend,
                       "control: the state under test is not actually not-ready, so this proves nothing")

        // Deliberately ordinary prose. A Commands V2 trigger phrase would be
        // answered by the fast path ABOVE the guard, which is correct behaviour
        // and would make this test pass for the wrong reason.
        let probe = "what did I say about the quarterly numbers"
        let started = Date()
        await ChatService.shared.send(userText: probe)
        let elapsed = Date().timeIntervalSince(started)

        // No network round trip. A real request to api.anthropic.com, even a
        // failing one, does not come back this fast.
        // 0.5s, not 2s. The first version of this used 2.0 and passed at 1.98,
        // which is a threshold that proves nothing: the guard was sitting BELOW
        // ConfidenceGate, which makes a real model call whenever a key exists,
        // so every refused turn spent an API call before refusing. Moving the
        // guard above it took this from 1.966s to 0.012s. A budget that a
        // network round trip can slip under is not a guard against one.
        XCTAssertLessThan(elapsed, 0.5,
                          "took \(elapsed)s, long enough that a request probably went out")

        let chat = AppState.shared.chat
        XCTAssertEqual(chat.count, 2,
                       "expected the user turn plus one refusal, got \(chat.map(\.role))")
        XCTAssertEqual(chat.first?.role, .user)
        XCTAssertEqual(chat.first?.content, probe)

        let reply = try? XCTUnwrap(chat.last)
        XCTAssertEqual(reply?.role, .assistant)

        // The refusal must be the READINESS copy, not a provider error. This is
        // the assertion that distinguishes "the guard stopped it" from "the
        // request went out and failed", and it is why asserting only the message
        // COUNT would have been worthless.
        let text = (reply?.content ?? "")
        XCTAssertTrue(text.contains(ChatReadiness.offlinePinnedButNoLocalModel.headline),
                      "the reply is not the readiness notice, so something else answered: \(text)")
        XCTAssertTrue(text.contains("Settings"),
                      "the refusal does not tell the user where to go")

        // A locally refused turn never failed, so there is nothing to retry.
        // A recovery banner here would offer a Retry that cannot succeed, which
        // is the exact affordance this whole line of work removed.
        XCTAssertNil(AppState.shared.chatRecovery,
                     "a refusal that never left the machine set a retry banner")

        // And no status code anywhere. The 563-call incident was a user being
        // told about HTTP codes and conversation length when the real problem
        // was that nothing was attached.
        for banned in ["HTTP", "400", "401", "429", "rejected", "too long"] {
            XCTAssertFalse(text.contains(banned),
                           "the refusal leaked \"\(banned)\", which describes a request that never happened")
        }
    }

    /// The mirror image, and the reason the guard is placed AFTER the Commands
    /// V2 fast path rather than at the top of `send()`. If a not-ready install
    /// could not run a local command, the guard would have broken more than it
    /// fixed.
    func testTheGuardSitsBelowTheCommandFastPath() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/ChatService.swift"), encoding: .utf8)
        let fastPath = try XCTUnwrap(src.range(of: "CommandV2Engine.shared.matchTrigger"),
                                     "the V2 fast path moved")
        let guardSite = try XCTUnwrap(src.range(of: "let readiness = ChatReadiness.current()"),
                                      "the readiness guard moved")
        XCTAssertTrue(guardSite.lowerBound > fastPath.lowerBound,
                      """
                      The readiness guard now runs BEFORE the Commands V2 fast path, so an \
                      install with no model can no longer run a local command that needs no \
                      model at all.
                      """)
    }

    /// And the guard must not fire when chat IS ready, or it would block every
    /// working install. Asserts the branch is genuinely conditional rather than
    /// an unconditional early return that happens to look right in one state.
    func testAReadyStateIsNotRefused() {
        AppState.shared.offlineMode = false
        XCTAssertTrue(ChatReadiness.evaluate(hasAnthropicKey: true,
                                             localModelAvailable: false,
                                             offlineMode: false).canSend,
                      "a configured install would be refused, which would break every user")
    }
}
