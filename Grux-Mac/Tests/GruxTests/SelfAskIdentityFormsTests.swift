import XCTest
@testable import Grux

/// W73-P3 items 1 to 3 (wave 73 review): "Jax, who are you?" went to the
/// model because the assistant's own name was not a lead-in; "Do you have a
/// name?", "Tell me about yourself" and "What is Grux.ai?" were missed; and
/// the capability ask kept its own copy of the identity forms, so "Who am I
/// talking to?" answered by Grux did not open a chat and "What should I try
/// first?" after it went to the model.
@MainActor
final class SelfAskIdentityFormsTests: XCTestCase {

    static let newForms = [
        "Do you have a name?",
        "What's your name again?",
        "What is your name again?",
        "What are you called?",
        "Who are you exactly?",
        "Who are you again?",
        "Tell me about yourself.",
        "Tell me about yourself, please.",
        "What is Grux.ai?",
        "What's grux.ai?",
        "Who am I speaking to?",
        "Who am I speaking with?",
    ]

    func testTheMissedFormsAreIdentityAsks() {
        for ask in Self.newForms {
            XCTAssertEqual(SelfAsk.kind(of: ask), .identity, ask)
        }
    }

    /// The assistant's name from Settings, before or after the ask, with or
    /// without a comma, in any case.
    func testTheAssistantsNameIsALeadInAndAClosing() {
        for ask in ["Jax, who are you?", "Who are you, Jax?", "jax who are you", "Hey Jax, what's your name?",
                    "Jax. Who are you?", "JAX, do you have a name?"] {
            XCTAssertEqual(SelfAsk.kind(of: ask, name: "Jax"), .identity, ask)
        }
        XCTAssertEqual(SelfAsk.kind(of: "Nova, who are you?", name: "Nova"), .identity)
        XCTAssertEqual(SelfAsk.kind(of: "Who are you, Mister Bean?", name: "Mister Bean"), .identity)
        XCTAssertEqual(SelfAsk.kind(of: "Jax, which model are you using?", name: "Jax"), .smarterModel)
        XCTAssertEqual(SelfAsk.kind(of: "Jax, do you work offline?", name: "Jax"), .offline)
    }

    /// Another name is not the assistant's, and the name beside another ask
    /// leaves the message with the model.
    func testOnlyTheAssistantsOwnNameIsDropped() {
        XCTAssertNil(SelfAsk.kind(of: "Nova, who are you?", name: "Jax"))
        XCTAssertNil(SelfAsk.kind(of: "Jax, write me a poem.", name: "Jax"))
        XCTAssertNil(SelfAsk.kind(of: "Jax", name: "Jax"))
        XCTAssertNil(SelfAsk.kind(of: "Who is Jax?", name: "Jax"))
        XCTAssertNil(SelfAsk.kind(of: "Who are you, and who is Jax?", name: "Jax"))
    }

    /// A name that is itself an ask word never eats the ask.
    func testANameThatIsAnAskWordKeepsTheAsk() {
        XCTAssertEqual(SelfAsk.kind(of: "Who are you?", name: "Who"), .identity)
        XCTAssertEqual(SelfAsk.kind(of: "What's your name?", name: "Name"), .identity)
    }

    /// Wrong near misses stay with the model.
    func testNearMissesStayWithTheModel() {
        for ask in ["Do you have a name for this file?", "What are you called in Spanish?",
                    "Tell me about yourself and then plan my week.", "What is Grux.ai pricing?",
                    "Who am I speaking to at the bank?", "Tell me about your weekend."] {
            XCTAssertNil(SelfAsk.kind(of: ask), ask)
        }
    }

    /// The class guard: every form Grux answers as "who are you" opens a chat
    /// for the capability ask, so the two lists can never drift again.
    func testEveryIdentityFormOpensAChat() {
        for form in SelfAsk.identityAsks {
            let ask = form.prefix(1).uppercased() + form.dropFirst() + "?"
            XCTAssertEqual(SelfAsk.kind(of: ask), .identity, ask)
            XCTAssertTrue(CapabilityAsk.isOpening(ask), ask)
            XCTAssertTrue(CapabilityAsk.matches("What should I try first?", earlier: [ask]), ask)
        }
        for ask in Self.newForms {
            XCTAssertTrue(CapabilityAsk.isOpening(ask), ask)
            XCTAssertFalse(CapabilityAsk.matches(ask), ask)
        }
    }

    func testWhoAmITalkingToThenAFirstRunOrPrivacyAsk() {
        for first in ["Who am I talking to?", "What should I call you?", "What is Grux AI?", "Jax, who are you?"] {
            XCTAssertTrue(CapabilityAsk.matches("What should I try first?", earlier: [first], name: "Jax"), first)
            XCTAssertTrue(CapabilityAsk.isOpening(first, name: "Jax"), first)
        }
        XCTAssertTrue(PrivacyAsk.matches("Is this private?", earlier: ["Who am I talking to?"]))
    }

    /// The name lead-in opens a chat; another sentence beside it does not.
    func testTheNameInTheCapabilityAsk() {
        XCTAssertTrue(CapabilityAsk.matches("Jax, what can you do?", name: "Jax"))
        XCTAssertTrue(CapabilityAsk.matches("What can you do, Jax?", name: "Jax"))
        XCTAssertFalse(CapabilityAsk.matches("Nova, what can you do?", name: "Jax"))
        XCTAssertFalse(CapabilityAsk.isOpening("Jax, plan my week.", name: "Jax"))
    }
}
