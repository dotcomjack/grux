import XCTest
@testable import Grux

// ReplyPolicyGateTests: covers the deterministic pre-draft gate against the
// default opt-out policy. Tests lean on brands/senders that use defaults and
// restore any store mutation they make, so nothing leaks across tests.

@MainActor
final class ReplyPolicyGateTests: XCTestCase {

    func testMutedSenderSkips() {
        let email = "muted-gate-test@example.com"
        SenderSuppressionStore.shared.muteEmail(email)
        defer { SenderSuppressionStore.shared.unmuteEmail(email) }

        let decision = ReplyPolicyGate.decide(
            fromEmail: email, fromName: "Whoever", subject: "Hello",
            isBulk: false, isAutoSubmitted: false, brand: "acme")

        XCTAssertEqual(decision, .skip(reason: "muted sender", kind: nil))
    }

    func testAutomatedSkipsUnderDefaultPolicy() {
        let decision = ReplyPolicyGate.decide(
            fromEmail: "no-reply@mpsend.walmart.com", fromName: "Walmart",
            subject: "Your order shipped", isBulk: true, isAutoSubmitted: true,
            brand: "acme")

        guard case let .skip(reason, kind) = decision else {
            return XCTFail("Expected .skip for automated email, got \(decision)")
        }
        XCTAssertTrue(reason.contains("automated"), "Skip reason should mention automated, got: \(reason)")
        XCTAssertEqual(kind, .automated, "Skip should carry the detected kind for the Filtered list")
    }

    func testPersonalProceedsUnderDefaultPolicy() {
        let decision = ReplyPolicyGate.decide(
            fromEmail: "jane@gmail.com", fromName: "Jane",
            subject: "Where is my order", isBulk: false, isAutoSubmitted: false,
            brand: "acme")

        XCTAssertEqual(decision, .proceed(.personal))
    }

    func testRefundCategoryAllowedByDefault() {
        XCTAssertTrue(ReplyPolicyGate.allowsCategory(.refund, brand: "acme"))
    }
}
