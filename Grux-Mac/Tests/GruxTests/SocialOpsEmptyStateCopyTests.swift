import XCTest
@testable import Grux

/// The two SocialOps-family panels each carry an explicit empty-SUCCESS state:
/// the service answered and holds nothing yet, which is a different sentence
/// from absence and from any fault. Before it existed, a healthy pull with zero
/// records rendered nothing at all below the header. These panels are not
/// Tier 1, so they do not join EmptyStateAuditTests' roster; this file holds
/// their copy to the same bar directly, reusing that audit's vocabulary and
/// bounded word matching rather than restating either.
@MainActor
final class SocialOpsEmptyStateCopyTests: XCTestCase {

    private static let copies: [(surface: String, text: String)] = [
        ("SocialOpsSection.emptyGridCopy", SocialOpsSection.emptyGridCopy),
        ("BrandsPostingSection.emptyStatusCopy", BrandsPostingSection.emptyStatusCopy),
    ]

    /// An empty state has to explain, not label: what the surface is for and
    /// why it is empty on a machine where the service answered.
    func testEmptySuccessCopyExplainsRatherThanLabels() {
        for (surface, text) in Self.copies {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertGreaterThanOrEqual(
                trimmed.split(separator: " ").count, 8,
                "\(surface) says \"\(trimmed)\", which is a label rather than an explanation")
        }
    }

    /// The service ANSWERED. Nothing went wrong, so no word may claim it did.
    func testEmptySuccessCopyNeverReadsAsAFailure() {
        for (surface, text) in Self.copies {
            for word in EmptyStateAuditTests.failureVocabulary
            where EmptyStateAuditTests.containsWord(word, in: text) {
                XCTFail("\(surface) says \"\(word)\" in \"\(text)\": the service answered, "
                        + "and copy that claims otherwise turns an ordinary empty panel "
                        + "into a bug report")
            }
        }
    }

    /// House voice: no em or en dashes, and nobody shouts over an empty panel.
    func testEmptySuccessCopyIsInTheHouseVoice() {
        for (surface, text) in Self.copies {
            XCTAssertFalse(text.contains("\u{2014}"), "\(surface) uses an em dash")
            XCTAssertFalse(text.contains("\u{2013}"), "\(surface) uses an en dash")
            XCTAssertFalse(text.contains("!"), "\(surface) shouts: \"\(text)\"")
        }
    }
}

/// The `ingress` provenance field on SocialOpsSnapshot: how a snapshot
/// ENTERED this Mac (pull vs push), which classify() needs to tell "a pull
/// host stopped answering" from "no pull host over push-fed data". The field
/// is new and the cache and wire both predate it, so the decode has to
/// survive JSON written before it existed, on the HardwareProfile
/// cookbook.json precedent.
final class SocialOpsSnapshotIngressTests: XCTestCase {

    /// A wire-shaped snapshot body with one record and NO ingress key, the
    /// exact bytes a pre-field social-ops.json or companion response holds.
    private let legacyJSON = Data("""
    {
      "generatedAt": 1700000000000,
      "source": "sweep",
      "records": [
        {
          "brand": "examplebrand", "platform": "threads", "status": "green",
          "loggedIn": true, "sessionValid": true, "lastPostResult": "ok",
          "rateLimited": false, "twoFAChallenge": false, "switchable": true,
          "reachTrend": "flat", "muted": false, "lastChecked": 1700000000,
          "lastError": ""
        }
      ]
    }
    """.utf8)

    func testALegacySnapshotWithoutIngressDecodesAndDefaultsToPull() throws {
        let snapshot = try JSONDecoder().decode(SocialOpsSnapshot.self, from: legacyJSON)
        XCTAssertEqual(snapshot.records.count, 1,
            "the custom decoder dropped the nested records a legacy file carries")
        XCTAssertEqual(snapshot.ingress, .pull,
            "a pre-field cache must backfill to .pull: guessing pull surfaces a "
            + "technical banner where silence was normal, while guessing push would "
            + "hide a real outage behind absence prose, and only one of those "
            + "mistakes loses information")
    }

    func testIngressSurvivesAPersistRoundTrip() throws {
        var snapshot = try JSONDecoder().decode(SocialOpsSnapshot.self, from: legacyJSON)
        snapshot.ingress = .push
        let persisted = try JSONEncoder().encode(snapshot)
        let restored = try JSONDecoder().decode(SocialOpsSnapshot.self, from: persisted)
        XCTAssertEqual(restored.ingress, .push,
            "a push-fed cache that decodes back to .pull would reclassify every later "
            + "pull absence as an outage, which is the divergence provenance exists "
            + "to end")
    }
}

