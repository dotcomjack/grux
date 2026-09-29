import XCTest
@testable import Grux

/// P-E-3: the Labs door opens onto the accepted shelf, eight cards read from
/// the registry.
@MainActor
final class LabsShelfTests: XCTestCase {

    func test_theShelfHoldsExactlyWhatIsBehindTheDoor_inRegistryOrder() {
        let cards = LabsShelf.cards
        XCTAssertEqual(cards.count, 8)
        let behind = SidebarIA.behind(.labs).map(\.id) + SidebarIA.labsOnlyKeys
        XCTAssertEqual(cards.map(\.id), behind, "the shelf and the door disagree about what is behind it")
        XCTAssertEqual(cards.count, SidebarIA.rail(developerUnlocked: false, brands: [])
            .first { $0.id == "door.labs" }?.count, "the door's count and the shelf's cards differ")
    }

    func test_everyCardOpensSomething_andSaysWhatItIsFor() {
        for card in LabsShelf.cards {
            XCTAssertFalse(card.line.isEmpty, "\(card.id) has no line")
            if card.id == "phone" {
                XCTAssertNil(card.tabKey, "the phone is a window, not a tab")
            } else {
                let key = try? XCTUnwrap(card.tabKey)
                XCTAssertNotNil(key.flatMap { LaunchRootView.tab(forKey: $0) }, "\(card.id) opens a tab key nothing resolves")
            }
        }
    }

    func test_theLabsKeyRoundTrips_andTheDoorOpensTheShelf() throws {
        XCTAssertEqual(LaunchRootView.tab(forKey: "labs"), .labs)
        XCTAssertEqual(LaunchRootView.tabKey(for: .labs), "labs")
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/Grux/LaunchRootView.swift"), encoding: .utf8)
        let door = try XCTUnwrap(source.components(separatedBy: "case .door(let id):").dropFirst().first)
        XCTAssertTrue(door.prefix(1200).contains("Button { selection = .labs }"), "the Labs door no longer opens its shelf")
        let pane = try String(contentsOf: root.appendingPathComponent("Sources/Grux/Shell/SurfacePane.swift"), encoding: .utf8)
        XCTAssertTrue(pane.contains("case .labs:\n                    LabsShelfView"), "nothing renders the shelf")
    }

    func test_theShelfDoesNotPromiseWhatLabsCannotKeep() {
        // Self-Upgrade at its top tier lands code without asking each time, so
        // a line promising everything here stays inside Approvals would be false.
        XCTAssertFalse(LabsShelf.intro.lowercased().contains("approval"))
    }
}
