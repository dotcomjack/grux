import XCTest
@testable import Grux

final class ClaudeSessionSlotMapperTests: XCTestCase {

    private func snapshot(id: String, title: String = "proj") -> ClaudeSessionSnapshot {
        ClaudeSessionSnapshot(
            sessionId: id,
            cwd: "/p",
            gitBranch: "main",
            title: title,
            lastMessageAt: Date(),
            currentTool: nil,
            totalInputTokens: 0,
            totalOutputTokens: 0,
            totalCacheReadTokens: 0,
            totalCacheCreationTokens: 0,
            totalCostUSD: 0,
            lastAssistantSummary: "",
            model: "claude-haiku-4-5"
        )
    }

    // MARK: - map()

    func testEmptyMappingProducesEmptyResult() {
        let out = ClaudeSessionSlotMapper.map(mapping: .empty, snapshots: ["a": snapshot(id: "a")])
        XCTAssertTrue(out.isEmpty)
    }

    func testPartialMappingOnlyFillsAssignedCorners() {
        var mapping = SlotMapping.empty
        mapping.topLeft = "a"
        mapping.bottomRight = "b"
        let snapshots = [
            "a": snapshot(id: "a", title: "A"),
            "b": snapshot(id: "b", title: "B")
        ]
        let out = ClaudeSessionSlotMapper.map(mapping: mapping, snapshots: snapshots)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[.topLeft]?.title, "A")
        XCTAssertEqual(out[.bottomRight]?.title, "B")
        XCTAssertNil(out[.topRight])
        XCTAssertNil(out[.bottomLeft])
    }

    func testFullMappingFillsAllCorners() {
        let mapping = SlotMapping(topLeft: "a", topRight: "b", bottomLeft: "c", bottomRight: "d")
        let snapshots = ["a", "b", "c", "d"].reduce(into: [:]) { $0[$1] = snapshot(id: $1, title: $1.uppercased()) }
        let out = ClaudeSessionSlotMapper.map(mapping: mapping, snapshots: snapshots)
        XCTAssertEqual(out.count, 4)
        XCTAssertEqual(out[.topLeft]?.title, "A")
        XCTAssertEqual(out[.topRight]?.title, "B")
        XCTAssertEqual(out[.bottomLeft]?.title, "C")
        XCTAssertEqual(out[.bottomRight]?.title, "D")
    }

    func testStaleMappingToMissingSessionIsDroppedSilently() {
        var mapping = SlotMapping.empty
        mapping.topLeft = "ghost"
        mapping.topRight = "real"
        let snapshots = ["real": snapshot(id: "real")]
        let out = ClaudeSessionSlotMapper.map(mapping: mapping, snapshots: snapshots)
        XCTAssertEqual(out.count, 1)
        XCTAssertNil(out[.topLeft])
        XCTAssertEqual(out[.topRight]?.sessionId, "real")
    }

    // MARK: - SlotMapping helpers

    func testSlotMappingSetAndGetPerCorner() {
        var m = SlotMapping.empty
        for corner in OverlayCorner.allCases {
            m.set("s-\(corner.rawValue)", for: corner)
        }
        for corner in OverlayCorner.allCases {
            XCTAssertEqual(m.sessionId(for: corner), "s-\(corner.rawValue)")
        }
    }

    func testSlotMappingClearingACorner() {
        var m = SlotMapping(topLeft: "a", topRight: "b", bottomLeft: nil, bottomRight: nil)
        m.set(nil, for: .topLeft)
        XCTAssertNil(m.sessionId(for: .topLeft))
        XCTAssertEqual(m.sessionId(for: .topRight), "b")
    }

    func testSlotMappingAssignedListSkipsNils() {
        let m = SlotMapping(topLeft: "a", topRight: nil, bottomLeft: "c", bottomRight: nil)
        let pairs = m.assigned
        XCTAssertEqual(pairs.count, 2)
        XCTAssertEqual(pairs[0].0, .topLeft)
        XCTAssertEqual(pairs[0].1, "a")
        XCTAssertEqual(pairs[1].0, .bottomLeft)
        XCTAssertEqual(pairs[1].1, "c")
    }

    func testSlotMappingRoundTripsViaJSON() throws {
        let original = SlotMapping(topLeft: "a", topRight: "b", bottomLeft: nil, bottomRight: "d")
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SlotMapping.self, from: encoded)
        XCTAssertEqual(decoded, original)
    }
}
