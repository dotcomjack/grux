import XCTest
@testable import Grux

final class ToolRelevanceTests: XCTestCase {
    private func tool(_ name: String) -> ClaudeTool { ClaudeTool(name: name, description: "", inputSchema: [:]) }

    func test_askingTheTime_ridesCoreOnly() {
        let g = ToolRelevance.groups(for: .init(utterance: "what time is it right now?"))
        XCTAssertEqual(g, [.core])
    }

    func test_codeShapedTurn_bringsDeveloperTools() {
        let g = ToolRelevance.groups(for: .init(utterance: "ship the iOS app"))
        XCTAssertTrue(g.contains(.developer))
        XCTAssertFalse(g.contains(.meetings))
    }

    func test_recentToolUse_keepsItsGroupAcrossTurns() {
        let g = ToolRelevance.groups(for: .init(utterance: "try again", recentToolNames: ["ios_build_verify"]))
        XCTAssertTrue(g.contains(.developer))
    }

    func test_emptyUtterance_ridesEverything() {
        XCTAssertEqual(ToolRelevance.groups(for: .init(utterance: " ")), Set(ToolRelevance.Group.allCases))
    }

    func test_filter_dropsHeavyGroupsAndKeepsCore() {
        let tools = [tool("add_task"), tool("control_screen"), tool("agent_swarm_start"), tool("start_meeting_capture"), tool("search_web")]
        let kept = ToolRelevance.filter(tools, signals: .init(utterance: "add a task to call the bank")).map(\.name)
        XCTAssertEqual(kept, ["add_task", "search_web"])
    }

    func test_everyKnownToolPrefix_hasAGroup() {
        XCTAssertEqual(ToolRelevance.group(for: "ios_scaffold"), .developer)
        XCTAssertEqual(ToolRelevance.group(for: "enroll_speaker_from_meeting"), .meetings)
        XCTAssertEqual(ToolRelevance.group(for: "deep_research"), .research)
        XCTAssertEqual(ToolRelevance.group(for: "slack_send"), .export)
        XCTAssertEqual(ToolRelevance.group(for: "creative_render_image"), .creative)
        XCTAssertEqual(ToolRelevance.group(for: "read_screen"), .screen)
        XCTAssertEqual(ToolRelevance.group(for: "fs_read"), .core)
    }

    @MainActor
    func test_recentToolUse_forgetsAfterTheWindow() {
        let r = RecentToolUse()
        r.record("ios_scaffold", at: Date(timeIntervalSinceNow: -20 * 60))
        r.record("add_task")
        XCTAssertEqual(r.names(), ["add_task"])
    }
}
