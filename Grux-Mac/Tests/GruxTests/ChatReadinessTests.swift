import XCTest
@testable import Grux

/// CHAT LET YOU SEND WITH NO MODEL ATTACHED, AND BLAMED THE CONVERSATION.
///
/// `ModelRegistry.resolvedRouting` falls back to Anthropic when no local model
/// is discovered, and hands back `apiKey()` whatever it is. With no key stored
/// and no local server that is an EMPTY key, so every send went out to the
/// network and came back a provider error. The user could retry forever, and
/// the error they saw talked about HTTP codes and conversation length, neither
/// of which was the problem. The problem was that nothing was attached.
///
/// The failure is not the wording, it is that the send was attempted at all. A
/// request that cannot possibly succeed should never leave the app.
///
/// PURE FUNCTION ON PURPOSE. `current()` reads the Keychain and the discovered
/// backend, so on any machine that already has credentials, and this is
/// developed on one, a test of it can only ever observe "ready". `evaluate` is
/// the rule, taking the three facts as arguments, which is the same reason
/// `CapabilityResolver.keyPrecedence` was pulled out of `isSatisfied`.
final class ChatReadinessTests: XCTestCase {

    /// THE BUG. No key, no local model, nothing pinned offline.
    func testNoKeyAndNoLocalModelIsNotReady() {
        let r = ChatReadiness.evaluate(hasAnthropicKey: false,
                                       localModelAvailable: false,
                                       offlineMode: false)
        XCTAssertFalse(r.canSend, "chat would send to Anthropic with an empty key")
        XCTAssertEqual(r, .needsModel)
    }

    /// A local model needs no key, but only once the router will actually USE it.
    ///
    /// THIS TEST ENSHRINED THE BUG. It asserted that a discovered local model
    /// with offline mode OFF was `.ready`, which is what the old truth table
    /// said and what the router flatly contradicts:
    /// `ModelRegistry.offlineReady` is `offlineMode && local != nil`, so with
    /// offline off the turn goes to Anthropic regardless. Discovery runs
    /// unconditionally at launch, so the ordinary local setup (Ollama up, no API
    /// key) reported READY, enabled Send, and sent with an empty key. The guard
    /// missed the exact state it was written for, and this test agreed with it.
    func testALocalModelIsEnoughOnceOfflineModeRoutesToIt() {
        XCTAssertTrue(ChatReadiness.evaluate(hasAnthropicKey: false,
                                             localModelAvailable: true,
                                             offlineMode: true).canSend,
                      "offline on plus a discovered model is the one state that truly routes local")
    }

    /// And the state that used to be mislabelled READY now says what to do.
    func testADiscoveredLocalModelWithOfflineOffIsNotReady() {
        let r = ChatReadiness.evaluate(hasAnthropicKey: false,
                                       localModelAvailable: true,
                                       offlineMode: false)
        XCTAssertFalse(r.canSend, "the router would send to Anthropic with an empty key")
        XCTAssertEqual(r, .localModelFoundButNotRouted)
        let text = (r.headline + " " + r.detail).lowercased()
        XCTAssertTrue(text.contains("offline"),
                      "the one action that fixes this is turning offline mode on, and the copy must say so")
    }

    /// A key is enough on its own.
    func testAKeyIsEnoughOnItsOwn() {
        XCTAssertTrue(ChatReadiness.evaluate(hasAnthropicKey: true,
                                             localModelAvailable: false,
                                             offlineMode: false).canSend)
    }

    /// OFFLINE PINNED WITH NOTHING TO RUN. The user asked for local and there is
    /// no local, so a silent fall back to a cloud key would be the opposite of
    /// what they chose. `resolvedRouting` already refuses to do that for a
    /// local-pinned preset; readiness has to agree with it rather than report
    /// green because a key happens to exist.
    func testOfflineModeWithNoLocalModelIsNotReadyEvenWithAKey() {
        let r = ChatReadiness.evaluate(hasAnthropicKey: true,
                                       localModelAvailable: false,
                                       offlineMode: true)
        XCTAssertFalse(r.canSend,
                       "offline is pinned and there is no local server, so this send cannot work")
        XCTAssertEqual(r, .offlinePinnedButNoLocalModel)
    }

