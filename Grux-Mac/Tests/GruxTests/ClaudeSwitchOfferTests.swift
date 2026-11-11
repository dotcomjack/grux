import XCTest
@testable import Grux

/// "USE CLAUDE" BROKE CHAT ON A MAC WITH NO KEY (D127).
///
/// Settings, Models, Custom endpoints read "Chat routes through the local model
/// at http://localhost:11434" beside a live "Use Claude" button on a Mac with no
/// Anthropic key. Claude answers only with a key, so a press either changed
/// nothing (the running local model still took every turn) or, with no local
/// model, left chat with nothing to send to.
///
/// The oracle is the router and `ChatReadiness` themselves, not a restated
/// rule: the button is offered exactly when, after a press, the turn routes to
/// Claude and can send.
final class ClaudeSwitchOfferTests: XCTestCase {

    private let endpoint = ActiveProvider.custom(UUID())

    /// Every chosen route, key or none, local model running or not: the button
    /// shows only when a press makes Claude answer, and a choice that is not
    /// Claude always gets either the button or the line naming the key.
    func testButtonOnlyWhenThePressLeavesChatAbleToSend() {
        for chosen in [ActiveProvider.anthropic, .local, endpoint] {
            for hasKey in [false, true] {
                for localUp in [false, true] {
                    let offer = ClaudeSwitchOffer.decide(chosen: chosen, hasAnthropicKey: hasKey,
                                                         localModelAvailable: localUp)
                    let routed = ModelRegistry.anthropicRoute(hasKey: hasKey, hasLocal: localUp)
                    let after = ChatReadiness.evaluate(hasAnthropicKey: hasKey,
                                                       localModelAvailable: localUp,
                                                       chosenProvider: .anthropic,
                                                       routedProvider: routed)
                    let label = "chosen \(chosen.storedValue) key \(hasKey) local \(localUp)"
                    if chosen == .anthropic {
                        XCTAssertEqual(offer, .none, label)
                    } else if routed == .anthropic && after.canSend {
                        XCTAssertEqual(offer, .button, label)
                    } else {
                        XCTAssertEqual(offer, .needsKey, label)
                    }
                }
            }
        }
    }

    /// The exact Mac the sense pass saw: local chat working, no key. A press
    /// would have kept every turn on the local model.
    func testLocalChatWithNoKeyIsNotOfferedUseClaude() {
        XCTAssertEqual(ModelRegistry.anthropicRoute(hasKey: false, hasLocal: true), .local)
        XCTAssertEqual(ClaudeSwitchOffer.decide(chosen: .local, hasAnthropicKey: false,
                                                localModelAvailable: true), .needsKey)
        XCTAssertEqual(ClaudeSwitchOffer.decide(chosen: .local, hasAnthropicKey: false,
                                                localModelAvailable: false), .needsKey)
        XCTAssertEqual(ClaudeSwitchOffer.decide(chosen: .local, hasAnthropicKey: true,
                                                localModelAvailable: true), .button)
        XCTAssertTrue(ClaudeSwitchOffer.needsKeyLine.contains("Anthropic API key"))
        XCTAssertTrue(ClaudeSwitchOffer.needsKeyLine.contains("Anthropic API above"),
                      "names the section on this same page where the key goes")
    }

    /// A removed custom endpoint with no key does not fall back to Claude:
    /// readiness reads `.needsModel` and chat refuses. The note must not say
    /// turns go to Claude then.
    func testRemovedEndpointWithNoKeyDoesNotPromiseClaude() {
        let removed = ActiveProvider.custom(UUID())
        let noKey = ClaudeSwitchOffer.fallbackNote(chosen: removed, routed: .anthropic,
                                                   hasAnthropicKey: false,
                                                   localBaseURL: "http://localhost:11434")
        XCTAssertNotNil(noKey)
        XCTAssertFalse(noKey!.contains("fall back to Claude"), noKey!)
        XCTAssertTrue(noKey!.contains("Anthropic API key"), noKey!)
        XCTAssertEqual(ChatReadiness.evaluate(hasAnthropicKey: false, localModelAvailable: true,
                                              chosenProvider: removed, routedProvider: .anthropic),
                       .needsModel)

        let withKey = ClaudeSwitchOffer.fallbackNote(chosen: removed, routed: .anthropic,
                                                     hasAnthropicKey: true,
                                                     localBaseURL: "http://localhost:11434")
        XCTAssertTrue(withKey!.contains("fall back to Claude"), withKey!)
    }

    /// A route in use needs no note, and a local choice with nothing answering
    /// keeps its sentence whatever the key (a key does not rescue a local pin).
    func testNotesForRoutesInUseAndLocalPins() {
        for hasKey in [false, true] {
            XCTAssertNil(ClaudeSwitchOffer.fallbackNote(chosen: .local, routed: .local,
                                                        hasAnthropicKey: hasKey, localBaseURL: "u"))
            let local = ClaudeSwitchOffer.fallbackNote(chosen: .local, routed: .anthropic,
                                                       hasAnthropicKey: hasKey, localBaseURL: "http://x:1")
            XCTAssertTrue(local!.contains("http://x:1"))
            XCTAssertFalse(local!.contains("Claude"), local!)
        }
    }
}
