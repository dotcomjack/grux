import XCTest
@testable import Grux

@MainActor
final class OutputGateTests: XCTestCase {

    // A clean reply with no banned offer, no dash, and no ungrounded product fact
    // is allowed whether or not grounding is enforced.
    func testCleanReplyAllowedWithoutGrounding() {
        let reply = "Thanks for reaching out. Your order is on the way and should arrive soon."
        XCTAssertEqual(
            OutputGate.vet(replyText: reply, voice: "acme", enforceGrounding: false),
            .allow
        )
    }

    func testCleanReplyAllowedWithGrounding() {
        let reply = "Thanks for reaching out. Your order is on the way and should arrive soon."
        XCTAssertEqual(
            OutputGate.vet(replyText: reply, voice: "acme", enforceGrounding: true),
            .allow
        )
    }

    func testEmptyReplyBlocked() {
        XCTAssertEqual(
            OutputGate.vet(replyText: "", voice: "acme", enforceGrounding: false),
            .block(reason: "empty reply")
        )
    }

    func testWhitespaceReplyBlocked() {
        XCTAssertEqual(
            OutputGate.vet(replyText: "   \n\t  ", voice: "acme", enforceGrounding: false),
            .block(reason: "empty reply")
        )
    }

    // A literal em dash in outbound copy is blocked with a dash reason. Grounding
    // is off so this is purely the Tier 1 dash check.
    func testEmDashBlocked() {
        let reply = "Thanks for reaching out\u{2014}your order is on the way."
        let decision = OutputGate.vet(replyText: reply, voice: "acme", enforceGrounding: false)
        switch decision {
        case .block(let reason):
            XCTAssertTrue(reason.lowercased().contains("dash"), "expected dash reason, got: \(reason)")
        case .allow:
            XCTFail("expected block for em dash, got allow")
        }
    }

    // Offering a coupon is a fabricated offer that bannedTokensFound catches for
    // the "acme" voice, so it is blocked.
    func testBannedOfferBlocked() {
        let reply = "Sorry about that. Here is a coupon for your next order."
        let decision = OutputGate.vet(replyText: reply, voice: "acme", enforceGrounding: false)
        switch decision {
        case .block(let reason):
            XCTAssertTrue(reason.contains("coupon"), "expected coupon in reason, got: \(reason)")
            XCTAssertTrue(reason.hasPrefix("banned offer:"), "expected banned offer prefix, got: \(reason)")
        case .allow:
            XCTFail("expected block for coupon offer, got allow")
        }
    }
}