    /// The message has to name BOTH ways out. A user with no key does not
    /// necessarily want to buy one; the local path is free and is the reason
    /// this app can run with no account at all.
    func testTheNotReadyMessageOffersBothWaysOut() {
        for state in [ChatReadiness.needsModel, .offlinePinnedButNoLocalModel] {
            let text = (state.headline + " " + state.detail).lowercased()
            XCTAssertTrue(text.contains("local"),
                          "\(state) never mentions running a local model, which needs no key")
            XCTAssertTrue(text.contains("key"),
                          "\(state) never mentions adding a key")
            XCTAssertTrue(text.contains("settings"),
                          "\(state) does not say where to go")
            XCTAssertFalse(text.contains("http"),
                           "\(state) leaks a status code into copy about a missing model")
            XCTAssertFalse(text.contains("retry"),
                           "\(state) offers a retry that cannot possibly succeed")
        }
    }

    /// TWO CREDENTIALS, AND THE UI NEVER SAID SO.
    ///
    /// Grux has two entirely separate auth paths and they are easy to confuse
    /// because both end in the word Claude:
    ///
    ///   1. An Anthropic API key in the Keychain, which powers Grux's own chat.
    ///   2. A claude.ai OAuth login, run as `claude auth login --claudeai` by
    ///      AccountSwitcher, which signs the agent CLI in so headless terminal
    ///      sessions can draw on a subscription.
    ///
    /// The second is called from AgentService.resumeWithAccountSwitch and from
    /// nowhere near chat, so signing the CLI in gives chat NOTHING. Reported by
    /// the owner 2026-08-23: hit the no-model state, ended up on a Claude sign-in
    /// page linking a terminal, and still had no key powering Grux.
    ///
    /// So the not-ready copy has to be explicit about which one it means.
    func testTheMessageDistinguishesGruxsKeyFromSigningTheCliIn() {
        let text = (ChatReadiness.needsModel.headline + " " + ChatReadiness.needsModel.detail).lowercased()
        XCTAssertTrue(text.contains("own key") || text.contains("your own api key"),
                      "the copy does not make clear whose key this is")
        XCTAssertTrue(text.contains("terminal session") || text.contains("signing"),
                      """
                      The copy never distinguishes this key from signing the agent CLI in. \
                      Those are different credentials and a user who does the second still \
                      has no chat.
                      """)
    }

    /// A ready state must carry no scolding copy for the composer to render.
    func testReadyHasNothingToSay() {
        XCTAssertTrue(ChatReadiness.ready.canSend)
        XCTAssertTrue(ChatReadiness.ready.headline.isEmpty)
        XCTAssertTrue(ChatReadiness.ready.detail.isEmpty)
    }
}

/// The notice has to land the user on the FIELD, not the pane.
///
/// "models" resolves to `SettingsLocation(pane: .models)` with no anchor, so it
/// opens the top of a long pane and leaves the user hunting. "api" resolves to
/// `anchor: "models.api"`, which is the Anthropic key field itself. Getting this
/// wrong is how a "go to Settings" sentence becomes a scavenger hunt.
final class ChatReadinessRoutingTests: XCTestCase {

    func testTheNoticeRoutesToTheKeyFieldNotThePaneTop() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/ChatView.swift"), encoding: .utf8)
        guard let r = src.range(of: "ChatReadinessNotice(readiness: readiness)") else {
            return XCTFail("the notice is no longer constructed here")
        }
        let window = String(src[r.upperBound...].prefix(320))
        XCTAssertTrue(window.contains("\"api\""),
                      "the notice opens the Models pane top instead of the Anthropic key field")
    }

    /// And the destination must actually resolve to that anchor.
    @MainActor
    func testTheApiTagResolvesToTheAnthropicKeyField() {
        let loc = SettingsTabAliases.resolve("api")
        XCTAssertEqual(loc.anchor, "models.api",
                       "the api tag no longer points at the key field")
    }
}
