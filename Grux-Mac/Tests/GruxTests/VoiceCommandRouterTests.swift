import XCTest
@testable import Grux

@MainActor
final class VoiceCommandRouterTests: XCTestCase {
    private func router(threshold: Double = 0.70, key: String = "") -> VoiceCommandRouter {
        let engine = DecisionEngine(keyLookup: { key }, ledger: DecisionLedger(storeURL: nil))
        let r = VoiceCommandRouter(engine: engine, threshold: { threshold }, macros: { [] })
        r.recentReply = { nil }
        return r
    }

    func test_navigationPhrase_executesOnTheSpot() async {
        let r = router()
        var opened: String?
        r.navigate = { opened = $0 }
        let e = await r.consider(chunk: "open my calendar")
        XCTAssertEqual(e?.outcome, .executed)
        XCTAssertEqual(opened, "calendar")
    }

    func test_chatter_isIgnored() async {
        let r = router()
        let e = await r.consider(chunk: "so anyway I was thinking about lunch")
        XCTAssertEqual(e?.outcome, .ignored)
    }

    /// CHANGED 2026-09-22, and the old expectation is the defect. A
    /// half-heard REVERSIBLE command used to queue an approval however it was
    /// heard, so room talk at 0.64 ("open contacts", measured on the
    /// operator's install) interrupted for a tab switch nobody asked for.
    /// Overheard and unsure is now ignored; addressed and unsure still asks.
    func test_belowThreshold_overheard_isIgnoredRatherThanQueued() async {
        let r = router(threshold: 0.99)
        var asked = 0
        r.askFirst = { _ in asked += 1 }
        let e = await r.consider(chunk: "open my calendar")
        XCTAssertEqual(e?.outcome, .ignored)
        XCTAssertEqual(asked, 0, "an approval was queued for something nobody said to Grux")
    }

    func test_belowThreshold_saidToGrux_stillAsks() async {
        let r = router(threshold: 0.99)
        var asked = 0
        r.askFirst = { _ in asked += 1 }
        let e = await r.consider(chunk: "grux open my calendar")
        XCTAssertEqual(e?.outcome, .askedFirst, "a command said to Grux by name must still get a question")
        XCTAssertEqual(asked, 1)
    }

    /// The rule itself, in every combination, including the one the live
    /// install hit: 0.64 against a 0.70 bar, not addressed.
    func test_theReversibleRule() {
        XCTAssertEqual(VoiceCommandRouter.onTheSpot(confidence: 0.64, threshold: 0.70, addressed: false), .ignored)
        XCTAssertEqual(VoiceCommandRouter.onTheSpot(confidence: 0.64, threshold: 0.70, addressed: true), .askedFirst)
        XCTAssertEqual(VoiceCommandRouter.onTheSpot(confidence: 0.70, threshold: 0.70, addressed: false), .executed)
        XCTAssertEqual(VoiceCommandRouter.onTheSpot(confidence: 0.99, threshold: 0.70, addressed: true), .executed)
    }

    /// The television test. Measured 2026-09-20: this exact advert reached Chat
    /// as a user message and Grux answered it out loud.
    func test_televisionAdvert_neverReachesChat() async {
        let r = router()
        var sent: [String] = []
        r.sendToChat = { sent.append($0) }
        r.askFirst = { _ in XCTFail("chatter must never ask first") }
        let e = await r.consider(chunk: "(burping) That MGM really creates unforgettable moments. It's the best.")
        await r.chatHandOff?.value
        XCTAssertEqual(e?.outcome, .ignored)
        XCTAssertEqual(sent, [])
    }

    func test_spokenToGruxByName_goesToChatWithoutThePrefix() async {
        let r = router()
        var sent: [String] = []
        r.sendToChat = { sent.append($0) }
        let e = await r.consider(chunk: "Hey Grux, why are you not responding?")
        await r.chatHandOff?.value
        XCTAssertEqual(e?.outcome, .executed)
        XCTAssertEqual(e?.commandId, VoiceCommandRouter.sayToChat)
        XCTAssertEqual(sent, ["why are you not responding?"])
    }

    func test_dictationBelowThreshold_isIgnoredNeverAsked() async {
        let r = router(threshold: 0.99)
        var sent: [String] = []
        r.sendToChat = { sent.append($0) }
        r.askFirst = { _ in XCTFail("dictation never asks first") }
        let e = await r.consider(chunk: "hey grux what time is it")
        await r.chatHandOff?.value
        XCTAssertEqual(e?.outcome, .ignored)
        XCTAssertEqual(sent, [])
    }

    /// Measured 2026-09-20: a macro triggered by "hey Grux" (with a shell step,
    /// so never by voice) claimed every sentence that started with the greeting
    /// and refused it. The greeting is an address, never a trigger.
    func test_wakePhraseMacro_neverClaimsAnAddressedSentence() async {
        let engine = DecisionEngine(keyLookup: { "" }, ledger: DecisionLedger(storeURL: nil))
        let greeting = Macro(name: "sig_dawn_patrol", triggers: ["hey Grux", "dawn patrol"], description: "",
                             rawActions: [.runShell(command: "echo hi")])
        let r = VoiceCommandRouter(engine: engine, threshold: { 0.70 }, macros: { [greeting] })
        r.recentReply = { nil }
        var sent: [String] = []
        var opened: String?
        r.sendToChat = { sent.append($0) }
        r.navigate = { opened = $0 }
        let chat = await r.consider(chunk: "Hey Grux, what time is it right now?")
        await r.chatHandOff?.value
        XCTAssertEqual(chat?.outcome, .executed)
        XCTAssertEqual(chat?.commandId, VoiceCommandRouter.sayToChat)
        XCTAssertEqual(sent, ["what time is it right now?"])
        let nav = await r.consider(chunk: "hey grux open my calendar")
        XCTAssertEqual(nav?.commandId, "tab:calendar")
        XCTAssertEqual(opened, "calendar")
        let macro = await r.consider(chunk: "dawn patrol")
        XCTAssertEqual(macro?.outcome, .refused, "its own non-wake trigger still reaches the macro, and the shell step still refuses")
    }

