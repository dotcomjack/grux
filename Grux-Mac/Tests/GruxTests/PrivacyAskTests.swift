import XCTest
@testable import Grux

/// D177, live on grux-local:2b (sense pass 22): "Does anything I type leave my
/// Mac?" got "Nothing you type leaves your Mac unless you save it to the
/// system.", a model's guess that is false on a Mac whose chat goes to a cloud
/// key or whose turn searches the web. The answer is Grux's own, from the route.
final class PrivacyAskTests: XCTestCase {
    func testTheWholeAskMatchesAndNothingElse() {
        for text in ["Does anything I type leave my Mac?", "does anything i type leave my mac",
                     "Grux, does anything I type leave my Mac?", "Hi! Is my data private?",
                     "What leaves my Mac?", "Where does my data go?", "Is this private?",
                     "Are my chats private?", "Do you send my data anywhere?", "Is anything sent to the cloud?",
                     "Does my data leave my computer?", "Who can see what I type?", "Are you running locally?",
                     "Does this run on my Mac?", "Do my messages leave this Mac?", "Is Grux private?",
                     "Does what I type leave my Mac, Grux?", "Do you send what I type to the cloud?"] {
            XCTAssertTrue(PrivacyAsk.matches(text), text)
        }
        for text in ["Does anything I type leave my Mac? Also add milk to my list.",
                     "Is this private: my bank sent me a code", "Where does my data go when I delete a note?",
                     "Is my calendar private?", "Write a privacy policy for my bakery", "private",
                     "Does my cat leave the house?", "", "Grux", "Is this private or public information?",
                     // W59-FIX P3: these ask about mail, iMessage or nothing in particular.
                     "Who can read my messages?", "Where does anything go?", "Who can see anything?"] {
            XCTAssertFalse(PrivacyAsk.matches(text), text)
        }
    }

    /// D204 (sense pass 29): "Is what I type here private?" went to the model,
    /// which answered "Everything you type stays between us." on any route.
    /// Where the typing happens ("here", "in chat", "to you") names chat, so
    /// the ask is the same one.
    func testWhereThePersonTypesIsStillTheAsk() {
        for text in ["Is what I type here private?", "Is what I type in here private?",
                     "Is what I type in chat private?", "Is what I write in this chat private?",
                     "Does what I type here leave my Mac?", "Are my messages to you private?",
                     "Are my chats with you private?", "Is anything I type to you sent to the cloud?",
                     "Who can see what I type here?", "Where does what I type in Grux go?",
                     "Is what I tell you private?", "Does anything I tell you leave my Mac?",
                     "Is my data here private?", "Are my conversations with Grux private?"] {
            XCTAssertTrue(PrivacyAsk.matches(text), text)
        }
        for text in ["Is what I type here a poem?", "Is what I typed here correct?",
                     "Who can read my messages here?", "Is anything here private?",
                     "Is my data in my calendar private?", "Is what I type here private? Also add milk to my list.",
                     "Is here private?", "Is what I type there private?"] {
            XCTAssertFalse(PrivacyAsk.matches(text), text)
        }
    }

    /// "Is this private?" after pasting a letter asks about the letter.
    func testAThisFormMidConversationStaysWithTheModel() {
        XCTAssertTrue(PrivacyAsk.matches("Is this private?"))
        XCTAssertTrue(PrivacyAsk.matches("Is this private?", earlier: ["Hi!", "What can you do?"]))
        XCTAssertFalse(PrivacyAsk.matches("Is this private?", earlier: ["Here is my letter to the bank: ..."]))
        XCTAssertTrue(PrivacyAsk.matches("Does anything I type leave my Mac?", earlier: ["Plan my move"]))
    }

    func testOnThisMacTheReplySaysChatStaysAndNamesWhatGoesOut() {
        let r = PrivacyAsk.reply(route: .thisMac(model: "Grux Local"), searchReady: false,
                                 decisionsKey: false, updateCheckOn: true)
        XCTAssertTrue(r.contains("Grux Local"), r)
        XCTAssertTrue(r.contains("does not leave this Mac"), r)
        XCTAssertTrue(r.contains("Open-Meteo"), r)
        XCTAssertTrue(r.contains("GitHub"), r)
        XCTAssertFalse(r.contains("Anthropic"), r)
        XCTAssertFalse(r.contains("Brave"), r)
        XCTAssertFalse(r.contains("TypeSafe"), r)
    }

