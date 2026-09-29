import XCTest
@testable import Grux

/// C12: Meta Ads and Social appear only once a brand exists, so something has
/// to name the door. "Add a brand" is that door, in onboarding and in Settings,
/// and it writes the hand-editable roster without losing anything in it.
final class AddBrandTests: XCTestCase {

    private func object(_ data: Data?) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(data)) as? [String: Any])
    }

    func test_aLabelFilesUnderAStableId() {
        XCTAssertEqual(BrandRoster.slug("Harbor Bakery"), "harbor-bakery")
        XCTAssertEqual(BrandRoster.slug("  Acme, Inc.  "), "acme-inc")
        XCTAssertEqual(BrandRoster.slug("Trail -- Head"), "trail-head")
        XCTAssertEqual(BrandRoster.slug("  "), "")
    }

    func test_theFirstBrandCreatesTheRoster_andReadsBackThroughTheRealDecoder() throws {
        let r = BrandRoster.adding(label: "Harbor Bakery", to: nil)
        XCTAssertEqual(r.outcome, .added(id: "harbor-bakery"))
        let roster = try JSONDecoder().decode(BrandRoster.Roster.self, from: XCTUnwrap(r.data))
        XCTAssertEqual(roster.brands.map(\.id), ["harbor-bakery"])
        XCTAssertEqual(roster.brands.map(\.label), ["Harbor Bakery"])
    }

    /// The file is hand-editable. A writer that drops what it does not know
    /// destroys somebody's configuration.
    func test_everythingAlreadyInTheFileSurvives() throws {
        let existing = Data(#"{"brands":[{"id":"acme","label":"Acme","bannedOffers":["bogo"]}],"supportInboxes":[{"id":"acme"}],"note":"hand written"}"#.utf8)
        let r = BrandRoster.adding(label: "Trailhead", to: existing)
        XCTAssertEqual(r.outcome, .added(id: "trailhead"))
        let o = try object(r.data)
        XCTAssertEqual(o["note"] as? String, "hand written")
        XCTAssertEqual((o["supportInboxes"] as? [[String: Any]])?.count, 1)
        let brands = try XCTUnwrap(o["brands"] as? [[String: Any]])
        XCTAssertEqual(brands.compactMap { $0["id"] as? String }, ["acme", "trailhead"])
        XCTAssertEqual(brands.first?["bannedOffers"] as? [String], ["bogo"])
    }

    func test_aBrandAlreadyThereOrNotANameWritesNothing() {
        let existing = Data(#"{"brands":[{"id":"acme","label":"Acme"}],"supportInboxes":[{"id":"shop"}]}"#.utf8)
        XCTAssertEqual(BrandRoster.adding(label: "ACME", to: existing).outcome, .alreadyThere(id: "acme"))
        XCTAssertNil(BrandRoster.adding(label: "ACME", to: existing).data)
        XCTAssertEqual(BrandRoster.adding(label: "Shop", to: existing).outcome, .alreadyThere(id: "shop"),
                       "an inbox is a brand too")
        XCTAssertEqual(BrandRoster.adding(label: "   ", to: existing).outcome, .notAName)
        XCTAssertEqual(BrandRoster.adding(label: "All", to: existing).outcome, .notAName,
                       "`all` is the filter's match-everything token")
    }

    func test_addingWritesTheFileAndTheLabelsReadBack() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("brands-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(BrandRoster.add(label: "Harbor Bakery", at: url), .added(id: "harbor-bakery"))
        XCTAssertEqual(BrandRoster.add(label: "Harbor Bakery", at: url), .alreadyThere(id: "harbor-bakery"))
        XCTAssertEqual(BrandRoster.labelsOnDisk(at: url), ["Harbor Bakery"])
    }

    /// The door is where a person looks: the Connections step of onboarding,
    /// and a Settings section that search can find.
    func test_theDoorIsNamedInOnboardingAndSettings() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux")
        let steps = try String(contentsOf: root.appendingPathComponent("Onboarding/OnboardingSteps.swift"), encoding: .utf8)
        let connections = try XCTUnwrap(steps.components(separatedBy: "struct ConnectionsStep: View {").dropFirst().first)
        XCTAssertTrue(connections.prefix(2_500).contains("AddBrandRow()"), "onboarding no longer names the brand door")
        let settings = try String(contentsOf: root.appendingPathComponent("SettingsView.swift"), encoding: .utf8)
        XCTAssertTrue(settings.contains("Section(\"Brands\") {\n                            AddBrandRow()"))
        XCTAssertTrue(SettingsSearchRegistry.entries.contains { $0.id == "data.brands" }, "search cannot find Brands")
        XCTAssertEqual(SettingsTabAliases.resolve("brands").anchor, "data.brands",
                       "`settings:brands` opens the wrong place (seen live: it opened General)")
        for copy in [AddBrandRow.purpose, AddBrandRow.addedCopy("Acme"), AddBrandRow.notANameCopy] {
            XCTAssertFalse(copy.contains("\u{2014}") || copy.contains("\u{2013}"))
        }
    }
}
