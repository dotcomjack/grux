import XCTest
@testable import Grux

/// Settings must not ask for a credential nothing will ever load.
///
/// The credentials list is generated from the contract rather than hand written,
/// which is the right call and was also the bug: it offered every `key.`
/// capability, all fourteen, so five paste fields sat in Settings for credentials
/// no code path reads. A stranger pastes a GitHub personal access token and it
/// goes into their Keychain and is never used by anything. A powerful token
/// sitting unused is risk with nothing on the other side of it.
///
/// CR-31 removed three false registry claims and the list is now derived from what
/// shipping features actually declare.
@MainActor
final class CredentialsOfferedTests: XCTestCase {

    /// The three that still EXIST and must never be offered, by name, so a regression
    /// says which one came back.
    ///
    /// It was five. CR-34 deleted the two scalar provider key capabilities outright on
    /// 2026-08-28, so they cannot be offered by a list that cannot name them. The three
    /// below are a different case and stay guarded: each is still declared by a blueprint,
    /// so the id is live vocabulary while the code path that would read it does not exist
    /// yet. Dead code path, not dead vocabulary.
    private let mustNotBeOffered: [SetupRequirement] = [
        .keyGithub, .keyAppstoreconnect, .keyReddit,
    ]

    func testNoCredentialIsOfferedForACapabilityNoFeatureClaims() {
        let offered = Set(FeatureRegistry.credentialsToOffer)
        let claimed = FeatureRegistry.claimedByAFeature
        let unclaimed = offered.subtracting(claimed).map(\.rawValue).sorted()
        XCTAssertTrue(unclaimed.isEmpty,
            "Settings offers a paste field for \(unclaimed), which no shipping feature "
            + "declares, so anything typed there goes into the Keychain unread")
    }

    func testTheDeadCredentialsAreNotOffered() {
        let offered = Set(FeatureRegistry.credentialsToOffer)
        for req in mustNotBeOffered {
            XCTAssertFalse(offered.contains(req), """
                Settings offers \(req.rawValue) again. Nothing in the app reads that slot:
                  key.appstoreconnect  ASCStateMonitor mints its JWT from a ship-config, not this slot
                  key.github           no GitHub API usage at all
                  key.reddit           no Reddit call at all
                If one of these gained a real consumer, give it a registry row and delete it
                from this list, in that order.
                """)
        }
    }

    /// CR-34 stays applied. A raw value is a storage format and an enum case is a
    /// compile-time name, so a reintroduction would not fail anywhere else: the two would
    /// simply reappear in the contract, in Settings, and in every count that reads
    /// `allCases`. Asserting on the raw values rather than on cases is deliberate, because
    /// naming the cases here would not compile once they are gone, which is the point.
    func testTheDeletedProviderKeyCapabilitiesStayDeleted() {
        let ids = Set(SetupRequirement.allCases.map(\.rawValue))
        for gone in ["key.openai", "key.openrouter"] {
            XCTAssertFalse(ids.contains(gone), """
                \(gone) is back in SetupRequirement. CR-34 deleted it on 2026-08-28 because a
                provider key is not a scalar slot on the app: CustomEndpointStore holds one key
                per user-added endpoint, under its own Keychain account. If a real consumer now
                exists, that is a new contract amendment, not a restored row.
                """)
        }
        XCTAssertEqual(ids.count, 41,
            "the contract should carry 41 capability ids after CR-34, found \(ids.count)")
    }

    /// The live ones must still be there. Without this the rule could regress to
    /// offering nothing at all and both tests above would pass.
    func testTheCredentialsThatAreActuallyUsedStayOffered() {
        let offered = Set(FeatureRegistry.credentialsToOffer)
        for req in [SetupRequirement.keyAnthropic, .keyElevenlabs, .keyReplicate, .keyBrave,
                    .keyResend, .keySlack, .keyNotion, .keyTelegram, .keyGodaddy] {
            XCTAssertTrue(offered.contains(req),
                "\(req.rawValue) is read by shipping code but Settings no longer offers a field "
                + "for it, so it cannot be configured through the UI at all")
        }
        XCTAssertEqual(offered.count, 9, "expected exactly the nine live credentials, got "
                       + "\(FeatureRegistry.credentialsToOffer.map(\.rawValue).sorted())")
    }