/// The two pure entry rules on SocialOpsStore, shared by the refresh pull and
/// the command echo. Pure and static because the store is a singleton whose
/// apply()/persist() write real cache files, so the rules are proven here
/// without the disk.
final class SocialOpsPullProvenanceTests: XCTestCase {

    private func snapshot(generatedAt: Int64,
                          ingress: SocialOpsIngress) -> SocialOpsSnapshot {
        SocialOpsSnapshot(generatedAt: generatedAt, source: "sweep",
                          records: [], ingress: ingress)
    }

    /// Finding: init(from:) honors a wire `ingress` key (for the legacy
    /// cache), so a companion could flip provenance from the wire. The entry
    /// points stamp over it, and this pins the stamp at the adoption seam.
    func testAWireSnapshotClaimingPushStillLandsPullThroughAdoption() throws {
        let wire = Data("""
        {"generatedAt": 1700000000001, "source": "sweep", "records": [], "ingress": "push"}
        """.utf8)
        let decoded = try JSONDecoder().decode(SocialOpsSnapshot.self, from: wire)
        XCTAssertEqual(decoded.ingress, .push,
            "control: the decoder honors the wire key, so the stamp below is provably "
            + "adoption's doing rather than the decoder ignoring the field")

        let adopted = SocialOpsStore.pullAdoption(of: decoded, over: nil)
        XCTAssertEqual(adopted?.ingress, .pull,
            "a wire body chose its own provenance and adoption let it stand: the echo "
            + "and pull entries must stamp .pull over whatever the wire claimed")
    }

    /// The echo path enforces the same monotonic rule as refresh(): an older
    /// or equal payload is discarded so a concurrent push cannot be rolled
    /// backwards, and only a strictly newer one is handed back for apply().
    func testAnOlderOrEqualPayloadIsDiscardedSoAPushCannotRollBackwards() {
        let current = snapshot(generatedAt: 2000, ingress: .push)
        XCTAssertNil(SocialOpsStore.pullAdoption(
            of: snapshot(generatedAt: 2000, ingress: .pull), over: current),
            "an equal-generatedAt payload adopted anyway re-persists and re-stamps what "
            + "a concurrent push already holds")
        XCTAssertNil(SocialOpsStore.pullAdoption(
            of: snapshot(generatedAt: 1000, ingress: .pull), over: current),
            "an older echo applied over a newer push is the rollback the monotonic rule "
            + "exists to prevent")
        // Controls: strictly newer adopts, and over nothing everything adopts.
        XCTAssertEqual(SocialOpsStore.pullAdoption(
            of: snapshot(generatedAt: 3000, ingress: .push), over: current)?.generatedAt, 3000,
            "control: a strictly newer payload must adopt, or the nils above are a rule "
            + "that rejects everything")
        XCTAssertEqual(SocialOpsStore.pullAdoption(
            of: snapshot(generatedAt: 1, ingress: .push), over: nil)?.generatedAt, 1,
            "control: with nothing held every payload adopts")
    }

    /// Finding: the equal-generatedAt no-op branch never upgraded ingress, so
    /// a loopback install that pushes AND pulls held .pushFed forever, and a
    /// dead companion then classified (.absence, .pushFed) into silence over
    /// rotting data. A no-op answer still proves the host.
    func testANoOpAnswerUpgradesAPushFedSnapshotAndOnlyThat() {
        let upgraded = SocialOpsStore.pullProvenUpgrade(
            of: snapshot(generatedAt: 2000, ingress: .push))
        XCTAssertEqual(upgraded?.ingress, .pull,
            "a pull that was answered, even as a timestamp no-op, proves the host, and "
            + "a push-fed snapshot must upgrade or the install classifies a dead "
            + "companion as the normal state forever")
        XCTAssertEqual(upgraded?.generatedAt, 2000,
            "the upgrade may only flip provenance, never touch the payload")

        // nil means no flip, which is what keeps the no-op branches true
        // no-ops: the caller persists exactly when a value comes back.
        XCTAssertNil(SocialOpsStore.pullProvenUpgrade(
            of: snapshot(generatedAt: 2000, ingress: .pull)),
            "an already pull-proven snapshot re-upgraded would persist on every no-op "
            + "pull, which is the re-persist the guard exists to avoid")
        XCTAssertNil(SocialOpsStore.pullProvenUpgrade(of: nil),
            "with nothing held there is nothing to prove")
    }
}