    func testACloudRouteNeverSaysItStaysHere() {
        let anthropic = PrivacyAsk.reply(route: .anthropic, searchReady: true, decisionsKey: false, updateCheckOn: true)
        XCTAssertTrue(anthropic.contains("Anthropic"), anthropic)
        XCTAssertTrue(anthropic.contains("Brave Search"), anthropic)
        let custom = PrivacyAsk.reply(route: .custom(name: "OpenRouter", host: "openrouter.ai"), searchReady: false,
                                      decisionsKey: false, updateCheckOn: true)
        XCTAssertTrue(custom.contains("OpenRouter") && custom.contains("openrouter.ai"), custom)
        let lan = PrivacyAsk.reply(route: .otherMachine(model: "Qwen3.5", host: "192.168.1.20"), searchReady: false,
                                   decisionsKey: false, updateCheckOn: true)
        XCTAssertTrue(lan.contains("192.168.1.20"), lan)
        for r in [anthropic, custom, lan] {
            XCTAssertFalse(r.contains("does not leave this Mac"), r)
            XCTAssertTrue(r.contains("leaves this Mac"), r)
        }
    }

    func testNoModelSaysNothingGoesAndTheStep() {
        let r = PrivacyAsk.reply(route: .none(step: "Chat needs a model first."), searchReady: false,
                                 decisionsKey: false, updateCheckOn: false)
        XCTAssertTrue(r.contains("goes nowhere"), r)
        XCTAssertTrue(r.contains("Chat needs a model first."), r)
        XCTAssertFalse(r.contains("GitHub"), r)
    }

    func testTheDecisionsKeyAndTheUpdateCheckAreNamedOnlyWhenOn() {
        let on = PrivacyAsk.reply(route: .thisMac(model: "Grux Local"), searchReady: true, decisionsKey: true,
                                  updateCheckOn: true)
        XCTAssertTrue(on.contains("TypeSafe"), on)
        XCTAssertTrue(on.contains("Brave Search"), on)
        let off = PrivacyAsk.reply(route: .thisMac(model: "Grux Local"), searchReady: false, decisionsKey: false,
                                   updateCheckOn: false)
        XCTAssertFalse(off.contains("GitHub"), off)
        XCTAssertTrue(off.contains("update check is off"), off)
    }

    /// The route is the router's: what can send, and where it resolves to.
    func testTheRouteFollowsTheRouter() {
        let ep = (name: "OpenRouter", baseURL: "https://openrouter.ai/api")
        XCTAssertEqual(PrivacyAsk.route(canSend: true, pin: nil, resolved: .anthropic, localBaseURL: "http://localhost:11434",
                                        model: "x", endpoint: nil, step: nil), .anthropic)
        XCTAssertEqual(PrivacyAsk.route(canSend: true, pin: nil, resolved: .local, localBaseURL: "http://127.0.0.1:11434",
                                        model: "Grux Local", endpoint: nil, step: nil), .thisMac(model: "Grux Local"))
        XCTAssertEqual(PrivacyAsk.route(canSend: true, pin: nil, resolved: .local, localBaseURL: "http://192.168.1.20:11434",
                                        model: "Grux Local", endpoint: nil, step: nil),
                       .otherMachine(model: "Grux Local", host: "192.168.1.20"))
        XCTAssertEqual(PrivacyAsk.route(canSend: true, pin: nil, resolved: .custom(UUID()), localBaseURL: "",
                                        model: "m", endpoint: ep, step: nil),
                       .custom(name: "OpenRouter", host: "openrouter.ai"))
        XCTAssertEqual(PrivacyAsk.route(canSend: false, pin: nil, resolved: .anthropic, localBaseURL: "",
                                        model: "m", endpoint: nil, step: "s"), .none(step: "s"))
    }

    /// W59-FIX round 1 P1: a chat preset's provider pin routes the turn
    /// (`ChatService` passes `presetApp?.providerOverride` to `resolvedRouting`),
    /// whatever the registry's own choice. P2: a custom endpoint on this Mac
    /// (LM Studio on localhost) does not leave it.
    func testThePresetPinAndALoopbackEndpointRoute() {
        XCTAssertEqual(PrivacyAsk.route(canSend: true, pin: "anthropic", resolved: .local,
                                        localBaseURL: "http://localhost:11434", model: "Claude", endpoint: nil, step: nil),
                       .anthropic)
        XCTAssertEqual(PrivacyAsk.route(canSend: true, pin: "local", resolved: .anthropic,
                                        localBaseURL: "http://localhost:11434", model: "Grux Local", endpoint: nil, step: nil),
                       .thisMac(model: "Grux Local"))
        XCTAssertEqual(PrivacyAsk.route(canSend: true, pin: "local", resolved: .anthropic,
                                        localBaseURL: "http://10.0.0.5:11434", model: "Grux Local", endpoint: nil, step: nil),
                       .otherMachine(model: "Grux Local", host: "10.0.0.5"))
        XCTAssertEqual(PrivacyAsk.route(canSend: true, pin: nil, resolved: .custom(UUID()), localBaseURL: "",
                                        model: "qwen", endpoint: (name: "LM Studio", baseURL: "http://localhost:1234/v1"),
                                        step: nil),
                       .thisMac(model: "LM Studio"))
    }

