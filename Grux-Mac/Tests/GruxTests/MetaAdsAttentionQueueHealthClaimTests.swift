import XCTest
@testable import Grux

/// An empty attention queue is not a health verdict.
///
/// Found by launching the app, not by reading it: with no ads service
/// configured the deck rendered an amber banner naming the unset defaults key
/// and, directly beneath it, a green check reading "All clear. The engine is
/// running clean." The store already knew the pull had failed
/// (`MetaAdsStore.servingStale`, off the same classify() verdict that drew the
/// banner). The view was never told, so the rule that stops an absence being
/// reported as health stopped at the banner and never reached the empty state
/// beside it.
final class MetaAdsAttentionQueueHealthClaimTests: XCTestCase {

    func testHealthIsClaimedOnlyWhenTheSnapshotIsCurrent() {
        XCTAssertTrue(
            MetaAdsAttentionQueue.claimsHealth(itemCount: 0, stale: false),
            "A fresh pull with no alerts is the one case that may say the engine is clean.")
    }

    /// The regression itself. Red before the fix.
    func testAStaleSnapshotWithNoAlertsNeverClaimsHealth() {
        XCTAssertFalse(
            MetaAdsAttentionQueue.claimsHealth(itemCount: 0, stale: true),
            "Zero alerts in a snapshot that could not be refreshed says nothing "
            + "about the engine, so the deck must not report it as running clean.")
    }

    func testAlertsAreNeverHealthRegardlessOfFreshness() {
        for stale in [true, false] {
            XCTAssertFalse(
                MetaAdsAttentionQueue.claimsHealth(itemCount: 3, stale: stale),
                "Items in the queue are the opposite of all clear (stale: \(stale)).")
        }
    }

    /// The rule has one home, and the surface that can reach the empty state
    /// has to feed it. Comment lines are stripped first: an earlier source
    /// assertion in this wave passed by matching its own explanatory prose.
    func testTheOnlyCallSiteThatCanRenderTheEmptyStatePassesStaleness() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // GruxTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // Grux-Mac
        let sources = root.appendingPathComponent("Sources/Grux/MetaAds")

        func code(_ name: String) throws -> String {
            try String(contentsOf: sources.appendingPathComponent(name), encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
        }

        // Positive control: prove this reader can see a string that is present.
        let view = try code("MetaAdsView.swift")
        XCTAssertTrue(view.contains("MetaAdsAttentionQueue("),
                      "Reader is broken: MetaAdsView does not appear to mount the queue at all.")

        XCTAssertTrue(view.contains("stale: store.servingStale"),
                      "MetaAdsView renders the queue over a possibly stale snapshot and is the "
                      + "only call site that can reach the empty state, so it owes it the verdict.")

        // The sibling call site guards on a non-empty queue, so it cannot render
        // the claim and correctly takes the default. If that guard ever goes, this
        // fails and the call site has to start passing staleness too.
        let detail = try code("MetaAdsBrandDetailView.swift")
        XCTAssertTrue(detail.contains("if !brand.attention.isEmpty {"),
                      "MetaAdsBrandDetailView no longer guards the queue on a non-empty list, so "
                      + "it can now render the health claim and must pass `stale:` as well.")
    }
}
