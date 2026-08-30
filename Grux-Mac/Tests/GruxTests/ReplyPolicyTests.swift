import XCTest
@testable import Grux

// Pure-value tests for BrandReplyPolicy. We exercise the value logic directly
// rather than the shared on-disk store so the suite stays deterministic and does
// not depend on ~/.grux state.
@MainActor
final class ReplyPolicyTests: XCTestCase {

    func testDefaultsKindPosture() {
        let p = BrandReplyPolicy.defaults
        XCTAssertTrue(p.allows(kind: .personal))
        XCTAssertFalse(p.allows(kind: .automated))
        XCTAssertFalse(p.allows(kind: .marketing))
    }

    func testDefaultsCategoryPosture() {
        let p = BrandReplyPolicy.defaults
        XCTAssertTrue(p.allows(category: .refund))
        XCTAssertTrue(p.allows(category: .shipping))
        XCTAssertTrue(p.allows(category: .product))
        XCTAssertTrue(p.allows(category: .other))
    }

    // Empty dicts force every lookup through the missing-key fallback. Kinds
    // resolve to the opt-out posture (personal on, automated + marketing off);
    // categories resolve to true.
    func testEmptyPolicyResolvesViaFallback() {
        let p = BrandReplyPolicy(kinds: [:], categories: [:])
        XCTAssertTrue(p.allows(kind: .personal))
        XCTAssertFalse(p.allows(kind: .automated))
        XCTAssertFalse(p.allows(kind: .marketing))
        XCTAssertTrue(p.allows(category: .refund))
        XCTAssertTrue(p.allows(category: .shipping))
        XCTAssertTrue(p.allows(category: .product))
        XCTAssertTrue(p.allows(category: .other))
    }

    // An explicit override beats the fallback in both directions.
    func testExplicitOverrideBeatsFallback() {
        let p = BrandReplyPolicy(
            kinds: [EmailKind.automated.rawValue: true, EmailKind.personal.rawValue: false],
            categories: [SupportCategory.refund.rawValue: false]
        )
        XCTAssertTrue(p.allows(kind: .automated))
        XCTAssertFalse(p.allows(kind: .personal))
        XCTAssertFalse(p.allows(category: .refund))
        // Unset category still falls back to true.
        XCTAssertTrue(p.allows(category: .shipping))
    }

    func testCodableRoundTrip() throws {
        let original = BrandReplyPolicy.defaults
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(BrandReplyPolicy.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func testCodableRoundTripPartial() throws {
        let original = BrandReplyPolicy(
            kinds: [EmailKind.marketing.rawValue: true],
            categories: [:]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(BrandReplyPolicy.self, from: data)
        XCTAssertEqual(original, decoded)
        XCTAssertTrue(decoded.allows(kind: .marketing))
        XCTAssertFalse(decoded.allows(kind: .automated))
    }
}
