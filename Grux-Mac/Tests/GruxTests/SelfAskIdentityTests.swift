import XCTest
@testable import Grux

/// D208 item 10, sense pass 30 (fresh thread DE570310, 6:13 AM Nov 9, and the
/// D207 proof thread EB7D2831, grux-local:2b): a stranger's "Who are you?" got
/// "I'm Jax ... I'm free to help with tasks, approvals" ("free" reads as no
/// charge, or idle) and then "I'm Jax, an assistant running on this Mac. I
/// don't have a specific name", which names itself and says it has no name.
/// The assistant's name, the app and the model chat runs on are Grux's own
/// facts, so the question is answered from them, with no model.
@MainActor
final class SelfAskIdentityTests: XCTestCase {

    static let identityAsks = [
        "Who are you?",
        "who are you",
        "Hi, who are you?",
        "Hello! Who are you?",
        "Who are you, Grux?",
        "What are you?",
        "What's your name?",
        "What is your name?",
        "what\u{2019}s your name",
        "What should I call you?",
        "What do I call you?",
        "Who am I talking to?",
        "Who am I talking with?",
        "What is Grux?",
        "What's Grux AI?",
        "What's your name? Thanks!",
    ]

    /// Share the words, ask something else: left with the model.
    static let notIdentity = [
        "Who are you voting for?",
        "What are you doing?",
        "Who are you texting?",
        "What's your name for this file?",
        "What's my name?",
        "Who is this?",
        "Who are you and what can you do?",
        "Who are you? Add milk to my list.",
        "What is Grux doing right now?",
        "What is Grux Local?",
    ]

    func testEveryIdentityAskMatches() {
        for ask in Self.identityAsks {
            XCTAssertEqual(SelfAsk.kind(of: ask), .identity, ask)
        }
    }

    func testAsksAboutSomethingElseStayWithTheModel() {
        for ask in Self.notIdentity {
            XCTAssertNil(SelfAsk.kind(of: ask), ask)
        }
    }

    /// The ask is about Grux mid-conversation too, and after a photo: "Who
    /// are you?" never names what is in a picture ("Who is this?" does, and
    /// stays with the model).
    func testItIsGruxsOwnAskWhateverCameBefore() {
        XCTAssertEqual(SelfAsk.kind(of: "Who are you?", earlier: ["Plan my move", ""]), .identity)
    }

    static let twoB = "gruxai.com/grux/grux-local:2b"

    func testItNamesItselfTheAppAndTheModel() {
        let reply = SelfAsk.identityReply(name: "Jax", route: .thisMac(model: "Grux Local"), chatLocalModel: Self.twoB)
        XCTAssertTrue(reply.hasPrefix("I'm Jax, the assistant in Grux AI, a free app on this Mac that needs no account."), reply)
        XCTAssertTrue(reply.contains("Chat runs on Grux Local 2B, on this Mac, now."), reply)
        XCTAssertTrue(reply.contains("\"What can you do?\""), reply)
        XCTAssertTrue(reply.contains("What you call the assistant"), reply)
        XCTAssertTrue(reply.contains("Settings, \(SettingsPane.general.label)"), reply)
        for wrong in ["specific name", "free to help", "don't have a name"] {
            XCTAssertFalse(reply.contains(wrong), wrong)
        }
    }

    /// The name is the one Settings holds, so a renamed assistant says its own.
    func testARenamedAssistantSaysItsOwnName() {
        let reply = SelfAsk.identityReply(name: "Grux", route: .thisMac(model: "Grux Local"), chatLocalModel: Self.twoB)
        XCTAssertTrue(reply.hasPrefix("I'm Grux, the assistant in Grux AI"), reply)
    }

    /// The route line is the one "What model are you?" prints, so the two
    /// answers never disagree about where chat goes.
    func testTheRouteLineMatchesTheModelAnswer() {
        let routes: [PrivacyAsk.Route] = [
            .thisMac(model: "Grux Local"), .otherMachine(model: "Qwen3.5", host: "studio.local"), .anthropic,
            .custom(name: "LM Studio", host: "localhost"), .none(step: "Chat needs a model first."),
        ]
        for route in routes {
            let local: String? = { if case .thisMac = route { return Self.twoB }; return nil }()
            let identity = SelfAsk.identityReply(name: "Jax", route: route, chatLocalModel: local)
            let model = SelfAsk.smarterReply(chosen: .local, route: route, chatLocalModel: local, pick: nil, pickInstalled: false,
                                             claudeKey: nil, localModelsLine: "")
            let line = SelfAsk.routeLine(route: route, chatLocalModel: local)
            XCTAssertTrue(identity.contains(line), "\(route)")
            XCTAssertTrue(model.hasPrefix(line), "\(route)")
        }
        XCTAssertTrue(SelfAsk.identityReply(name: "Jax", route: .anthropic, chatLocalModel: nil)
            .contains("Chat runs on Claude through your Anthropic key now."))
        XCTAssertTrue(SelfAsk.identityReply(name: "Jax", route: .none(step: "Chat needs a model first."),
                                            chatLocalModel: nil).contains("Chat needs a model first."))
    }

    func testTheReplyCarriesNoDashes() {
        let reply = SelfAsk.identityReply(name: "Jax", route: .thisMac(model: "Grux Local"), chatLocalModel: Self.twoB)
        XCTAssertFalse(reply.contains("\u{2014}") || reply.contains("\u{2013}"))
    }

    /// D207 stays true: the first-run ask after "Who are you?" is the
    /// capability ask, now that Grux answers "Who are you?" itself.
    func testTheFirstRunAskStillFollowsIt() {
        let chat = [ChatMessage(role: .user, content: "Who are you?", answeredWithoutModel: true),
                    ChatMessage(role: .assistant, content: "I'm Jax, the assistant in Grux AI."),
                    ChatMessage(role: .user, content: "What should I try first?")]
        XCTAssertTrue(CapabilityAsk.matches("What should I try first?",
                                            earlier: CapabilityAsk.modelAsks(Array(chat.dropLast()))))
    }
}
