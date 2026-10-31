import XCTest
@testable import Grux

// F5: at most one Foundry build at a time on a Mac, and none on a nearly full
// disk. An escalated build returns as soon as its swarm starts, so before this
// the next proposal in a cycle (or a Build it press) started a second build
// beside it; buildAndVerify refused only a second build of the SAME proposal.
final class FoundryOneBuildAtATimeTests: XCTestCase {
    private let gb: Int64 = 1_000_000_000
    private let a = UUID(), b = UUID()

    func test_nothingRunningWithRoomBuilds() {
        XCTAssertNil(FoundryEngine.buildHold(building: [], liveEscalations: [:], freeBytes: 9 * gb))
    }

    func test_aBuildOnTheRailHoldsAnother() {
        let hold = FoundryEngine.buildHold(building: [a], liveEscalations: [:], freeBytes: 9 * gb)
        XCTAssertEqual(hold, "not building: another upgrade is building, and one builds at a time on this Mac.")
    }

    func test_aLiveSwarmJobHoldsAnother() {
        let hold = FoundryEngine.buildHold(building: [], liveEscalations: ["job": b], freeBytes: 9 * gb)
        XCTAssertNotNil(hold)
        XCTAssertTrue(hold?.contains("one builds at a time") == true)
    }

    // On, one under and one over the 4 GB floor, in the decimal GB Finder
    // shows (wave 13 P3: the floor was 4 GiB, so 4.2 GB in Finder read
    // "3.9 GB free and a build needs 4 GB").
    func test_theDiskFloorBoundary() {
        XCTAssertNil(FoundryEngine.buildHold(building: [], liveEscalations: [:], freeBytes: 4 * gb))
        XCTAssertNil(FoundryEngine.buildHold(building: [], liveEscalations: [:], freeBytes: 4 * gb + 1))
        XCTAssertEqual(FoundryEngine.buildHold(building: [], liveEscalations: [:], freeBytes: 4 * gb - 1),
                       "not building: this Mac has 3.9 GB free and a build needs 4 GB.")
        XCTAssertEqual(FoundryEngine.minimumFreeBytesToBuild, 4 * gb)
    }

    func test_anUnreadableDiskHolds() {
        XCTAssertEqual(FoundryEngine.buildHold(building: [], liveEscalations: [:], freeBytes: nil),
                       "not building: Grux could not read how much disk space is free.")
    }

    // Wave 13 P3: the proposal that is itself building is named as such, not
    // as "another upgrade".
    func test_theDoorNamesTheProposalThatIsItselfBuilding() {
        var p = UpgradeProposal(title: "t", lane: .codeHealth, domain: .mac, expectedGain: 0.5, riskClass: .low,
                                estCostLabel: "$2 estimated", tierRequired: .propose, readyPrompt: "Fix it.")
        p.status = .accepted
        let request = FoundryEngine.resolveBuildRequest(
            token: String(p.id.uuidString.prefix(8)), proposals: [p], foundryEnabled: true, inFlight: [p.id],
            hold: "not building: another upgrade is building, and one builds at a time on this Mac.")
        XCTAssertEqual(request, .refuse("not building: 't' is already building."))
    }

    // The door says the hold before it accepts anything, so the proposal is
    // still proposed and the line must not say it stays accepted (live, 8:01 PM
    // Oct 29: ABE4CCBE refused while still proposed).
    func test_theDoorRefusesWithTheHold() {
        let p = UpgradeProposal(title: "t", lane: .codeHealth, domain: .mac, expectedGain: 0.5, riskClass: .low,
                                estCostLabel: "$2 estimated", tierRequired: .propose, readyPrompt: "Fix it.")
        let request = FoundryEngine.resolveBuildRequest(
            token: String(p.id.uuidString.prefix(8)), proposals: [p], foundryEnabled: true, inFlight: [],
            hold: "not building: another upgrade is building, and one builds at a time on this Mac.")
        XCTAssertEqual(request, .refuse("not building: another upgrade is building, and one builds at a time on this Mac. Ask again later."))
    }

    // Every build path goes through buildAndVerify, and it asks the hold
    // before it puts anything on the rail; the cycle loop stands down on it.
    func test_theRailAndTheCycleAskTheHold() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/Foundry/FoundryEngine.swift"), encoding: .utf8)
        let rail = try XCTUnwrap(src.range(of: "func buildAndVerify(_ proposal: UpgradeProposal) async {"))
        let body = String(src[rail.upperBound...].prefix(1200))
        let hold = try XCTUnwrap(body.range(of: "currentBuildHold()"))
        let insert = try XCTUnwrap(body.range(of: "building.insert(proposal.id)"))
        XCTAssertLessThan(hold.lowerBound, insert.lowerBound)
        XCTAssertTrue(src.contains("cycle standing down (\\(hold))"))
        // An accepted proposal the rail holds says it waits for the next pass.
        XCTAssertTrue(body.contains("\\(hold) It stays accepted for the next pass."))
    }
}
