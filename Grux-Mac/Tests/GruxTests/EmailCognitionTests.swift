import XCTest
@testable import Grux

// Tests for the pure, model-free heuristic matching in the email cognition pass
// (Phase 1 of the email vertical slice). The fired-heuristic set must be
// explainable, so this logic is deterministic and unit tested.
final class EmailCognitionTests: XCTestCase {

    func testMatchFiresOnSupportDomain() {
        let h = [(rule: "Always reply in Sarah's voice", domain: "comms"),
                 (rule: "Never offer free items", domain: "acme-support"),
                 (rule: "Prefer compact layouts", domain: "ui")]
        let fired = EmailCognition.match(heuristics: h, subject: "question", preview: "hello there", voice: "acme")
        XCTAssertTrue(fired.contains("Always reply in Sarah's voice"))  // comms domain
        XCTAssertTrue(fired.contains("Never offer free items"))         // acme-support domain
        XCTAssertFalse(fired.contains("Prefer compact layouts"))        // ui domain, no keyword overlap
    }

    func testMatchFiresOnKeyword() {
        let h = [(rule: "Refund requests get a 30 day window", domain: "")]
        let fired = EmailCognition.match(heuristics: h, subject: "Refund please", preview: "...", voice: "x")
        XCTAssertTrue(fired.contains("Refund requests get a 30 day window"))  // "refund" overlaps
    }

    func testKeywordsDropShortTokens() {
        let kw = EmailCognition.keywords(in: "Ship the order with care")
        XCTAssertTrue(kw.contains("order"))   // 5 chars, kept
        XCTAssertFalse(kw.contains("the"))    // 3 chars, dropped
        XCTAssertFalse(kw.contains("with"))   // 4 chars, dropped
    }

    // A brand-scoped learned lesson must fire only for its own brand, never
    // pollute another brand's replies. [review-swarm]
    func testBrandScopedHeuristicDoesNotCrossBrands() {
        let h = [(rule: "Keep replies short and direct", domain: "acme-support")]
        // Fires for its own brand.
        XCTAssertTrue(EmailCognition.match(heuristics: h, subject: "order", preview: "hi", voice: "acme")
            .contains("Keep replies short and direct"))
        // Does NOT fire for another brand (no keyword overlap, domain mismatch).
        XCTAssertFalse(EmailCognition.match(heuristics: h, subject: "order", preview: "hi", voice: "globex")
            .contains("Keep replies short and direct"))
    }

    func testGeneralCommsDomainFiresForAnyBrand() {
        let h = [(rule: "Always sign off warmly", domain: "comms")]
        XCTAssertTrue(EmailCognition.match(heuristics: h, subject: "x", preview: "y", voice: "globex")
            .contains("Always sign off warmly"))
    }

    func testMatchCapsAtSix() {
        let h = (0..<20).map { (rule: "comms rule \($0)", domain: "comms") }
        XCTAssertEqual(EmailCognition.match(heuristics: h, subject: "x", preview: "y", voice: "acme").count, 6)
    }
}