    /// CR-31's other half. `social` is a real tab that had no registry row, so its
    /// gate no-opped and the beta badge could not find it.
    func testSocialHasARegistryRowAndIsMarkedLabs() {
        let row = FeatureRegistry.row(forTab: "social")
        XCTAssertNotNil(row, "social lost its registry row, so the tab is ungated and unbadged")
        XCTAssertEqual(row?.tier, .labs, "social is one of the beta shells and must read labs")
        XCTAssertTrue(FeatureRegistry.isLabs(forTab: "social"),
                      "social has a labs row but the badge lookup disagrees")
        XCTAssertEqual(row?.requires, [], "social must not BLOCK: it is an empty shell by design, "
                       + "and a blocking requirement would put an uncleanable setup card over it")
    }

    /// The fourth beta shell. `empire` is NOT a tab: it opens as its own window
    /// from `openEmpireDashboardWindow()`, so it has no sidebar row and
    /// `isLabs(forTab:)` has no key to find it by. A registry row would not fix
    /// that, because the row-to-badge path runs through the sidebar. It carries
    /// the mark in its own title instead, and this asserts it, since a surface
    /// that ships empty owes the reader the same warning the tabs give.
    func testTheEmpireWindowCarriesTheBadgeInItsOwnTitle() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/Grux/Empire/EmpireDashboardWindow.swift"),
            encoding: .utf8)
        // Comments stripped: the comment beside the call site explains why the
        // badge is there and names it, so a raw text search would match the
        // explanation rather than the code and pass against its deletion.
        var stripped: [String] = []
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            if let r = line.range(of: "//") {
                stripped.append(String(line[line.startIndex..<r.lowerBound]))
            } else {
                stripped.append(String(line))
            }
        }
        let code = stripped.joined(separator: "\n")
        XCTAssertTrue(code.contains("BetaBadge()"),
            "the Empire window no longer marks itself beta. It has no sidebar row, so the "
            + "sidebar badge cannot cover it and removing this leaves it the one shell with "
            + "no warning at all.")
        XCTAssertNil(FeatureRegistry.row(forTab: "empire"),
            "empire gained a registry row. That does not badge it, because the badge path "
            + "runs through the sidebar and empire has no sidebar row; check the title marker "
            + "is still what carries it.")
    }

    /// Blueprints must never count as claimants. They declare capabilities too, and
    /// index.md says they are specification only with nothing implemented, so
    /// counting them would restore every field CR-31 removed.
    func testBlueprintsDoNotResurrectTheRemovedFields() throws {
        let blueprints = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/blueprints")
        let index = try String(contentsOf: blueprints.appendingPathComponent("index.md"),
                              encoding: .utf8)
        XCTAssertTrue(index.contains("specification only"),
            "the blueprint index no longer says these are specification only. If blueprints "
            + "became implemented, the credentials rule needs revisiting rather than this test "
            + "being deleted.")

        // The premise: these ARE named by blueprints, which is why the distinction matters.
        let all = try FileManager.default.contentsOfDirectory(atPath: blueprints.path)
            .filter { $0.hasSuffix(".md") }
            .map { try String(contentsOf: blueprints.appendingPathComponent($0), encoding: .utf8) }
            .joined()
        XCTAssertTrue(all.contains("key.github"),
            "no blueprint mentions key.github any more, so the reason it survives in the "
            + "contract is gone and it is now a genuine deletion candidate")
        XCTAssertFalse(FeatureRegistry.credentialsToOffer.contains(.keyGithub),
            "a blueprint mention resurrected the key.github field in Settings")
    }
}
