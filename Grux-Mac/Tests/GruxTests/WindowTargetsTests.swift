import XCTest
@testable import Grux

/// P-R-4, apps as spoken targets. Reversible only: focus and hide, and "close
/// everything" hides, never quits. The which-app question rides the voice
/// event's one call and only exists with a provider that can judge.
@MainActor
final class WindowTargetsTests: XCTestCase {

    func test_phrasesForAnApp() {
        XCTAssertTrue(WindowTargets.focusPhrases(forApp: "Safari").contains("open safari"))
        XCTAssertTrue(WindowTargets.focusPhrases(forApp: "Safari").contains("switch to safari"))
        XCTAssertTrue(WindowTargets.hidePhrases(forApp: "Safari").contains("hide safari"))
    }

    func test_closeEverythingHidesAndNothingSaidCanQuit() {
        XCTAssertEqual(WindowTargets.closeEverythingVerb, "hide")
        let r = router(apps: ["Safari", "Google Chrome"])
        for v in r.vocabulary() {
            XCTAssertFalse(v.phrases.contains { $0.contains("quit") }, "\(v.id) can be said to quit")
        }
    }

    /// A stub that answers the voice question and the which-app question from
    /// fixed picks, and counts calls.
    final class Picks: DecisionProvider, @unchecked Sendable {
        let kind: DecisionProviderKind = .jev
        var voice: String; var app: String?; var calls = 0
        init(voice: String, app: String? = nil) { self.voice = voice; self.app = app }
        func decide(state: String, questions: [String: DecisionQuestion]) async throws -> DecisionResult {
            calls += 1
            var out: [String: DecisionAnswer] = [:]
            for name in questions.keys {
                if name.hasSuffix("intent") { out[name] = .choice(voice, confidence: 0.93, probabilities: [voice: 0.93]) }
                if name.hasSuffix("__app"), let app { out[name] = .choice(app, confidence: 0.9, probabilities: [app: 0.9]) }
            }
            return DecisionResult(answers: out, latencyMs: 300, inputTokens: 900, outputTokens: 20, provider: .jev)
        }
    }

    private var focused: [String] = [], hidden: [String] = [], hidAll = 0, navigated: [String] = [], chatted: [String] = []

    private func router(apps: [String], provider: Picks? = nil, ledger given: DecisionLedger? = nil) -> VoiceCommandRouter {
        let ledger = given ?? DecisionLedger(storeURL: nil)
        let engine = provider.map { p in DecisionEngine(keyLookup: { "k" }, ledger: ledger, remote: { _ in p }) }
            ?? DecisionEngine(keyLookup: { "" }, ledger: ledger)
        let r = VoiceCommandRouter(engine: engine, threshold: { 0.7 }, macros: { [] })
        r.recentReply = { nil }
        r.runningApps = { apps }
        r.focusApp = { [unowned self] in self.focused.append($0); return true }
        r.hideApp = { [unowned self] in self.hidden.append($0); return true }
        r.hideAll = { [unowned self] in self.hidAll += 1; return 3 }
        r.navigate = { [unowned self] in self.navigated.append($0) }
        r.sendToChat = { [unowned self] in self.chatted.append($0) }
        return r
    }

    func test_keylessSpeakingAnAppByNameBringsItForward() async {
        let r = router(apps: ["Safari", "Google Chrome"])
        let e = await r.consider(chunk: "switch to safari")
        XCTAssertEqual(e?.outcome, .executed)
        XCTAssertEqual(focused, ["Safari"])
    }

    func test_keylessHideAndCloseEverything() async {
        let r = router(apps: ["Safari", "Google Chrome"])
        _ = await r.consider(chunk: "hide google chrome")
        XCTAssertEqual(hidden, ["Google Chrome"])
        _ = await r.consider(chunk: "close everything")
        XCTAssertEqual(hidAll, 1)
    }

    /// Apple's Notes and Grux's own Notes tab share a name: the tab keeps it.
    func test_anAppNamedLikeATabIsLeftToTheTab() async {
        let r = router(apps: ["Notes", "Safari"])
        XCTAssertFalse(r.vocabulary().contains { $0.id == "app.focus:Notes" })
        _ = await r.consider(chunk: "open notes")
        XCTAssertEqual(navigated, ["notes"])
        XCTAssertEqual(focused, [])
    }

    /// "Bring up my browser" names no app. With a key, one call answers both
    /// what was asked and which app it means.
    func test_whichAppIsAnsweredOnTheSameCall() async {
        let p = Picks(voice: VoiceCommandRouter.genericAppFocus, app: "Google Chrome")
        let ledger = DecisionLedger(storeURL: nil)
        let r = router(apps: ["Safari", "Google Chrome", "Terminal"], provider: p, ledger: ledger)
        let e = await r.consider(chunk: "bring up my browser")
        XCTAssertEqual(e?.outcome, .executed)
        XCTAssertEqual(e?.commandId, "app.focus:Google Chrome")
        XCTAssertEqual(focused, ["Google Chrome"])
        XCTAssertEqual(p.calls, 1)
        XCTAssertEqual(ledger.recent.map(\.surface), ["voice+app.intent"])
    }

