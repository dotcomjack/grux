import XCTest
@testable import Grux

// D179 item 5: the Cognition Map marked every answered chat turn "Simulate"
// (`cognitionMap-page1.png`, sense pass 22). Every writer stamps the goal
// pursuit autonomy mode, but that setting governs only the autonomous goal
// cycle: a chat turn, a support email draft or a fact check ran for real
// whatever it reads, so "Simulate" under one says nothing ran when it did.
final class CognitionAutonomyTagTests: XCTestCase {

    private func event(_ kind: CognitionEventKind, mode: String) -> CognitionEvent {
        CognitionEvent(kind: kind, trigger: "t", mode: mode, outcome: "o")
    }

    func test_aChatTurnShowsNoAutonomyTagWhateverModeItCarries() {
        for mode in ["simulate", "observe", "live", ""] {
            XCTAssertNil(event(.prompt, mode: mode).autonomyTag, "prompt \(mode)")
        }
    }

    func test_aTaskOrDirectiveShowsNoAutonomyTag() {
        for kind in [CognitionEventKind.task, .directive] {
            for mode in ["simulate", "observe", "live"] {
                XCTAssertNil(event(kind, mode: mode).autonomyTag, "\(kind) \(mode)")
            }
        }
    }

    func test_aGoalCycleNamesTheAutonomyItRanUnder() {
        XCTAssertEqual(event(.goalCycle, mode: "simulate").autonomyTag, "Simulate")
        XCTAssertEqual(event(.goalCycle, mode: "observe").autonomyTag, "Observe")
        XCTAssertEqual(event(.goalCycle, mode: "live").autonomyTag, "Live")
    }

    func test_aGoalCycleWithAnUnknownOrEmptyModeShowsNoTag() {
        XCTAssertNil(event(.goalCycle, mode: "").autonomyTag)
        XCTAssertNil(event(.goalCycle, mode: "turbo").autonomyTag)
    }

    // The row must read the tag, not the raw mode, or a chat turn shows it again.
    func test_theRowReadsTheTagNotTheRawMode() throws {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            url.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) { break }
        }
        let row = try String(contentsOf: url.appendingPathComponent("Sources/Grux/Jax/Cognition/CognitionEventRow.swift"), encoding: .utf8)
        XCTAssertTrue(row.contains("event.autonomyTag"))
        XCTAssertFalse(row.contains("event.mode"), "the raw autonomy mode is shown on every kind")
    }
}
