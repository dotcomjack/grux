import XCTest
@testable import Grux

/// The inject seam and the dry run behind it. Injected words must reach the
/// router exactly as heard words do, always answer with a result, and never
/// act outside Grux unless asked to in so many words.
@MainActor
final class AmbientInjectTests: XCTestCase {
    private func router() -> VoiceCommandRouter {
        let engine = DecisionEngine(keyLookup: { "" }, ledger: DecisionLedger(storeURL: nil))
        let r = VoiceCommandRouter(engine: engine, threshold: { 0.70 }, macros: { [] })
        r.recentReply = { nil }
        r.askFirst = { _ in XCTFail("nothing here should ask first") }
        r.sendToChat = { _ in XCTFail("nothing here should reach chat") }
        return r
    }

    // MARK: Dry run in the router

    func test_outsideGrux_closeEverything_isDecidedButNothingIsHidden() async {
        let r = router()
        var hidden = 0
        r.hideAll = { hidden += 1; return 3 }
        let e = await r.consider(chunk: "close everything", dryRun: .outsideGrux)
        XCTAssertEqual(e?.commandId, "close_all")
        XCTAssertEqual(e?.outcome, .executed, "the decision is recorded as the policy made it")
        XCTAssertEqual(e?.dryRun, true)
        XCTAssertEqual(e?.action, "dry run: would run close_all")
        XCTAssertEqual(hidden, 0, "a dry run hid every app")
    }

    func test_outsideGrux_focusingAnotherApp_isHeldBack() async {
        let r = router()
        var focused: [String] = []
        r.runningApps = { ["Safari"] }
        r.focusApp = { focused.append($0); return true }
        let e = await r.consider(chunk: "switch to safari", dryRun: .outsideGrux)
        XCTAssertEqual(e?.commandId, "app.focus:Safari")
        XCTAssertEqual(e?.dryRun, true)
        XCTAssertEqual(focused, [], "a dry run brought another app forward")
    }

    func test_outsideGrux_stillOpensGruxsOwnTab() async {
        let r = router()
        var opened: [String] = []
        r.navigate = { opened.append($0) }
        let e = await r.consider(chunk: "open my calendar", dryRun: .outsideGrux)
        XCTAssertEqual(e?.commandId, "tab:calendar")
        XCTAssertEqual(e?.dryRun, false)
        XCTAssertEqual(e?.action, "opened calendar")
        XCTAssertEqual(opened, ["calendar"])
    }

    func test_everything_holdsBackTabsAndDictation() async {
        let r = router()
        r.navigate = { _ in XCTFail("a full dry run opened a tab") }
        let tab = await r.consider(chunk: "open my calendar", dryRun: .everything)
        XCTAssertEqual(tab?.commandId, "tab:calendar")
        XCTAssertEqual(tab?.dryRun, true)
        let chat = await r.consider(chunk: "hey grux what time is it", dryRun: .everything)
        XCTAssertEqual(chat?.commandId, VoiceCommandRouter.sayToChat)
        XCTAssertEqual(chat?.outcome, .executed)
        XCTAssertEqual(chat?.action, "dry run: would send to chat")
    }

    func test_ignoredChatter_isNotCalledADryRun() async {
        let r = router()
        let e = await r.consider(chunk: "so anyway I was thinking about lunch", dryRun: .everything)
        XCTAssertEqual(e?.outcome, .ignored)
        XCTAssertEqual(e?.dryRun, false, "nothing was held back, because nothing was going to happen")
    }

    func test_whatCountsAsOutsideGrux() {
        for id in ["close_all", "app.focus:Safari", "app.hide:Music", "app.focus", "macro:standup"] {
            XCTAssertTrue(VoiceCommandRouter.actsOutsideGrux(id), id)
        }
        for id in ["tab:calendar", "mute", "unmute", VoiceCommandRouter.sayToChat, LocalDecisionProvider.notACommand] {
            XCTAssertFalse(VoiceCommandRouter.actsOutsideGrux(id), id)
        }
    }

    // MARK: The request

    func test_plainText_defaultsToHoldingBackOtherApps() {
        XCTAssertEqual(AmbientInject.parse("  close everything\n"),
                       .init(text: "close everything", dryRun: .outsideGrux))
    }

    func test_json_choosesTheMode_andAnUnknownModeStaysSafe() {
        XCTAssertEqual(AmbientInject.parse(#"{"text":"open calendar","dryRun":"everything"}"#),
                       .init(text: "open calendar", dryRun: .everything))
        XCTAssertEqual(AmbientInject.parse(#"{"text":"open calendar","dryRun":"none"}"#),
                       .init(text: "open calendar", dryRun: .none))
        XCTAssertEqual(AmbientInject.parse(#"{"text":"close everything","dryRun":"yes please"}"#),
                       .init(text: "close everything", dryRun: .outsideGrux))
        XCTAssertEqual(AmbientInject.parse(#"{"text":"close everything"}"#).dryRun, .outsideGrux)
    }

    // MARK: No silent drops

    func test_mutedChunk_saysWhyItWasDropped() {
        XCTAssertEqual(AmbientListener.alwaysOnDropReason("open my calendar", micMuted: true),
                       "dropped: microphone is muted")
        XCTAssertNil(AmbientListener.alwaysOnDropReason("open my calendar", micMuted: false))
        XCTAssertEqual(AmbientListener.alwaysOnDropReason("um", micMuted: false),
                       "dropped: short, filler or incoherent")
    }

    func test_droppedChunk_stillGetsAResult_withNullDecision() throws {
        let req = AmbientInject.Request(text: "um", dryRun: .outsideGrux)
        let route = AmbientListener.ChunkRoute(heard: "um", stage: "dropped: short, filler or incoherent")
        let out = AmbientInject.result(for: req, route: route, wallMs: 4)
        XCTAssertEqual(out["stage"] as? String, "dropped: short, filler or incoherent")
        XCTAssertTrue(out["decisionId"] is NSNull)
        XCTAssertEqual(out["dryRunMode"] as? String, "outsideGrux")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("inject-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        AmbientInject.write(out, to: url)
        let back = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(back["wallMs"] as? Int, 4)
        XCTAssertEqual(back["text"] as? String, "um")
    }

    func test_routedChunk_resultCarriesTheDecision() {
        let req = AmbientInject.Request(text: "close everything", dryRun: .outsideGrux)
        let e = VoiceDecisionEvent(heard: "close everything", commandId: "close_all", confidence: 0.95,
                                   latencyMs: 3, provider: .local, outcome: .executed,
                                   action: "dry run: would run close_all", dryRun: true)
        let out = AmbientInject.result(for: req, route: .init(heard: "close everything", stage: "routed", event: e), wallMs: 9)
        XCTAssertEqual(out["decisionId"] as? String, "close_all")
        XCTAssertEqual(out["outcome"] as? String, "executed")
        XCTAssertEqual(out["provider"] as? String, "local")
        XCTAssertEqual(out["dryRun"] as? Bool, true)
        XCTAssertEqual(out["action"] as? String, "dry run: would run close_all")
    }
}