    /// Without a confident target the generic pick is not a command: an
    /// unaddressed line is ignored and an addressed one goes to Chat, which is
    /// what happened before the question existed.
    func test_aGenericPickWithNoTargetTakesTheOldPath() async {
        let r1 = router(apps: ["Safari"], provider: Picks(voice: VoiceCommandRouter.genericAppFocus, app: VoiceCommandRouter.noApp))
        let ignored = await r1.consider(chunk: "open the pod bay doors")
        await r1.chatHandOff?.value
        XCTAssertEqual(ignored?.outcome, .ignored)
        XCTAssertEqual(focused, [])
        let r2 = router(apps: ["Safari"], provider: Picks(voice: VoiceCommandRouter.genericAppFocus, app: VoiceCommandRouter.noApp))
        let addressed = await r2.consider(chunk: "hey grux open the pod bay doors")
        await r2.chatHandOff?.value
        XCTAssertEqual(addressed?.outcome, .executed)
        XCTAssertEqual(chatted, ["open the pod bay doors"])
    }

    /// Both answers must clear the execute threshold. A generic pick the voice
    /// question is unsure of (a bystander line, measured at 0.64) does nothing
    /// new: no focus, and no ask-first card either.
    func test_anUnsureGenericPickDoesNothingNew() async {
        final class Unsure: DecisionProvider, @unchecked Sendable {
            let kind: DecisionProviderKind = .jev
            func decide(state: String, questions: [String: DecisionQuestion]) async throws -> DecisionResult {
                var out: [String: DecisionAnswer] = [:]
                for name in questions.keys {
                    if name.hasSuffix("intent") { out[name] = .choice(VoiceCommandRouter.genericAppFocus, confidence: 0.64, probabilities: [:]) }
                    if name.hasSuffix("__app") { out[name] = .choice("Messages", confidence: 1.0, probabilities: [:]) }
                }
                return DecisionResult(answers: out, latencyMs: 1, inputTokens: 1, outputTokens: 1, provider: .jev)
            }
        }
        let engine = DecisionEngine(keyLookup: { "k" }, ledger: DecisionLedger(storeURL: nil), remote: { _ in Unsure() })
        let r = VoiceCommandRouter(engine: engine, threshold: { 0.7 }, macros: { [] })
        r.recentReply = { nil }
        r.runningApps = { ["Messages", "Safari"] }
        var focused: [String] = [], asked = 0
        r.focusApp = { focused.append($0); return true }
        r.askFirst = { _ in asked += 1 }
        // Describes an app without naming it, so the which-app question is on
        // the call; the voice answer is the unsure one.
        let e = await r.consider(chunk: "she said to pull up my texts and reply to him")
        XCTAssertFalse(VoiceCommandRouter.offered(r.vocabulary(), state: "Heard: she said to pull up my texts and reply to him")
            .contains { $0.id.hasPrefix("app.focus:") }, "the fixture names an app, so it never reaches the which-app question")
        XCTAssertEqual(e?.outcome, .ignored)
        XCTAssertEqual(focused, [])
        XCTAssertEqual(asked, 0)
    }

    /// The which-app question is for requests, and a request leads with its
    /// verb. Room talk with the verb mid-sentence stays off the call.
    func test_theVerbMustLeadForTheQuestionToBeAsked() {
        for asks in ["bring up my browser", "switch to the terminal", "pull up my texts", "open the code editor",
                     "go to my files", "can you pull up my texts", "could you bring up slack"] {
            XCTAssertTrue(VoiceCommandRouter.asksToBringSomethingForward(asks), asks)
        }
        for talk in ["We just kind of want to open it up to you guys", "she said she would pull up her texts later",
                     "I was going to go to the store after lunch", "nothing about apps here"] {
            XCTAssertFalse(VoiceCommandRouter.asksToBringSomethingForward(talk), talk)
        }
    }

    /// A named app already has its own command, so the question is not asked,
    /// and keyless it is never asked.
    func test_theWhichAppQuestionIsAskedOnlyWhenItCanHelp() async {
        let named = Picks(voice: "app.focus:Safari")
        let ledger = DecisionLedger(storeURL: nil)
        _ = await router(apps: ["Safari"], provider: named, ledger: ledger).consider(chunk: "open safari")
        XCTAssertEqual(ledger.recent.map(\.surface), ["voice"])
        let keyless = DecisionLedger(storeURL: nil)
        _ = await router(apps: ["Safari"], ledger: keyless).consider(chunk: "bring up my browser")
        XCTAssertEqual(keyless.recent.map(\.surface), ["voice"])
    }
}
