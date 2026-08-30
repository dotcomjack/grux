import XCTest
@testable import Grux

// Covers the FilteredMailStore behavior behind the Jax HQ "Filtered" list:
// upsert-by-id (newest first), domain/sender clearing, and the FilteredMail
// domain accessor. Touches the shared singleton + disk, so each test cleans up
// the exact ids it adds.
@MainActor
final class FilteredMailTests: XCTestCase {

    private func make(_ id: String, email: String, reason: String = "No-reply / automated",
                      kind: String? = "automated") -> FilteredMail {
        // Roster-free initializer on purpose: the brand vocabulary moved to the
        // user's own ~/.grux/brands.json, and this fixture must not depend on
        // what any one install has configured.
        FilteredMail(id: id, filteredAt: Date(),
                     inbox: SupportInbox(id: "test-brand"), brand: "test-brand",
                     fromName: "Test", fromEmail: email, subject: "s \(id)",
                     preview: "p", body: nil, reason: reason, kind: kind, category: nil)
    }

    func testDomainAccessor() {
        let m = make("ft-dom", email: "no-reply@mpsend.walmart.com")
        XCTAssertEqual(m.domain, "mpsend.walmart.com")
    }

    func testRecordUpsertsByIdNewestFirst() {
        let store = FilteredMailStore.shared
        let id = "ft-upsert-1"
        store.record(make(id, email: "a@ft-test.example", reason: "Marketing / promotional"))
        store.record(make(id, email: "a@ft-test.example", reason: "No-reply / automated"))
        defer { store.remove(id) }
        let matches = store.items.filter { $0.id == id }
        XCTAssertEqual(matches.count, 1)                       // upsert, not duplicate
        XCTAssertEqual(matches.first?.reason, "No-reply / automated")  // latest wins
        XCTAssertEqual(store.items.first?.id, id)              // newest first
    }

    func testRemoveDomainClearsAllFromThatDomain() {
        let store = FilteredMailStore.shared
        store.record(make("ft-d1", email: "x@clear-dom.example"))
        store.record(make("ft-d2", email: "y@clear-dom.example"))
        store.record(make("ft-d3", email: "z@keep-dom.example"))
        defer { ["ft-d1", "ft-d2", "ft-d3"].forEach { store.remove($0) } }

        store.removeDomain("clear-dom.example")
        XCTAssertFalse(store.items.contains { $0.id == "ft-d1" })
        XCTAssertFalse(store.items.contains { $0.id == "ft-d2" })
        XCTAssertTrue(store.items.contains { $0.id == "ft-d3" })  // other domain untouched
    }

    // Muting a parent domain must clear subdomain rows too, matching the
    // suffix semantics of the mute. [review-swarm finding]
    func testRemoveDomainClearsSubdomainRows() {
        let store = FilteredMailStore.shared
        store.record(make("ft-sub1", email: "no-reply@mpsend.sub-clear.example"))
        store.record(make("ft-sub2", email: "alerts@email.sub-clear.example"))
        store.record(make("ft-sub3", email: "x@notsub-clear.example"))
        defer { ["ft-sub1", "ft-sub2", "ft-sub3"].forEach { store.remove($0) } }

        store.removeDomain("sub-clear.example")
        XCTAssertFalse(store.items.contains { $0.id == "ft-sub1" })  // mpsend.sub-clear.example
        XCTAssertFalse(store.items.contains { $0.id == "ft-sub2" })  // email.sub-clear.example
        XCTAssertTrue(store.items.contains { $0.id == "ft-sub3" })   // lookalike, must NOT clear
    }

    func testRemoveSenderClearsExactAddress() {
        let store = FilteredMailStore.shared
        store.record(make("ft-s1", email: "dup@sender-test.example"))
        store.record(make("ft-s2", email: "other@sender-test.example"))
        defer { ["ft-s1", "ft-s2"].forEach { store.remove($0) } }
        store.removeSender("dup@sender-test.example")
        XCTAssertFalse(store.items.contains { $0.id == "ft-s1" })
        XCTAssertTrue(store.items.contains { $0.id == "ft-s2" })
    }
}