    /// Heard 2026-09-20 13:25:20 and ignored at 0.45: the operator answering
    /// Grux seconds after it spoke, without saying its name. A reply inside the
    /// follow-up window is addressed.
    func test_answeringGruxRightAfterItSpoke_isAddressed() async {
        let r = router()
        var sent: [String] = []
        r.sendToChat = { sent.append($0) }
        r.recentReply = { (age: 20, text: "Your move: retry, change scope, or abandon?") }
        let e = await r.consider(chunk: "That was fucked. You responded in high pitched language and sped up after you said your move.")
        await r.chatHandOff?.value
        XCTAssertEqual(e?.outcome, .executed)
        XCTAssertEqual(e?.commandId, VoiceCommandRouter.sayToChat)
        XCTAssertEqual(sent.count, 1)
    }

    func test_sameWordsLongAfterGruxSpoke_areChatterWithoutTheName() async {
        let r = router()
        var sent: [String] = []
        r.sendToChat = { sent.append($0) }
        r.recentReply = { (age: 600, text: "Your move: retry, change scope, or abandon?") }
        let e = await r.consider(chunk: "That was fucked. You responded in high pitched language and sped up after you said your move.")
        await r.chatHandOff?.value
        XCTAssertEqual(e?.outcome, .ignored)
        XCTAssertEqual(sent, [])
    }

    /// A provider that is sure the words were not for Grux is believed even in
    /// the follow-up window: the advert ten seconds after a reply stays ignored.
    /// The on-device matcher cannot judge, so its "not a command" is not sureness.
    func test_followUpWindow_yieldsToAProviderSureItIsChatter() async {
        struct Sure: DecisionProvider {
            let kind: DecisionProviderKind = .jev
            let id: String; let confidence: Double
            func decide(state: String, questions: [String: DecisionQuestion]) async throws -> DecisionResult {
                DecisionResult(answers: ["intent": .choice(id, confidence: confidence, probabilities: [id: confidence])],
                               latencyMs: 1, inputTokens: 0, outputTokens: 0, provider: .jev)
            }
        }
        let sure = DecisionEngine(keyLookup: { "k" }, ledger: DecisionLedger(storeURL: nil),
                                  remote: { _ in Sure(id: LocalDecisionProvider.notACommand, confidence: 1.0) })
        let r1 = VoiceCommandRouter(engine: sure, threshold: { 0.70 }, macros: { [] })
        r1.recentReply = { (age: 10, text: "ready") }
        var sent: [String] = []
        r1.sendToChat = { sent.append($0) }
        let tv = await r1.consider(chunk: "That MGM really creates unforgettable moments. It's the best.")
        await r1.chatHandOff?.value
        XCTAssertEqual(tv?.outcome, .ignored)
        XCTAssertEqual(sent, [])

        let unsure = DecisionEngine(keyLookup: { "k" }, ledger: DecisionLedger(storeURL: nil),
                                    remote: { _ in Sure(id: VoiceCommandRouter.sayToChat, confidence: 0.51) })
        let r2 = VoiceCommandRouter(engine: unsure, threshold: { 0.70 }, macros: { [] })
        r2.recentReply = { (age: 10, text: "Your move: retry, change scope, or abandon?") }
        r2.sendToChat = { sent.append($0) }
        let reply = await r2.consider(chunk: "That was fucked. You responded in high pitched language.")
        await r2.chatHandOff?.value
        XCTAssertEqual(reply?.outcome, .executed, "an unsure say:chat inside the window is the person answering Grux")
        XCTAssertEqual(sent.count, 1)
    }

    func test_vocabularyAlwaysCarriesNotACommand() {
        XCTAssertTrue(router().vocabulary().contains { $0.id == LocalDecisionProvider.notACommand })
    }
    /// Measured on an install sitting on the first-run setup screen: "open my
    /// calendar" reported "opened calendar" while setup still covered the whole
    /// window and no Calendar pane ever rendered. The decision was right; the
    /// report was not. It has to say what the person will actually see.
    func test_aTabCommandBehindSetup_saysSoInsteadOfClaimingItOpened() async {
        let r = router()
        var opened: String?
        r.navigate = { opened = $0 }
        r.tabsShowing = { false }
        let e = await r.consider(chunk: "open my calendar")
        XCTAssertEqual(e?.outcome, .executed)
        XCTAssertEqual(opened, "calendar", "the window should still come forward, showing the setup to finish")
        XCTAssertEqual(e?.action, "setup is showing, calendar not opened yet")
    }

    func test_aTabCommandWithTheShellShowing_opens() async {
        let r = router()
        r.navigate = { _ in }
        r.tabsShowing = { true }
        let e = await r.consider(chunk: "open my calendar")
        XCTAssertEqual(e?.action, "opened calendar")
    }
}
