import XCTest
@testable import Grux

/// Cache provenance for the two digest stores is a Grux-side STAMPED fact,
/// read from a per-store defaults marker that only the entry points write
/// (refresh() adoption stamps "pull", ingest() stamps "push"). It used to be
/// derived from digest.source, a wire-controlled display string PRInboxServer
/// preserves verbatim, so a replayed Grux-persisted digest genuinely carrying
/// "grux-pull" pushed from elsewhere marked a never-pulled cache .pullProven,
/// and classify() then dressed ordinary pull absence as an outage banner.
///
/// The rule is pinned at its pure seam, which is now its ONE home:
/// PrivateServiceFetch.cacheProvenance(source:marker:). It lived as
/// byte-identical statics on both digest stores until this suite's own
/// premise (two copies can diverge) argued them into one function. The
/// stores are singletons whose apply() writes real cache files, so the
/// stamping WRITES are not driven here, only the rule that reads them.
final class DigestIngressMarkerTests: XCTestCase {

    private let rule = PrivateServiceFetch.cacheProvenance(source:marker:)

    /// The replay: a digest whose source honestly reads "grux-pull" (some
    /// Grux persisted it once) arrives over PUSH. The push stamp must win,
    /// or the never-pulled cache reads pull-proven and a later pull absence
    /// reclassifies into a fabricated outage over a healthy push channel.
    func testTheMarkerOutranksTheWireControlledSourceString() {
        XCTAssertEqual(rule("grux-pull", "push"), .pushFed,
            "a pushed digest carrying \"grux-pull\" in its display source "
            + "chose its own provenance, which is the replay the stamped marker "
            + "exists to end")
        XCTAssertEqual(rule("mini-cron", "pull"), .pullProven,
            "the pull stamp is a fact about what THIS machine did, "
            + "whatever display source the payload carries")
    }

    func testNoDigestMeansEmptyWhateverTheMarkerSays() {
        XCTAssertEqual(rule(nil, "pull"), .empty,
            "a marker outliving a deleted cache must not fabricate "
            + "provenance for nothing")
        XCTAssertEqual(rule(nil, "push"), .empty)
        XCTAssertEqual(rule(nil, nil), .empty)
    }

    /// A cache persisted by a build that predates the marker has no stamp to
    /// read. On that build the adopted pulls really did write "grux-pull"
    /// into source themselves, so the heuristic is trusted for exactly this
    /// migration case and no other.
    func testALegacyCacheWithoutTheMarkerFallsBackToTheSourceHeuristic() {
        XCTAssertEqual(rule("grux-pull", nil), .pullProven,
            "the legacy fallback lost the pull-proven read, so every "
            + "pre-marker cache reclassifies its next outage as normal absence")
        XCTAssertEqual(rule("mini-cron", nil), .pushFed,
            "a legacy push-fed cache read as pull-proven turns ordinary "
            + "absence into an outage banner")
    }

    /// The UPGRADE half of the marker, which neither store had a test for.
    ///
    /// A pull that does not adopt still upgrades a push-fed marker to "pull",
    /// so a loopback install that both pushes and pulls stops holding "push"
    /// forever. Whether it MAY is two separate questions, and one `<=` was
    /// answering both.
    private let upgrade = PrivateServiceFetch.upgradesIngressToPull(freshEpoch:heldEpoch:cache:)

    /// The equal-epoch case the upgrade's own comment describes: the answer
    /// IS the payload being held, so the host that just answered is provably
    /// the host that supplied it.
    func testAnEqualEpochAnswerUpgradesAPushFedMarker() {
        XCTAssertTrue(upgrade(1_700_000_000, 1_700_000_000, .pushFed),
            "the pull answered with exactly what this store holds and the marker stayed "
            + "\"push\", so the day the companion dies classify() reads ordinary absence "
            + "over rotting data and every surface goes silent")
    }

    /// A STRICTLY OLDER answer proves the host is alive and proves nothing
    /// about provenance. It was gated on the same `<=` as the reject rule, so
    /// a stale mirror's answer flipped a push-fed marker to pull and claimed
    /// authorship of data it never sent.
    func testAStrictlyOlderAnswerDoesNotClaimPullProvenance() {
        XCTAssertFalse(upgrade(1_699_999_000, 1_700_000_000, .pushFed),
            "an older answer stamped \"pull\" over a push-fed cache, so a stale mirror "
            + "vouched for a digest it did not supply")
    }

    /// The legacy hole: a cache persisted by a build that predates the marker
    /// has none to read, and the upgrade keyed on the literal "push", so
    /// exactly the installs carrying pre-marker data never upgraded. Judged
    /// through `cacheProvenance`, which already treats a missing marker over
    /// a non-pull source as push-fed, rather than a second copy of the rule.
    func testALegacyCacheWithNoMarkerStillUpgrades() {
        let legacyPush = rule("mini-cron", nil)
        XCTAssertEqual(legacyPush, .pushFed,
            "the provenance rule stopped reading a legacy push-fed cache as push-fed, "
            + "so the assertion below no longer covers the case it names")
        XCTAssertTrue(upgrade(1_700_000_000, 1_700_000_000, legacyPush),
            "a pre-marker push-fed cache never upgraded, which leaves the oldest "
            + "installs holding the silence-over-rotting-data hole open forever")
    }

    /// A pull-proven cache has nothing to upgrade, and an empty one has
    /// nothing to hold. Neither may write the marker on a no-op answer.
    func testNothingElseUpgrades() {
        XCTAssertFalse(upgrade(1_700_000_000, 1_700_000_000, .pullProven),
            "a marker already reading \"pull\" was rewritten, which is a write nobody needs")
        XCTAssertFalse(upgrade(1_700_000_000, 1_700_000_000, .empty),
            "an empty cache claimed pull provenance for a payload it does not hold")
    }

    /// One shared key would let a PR push rewrite the test digest's
    /// provenance, so the two stores must stamp distinct keys, and the names
    /// are pinned because they are now part of this install's persisted
    /// state. MainActor because the keys live on the MainActor stores.
    @MainActor
    func testTheTwoStoresStampDistinctPinnedKeys() {
        XCTAssertEqual(PRDigestStore.ingressDefaultsKey, "grux.services.prDigestIngress")
        XCTAssertEqual(TestDigestStore.ingressDefaultsKey, "grux.services.testDigestIngress")
        XCTAssertNotEqual(PRDigestStore.ingressDefaultsKey, TestDigestStore.ingressDefaultsKey)
    }
}
