import XCTest
@testable import Grux

// These tests touch the shared singleton and disk, so each one cleans up the
// exact entries it adds (unmute what it mutes). Assertions check deltas, never
// absolute set sizes, so a residual entry from elsewhere cannot flip a result.
@MainActor
final class SenderSuppressionTests: XCTestCase {

    func testDomainOf() {
        XCTAssertEqual(SenderSuppressionStore.domain(of: "a@b.com"), "b.com")
        XCTAssertEqual(SenderSuppressionStore.domain(of: "A@B.COM"), "b.com")
        XCTAssertEqual(SenderSuppressionStore.domain(of: "noreply@mpsend.walmart.com"), "mpsend.walmart.com")
        XCTAssertNil(SenderSuppressionStore.domain(of: "garbage"))
        XCTAssertNil(SenderSuppressionStore.domain(of: ""))
    }

    func testEmailExactMatch() {
        let store = SenderSuppressionStore.shared
        let addr = "spam-test-unique@example.test"
        let other = "someone-else@example.test"

        XCTAssertFalse(store.isSuppressed(email: addr))
        store.muteEmail(addr)
        defer { store.unmuteEmail(addr) }

        // Case-insensitive match on the muted address.
        XCTAssertTrue(store.isSuppressed(email: addr))
        XCTAssertTrue(store.isSuppressed(email: "SPAM-Test-Unique@Example.Test"))
        // A different address on the same domain is NOT suppressed by an exact
        // email mute.
        XCTAssertFalse(store.isSuppressed(email: other))
    }

    func testDomainExactMatch() {
        let store = SenderSuppressionStore.shared
        let domain = "exact-domain-test.example"

        XCTAssertFalse(store.isSuppressed(email: "anyone@\(domain)"))
        store.muteDomain(domain)
        defer { store.unmuteDomain(domain) }

        XCTAssertTrue(store.isSuppressed(email: "anyone@\(domain)"))
        XCTAssertTrue(store.isSuppressed(email: "ANYONE@\(domain.uppercased())"))
    }

    func testDomainSuffixMatch() {
        let store = SenderSuppressionStore.shared
        store.muteDomain("walmart.com")
        defer { store.unmuteDomain("walmart.com") }

        // Subdomain mailer is suppressed by the bare-domain mute.
        XCTAssertTrue(store.isSuppressed(email: "no-reply@mpsend.walmart.com"))
        XCTAssertTrue(store.isSuppressed(email: "x@walmart.com"))
        // A lookalike domain must NOT match off the "walmart.com" suffix.
        XCTAssertFalse(store.isSuppressed(email: "x@notwalmart.com"))
    }

    func testAtPrefixNormalizesSameAsBare() {
        let store = SenderSuppressionStore.shared
        store.muteDomain("@suffix-norm-test.example")
        defer { store.unmuteDomain("suffix-norm-test.example") }

        // The "@"-prefixed input normalizes to the same bare domain.
        XCTAssertTrue(store.domains.contains("suffix-norm-test.example"))
        XCTAssertTrue(store.isSuppressed(email: "hi@suffix-norm-test.example"))
        XCTAssertTrue(store.isSuppressed(email: "hi@sub.suffix-norm-test.example"))
    }

    func testUnmuteRemoves() {
        let store = SenderSuppressionStore.shared
        let addr = "remove-me@unmute-test.example"
        let domain = "unmute-domain-test.example"

        store.muteEmail(addr)
        store.muteDomain(domain)
        XCTAssertTrue(store.isSuppressed(email: addr))
        XCTAssertTrue(store.isSuppressed(email: "x@\(domain)"))

        store.unmuteEmail(addr)
        store.unmuteDomain(domain)
        XCTAssertFalse(store.isSuppressed(email: addr))
        XCTAssertFalse(store.isSuppressed(email: "x@\(domain)"))
        XCTAssertFalse(store.emails.contains(addr))
        XCTAssertFalse(store.domains.contains(domain))
    }

    // muteDomain given a FULL ADDRESS must collapse to the bare domain, not store
    // a dead never-matching entry. [review-swarm finding]
    func testMuteDomainWithFullAddressCollapsesToBareDomain() {
        let store = SenderSuppressionStore.shared
        store.muteDomain("no-reply@mute-fulladdr-test.example")
        defer { store.unmuteDomain("mute-fulladdr-test.example") }
        XCTAssertTrue(store.domains.contains("mute-fulladdr-test.example"))
        XCTAssertFalse(store.domains.contains("no-reply@mute-fulladdr-test.example"))
        XCTAssertTrue(store.isSuppressed(email: "anyone@mute-fulladdr-test.example"))
    }
}
