import XCTest
@testable import Grux

/// W54-P3 items 5 and 6 (wave 54 review):
/// 5. The menu bar showed the last decision's gist with no label, so "Delete
///    the meeting folder, 131 ms" could read as a thing Grux had done. It says
///    what Settings says: "Last decision about".
/// 6. Fill in OpenRouter replaced a Name and Base URL the person had typed.
///    It fills only the fields that are empty.
@MainActor
final class W54LastThreeP3Tests: XCTestCase {

    func test_theMenuBarLineSaysItIsAboutTheDecision() {
        XCTAssertEqual(DecisionUsageSummary.menuBarLine("Delete the meeting folder, 131 ms"),
                       "Last decision about: Delete the meeting folder, 131 ms")
        XCTAssertTrue(DecisionUsageSummary.menuBarLine("x").hasPrefix(DecisionUsageSummary.lastDecisionLabel))
    }

    func test_theMenuBarAndTheUsageCardUseTheSameLabel() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let menu = try String(contentsOf: root.appendingPathComponent("Sources/Grux/MenuBarView.swift"), encoding: .utf8)
        XCTAssertTrue(menu.contains("Text(DecisionUsageSummary.menuBarLine(decision))"),
                      "the menu bar draws the gist without its label")
        let card = try String(contentsOf: root.appendingPathComponent("Sources/Grux/Settings/UsageCard.swift"), encoding: .utf8)
        XCTAssertTrue(card.contains("label: DecisionUsageSummary.lastDecisionLabel"))
        XCTAssertFalse(card.contains("\"Last decision about\""))
    }

    func test_fillInOpenRouterFillsOnlyEmptyFields() {
        let ex = ModelConfigSection.openRouterExample
        let empty = ModelConfigSection.filledOpenRouter(name: "", baseURL: "")
        XCTAssertEqual(empty.name, ex.name)
        XCTAssertEqual(empty.baseURL, ex.baseURL)

        let blank = ModelConfigSection.filledOpenRouter(name: "  ", baseURL: "\n")
        XCTAssertEqual(blank.name, ex.name, "whitespace is empty")
        XCTAssertEqual(blank.baseURL, ex.baseURL)

        let typed = ModelConfigSection.filledOpenRouter(name: "My router", baseURL: "https://example.com/v1")
        XCTAssertEqual(typed.name, "My router")
        XCTAssertEqual(typed.baseURL, "https://example.com/v1")

        let half = ModelConfigSection.filledOpenRouter(name: "Work", baseURL: "")
        XCTAssertEqual(half.name, "Work")
        XCTAssertEqual(half.baseURL, ex.baseURL)
        let otherHalf = ModelConfigSection.filledOpenRouter(name: "", baseURL: "https://example.com/v1")
        // Another service's address keeps an empty name empty (wave 55 P2-2).
        XCTAssertEqual(otherHalf.name, "")
        XCTAssertEqual(otherHalf.baseURL, "https://example.com/v1")
    }

    func test_theButtonUsesTheFillThatKeepsTypedFields() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/Backend/ModelConfigView.swift"), encoding: .utf8)
        XCTAssertTrue(src.contains("Self.filledOpenRouter(name: newName, baseURL: newBaseURL)"))
        XCTAssertFalse(src.contains("newName = Self.openRouterExample.name"))
    }
}