    /// W59-FIX round 1 P2: a key not read yet is not a missing key; the answer
    /// over-discloses rather than leaves out a send. P3s: hosted speech and a
    /// memory mirror are named when on.
    func testUnknownKeysHostedSpeechAndTheMirrorAreNamed() {
        let unknown = PrivacyAsk.reply(route: .thisMac(model: "Grux Local"), searchReady: true, decisionsKey: nil,
                                       updateCheckOn: true)
        XCTAssertTrue(unknown.contains("If a Decisions key is set"), unknown)
        XCTAssertFalse(unknown.contains("ElevenLabs"), unknown)
        let voiced = PrivacyAsk.reply(route: .thisMac(model: "Grux Local"), searchReady: false, decisionsKey: false,
                                      updateCheckOn: true, hostedVoice: true, memoryMirrorHost: "mini.local")
        XCTAssertTrue(voiced.contains("ElevenLabs"), voiced)
        XCTAssertTrue(voiced.contains("copies memories and what it indexes to mini.local"), voiced)
        XCTAssertFalse(voiced.contains("Decisions"), voiced)
    }

    /// W59-FIX round 2 P3: an Ollama cloud model on a localhost server runs
    /// at Ollama, not on this Mac; a memory mirror carries what Grux indexes too.
    func testACloudModelAndTheMirrorSayWhatLeaves() {
        XCTAssertEqual(PrivacyAsk.route(canSend: true, pin: nil, resolved: .local, localBaseURL: "http://localhost:11434",
                                        model: "Gpt Oss", endpoint: nil, step: nil, cloudModel: true),
                       .otherMachine(model: "Gpt Oss", host: "Ollama's cloud"))
        let r = PrivacyAsk.reply(route: .thisMac(model: "Grux Local"), searchReady: false, decisionsKey: false,
                                 updateCheckOn: true, memoryMirrorHost: "mini.local")
        XCTAssertTrue(r.contains("what it indexes"), r)
        XCTAssertTrue(PrivacyAsk.isCloudModel("gpt-oss:120b-cloud") && PrivacyAsk.isCloudModel("deepseek-v3.1:671b-cloud")
                      && PrivacyAsk.isCloudModel("kimi-k2:cloud"))
        XCTAssertFalse(PrivacyAsk.isCloudModel("gruxai.com/grux/grux-local:2b") || PrivacyAsk.isCloudModel("qwen3.5:4b"))
    }

    /// W59-FIX round 9 P2: with a local preset over a cloud route, chat stays
    /// here but thread titles, summaries of long chats and web answers go by
    /// the route (`AppState.chatBackgroundRouting`): the answer names it.
    func testABackgroundRouteThatLeavesIsNamed() {
        let pinned = PrivacyAsk.reply(route: .thisMac(model: "Grux Local"), searchReady: false, decisionsKey: false,
                                      updateCheckOn: true, backgroundRoute: .anthropic)
        XCTAssertTrue(pinned.contains("also goes to Anthropic"), pinned)
        // Round 10 P3: no web answers are named while web search cannot run.
        XCTAssertFalse(pinned.contains("web search answers"), pinned)
        let searching = PrivacyAsk.reply(route: .thisMac(model: "Grux Local"), searchReady: true, decisionsKey: false,
                                         updateCheckOn: true, backgroundRoute: .anthropic)
        XCTAssertTrue(searching.contains("web search answers"), searching)
        let endpoint = PrivacyAsk.reply(route: .thisMac(model: "Grux Local"), searchReady: false, decisionsKey: false,
                                        updateCheckOn: true, backgroundRoute: .custom(name: "OpenRouter", host: "openrouter.ai"))
        XCTAssertTrue(endpoint.contains("OpenRouter (openrouter.ai)"), endpoint)
        for same in [PrivacyAsk.Route.thisMac(model: "Grux Local"), .none(step: nil)] {
            let r = PrivacyAsk.reply(route: .thisMac(model: "Grux Local"), searchReady: false, decisionsKey: false,
                                     updateCheckOn: true, backgroundRoute: same)
            XCTAssertFalse(r.contains("also goes"), r)
        }
    }

    /// Order in send(): before the readiness guard, so it answers with no model.
    func testTheRouteSitsBeforeTheReadinessGuard() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/ChatService.swift"), encoding: .utf8)
        let route = try XCTUnwrap(src.range(of: "PrivacyAsk.matches(trimmed"))
        let readiness = try XCTUnwrap(src.range(of: "let readiness = ChatReadiness.current()"))
        XCTAssertTrue(route.lowerBound < readiness.lowerBound)
    }
}
