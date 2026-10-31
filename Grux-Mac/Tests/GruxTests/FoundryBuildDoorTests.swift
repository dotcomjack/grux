import XCTest
@testable import Grux

// Build it without a click: ~/.grux/fire-foundry-build names a proposal by the
// start of its id, and the engine decides from plain values whether that is a
// build, and of which proposal, or a refusal that says why.
final class FoundryBuildDoorTests: XCTestCase {

    private func proposal(_ id: String, _ title: String, status: ProposalStatus = .proposed) -> UpgradeProposal {
        var p = UpgradeProposal(
            title: title,
            lane: .codeHealth,
            domain: .mac,
            expectedGain: 0.5,
            riskClass: .low,
            estCostLabel: "$2 estimated",
            tierRequired: .propose,
            readyPrompt: "Fix it."
        )
        p.id = UUID(uuidString: id)!
        p.status = status
        return p
    }

    private lazy var book: [UpgradeProposal] = [
        proposal("2024E176-0000-4000-8000-000000000001", "security-audit.log errors"),
        proposal("78BA18B6-0000-4000-8000-000000000002", "fs-audit gated", status: .accepted),
        proposal("49DD242B-0000-4000-8000-000000000003", "repeated asks", status: .landed),
        proposal("49DD9999-0000-4000-8000-000000000004", "another 49DD", status: .rejected),
    ]

    private func resolve(_ token: String, enabled: Bool = true, inFlight: Set<UUID> = []) -> FoundryEngine.BuildRequest {
        FoundryEngine.resolveBuildRequest(token: token, proposals: book, foundryEnabled: enabled, inFlight: inFlight)
    }

    func testAProposedProposalNamedByItsIdPrefixBuilds() {
        XCTAssertEqual(resolve("2024e176\n"), .build(book[0].id))
    }

    func testAnAcceptedProposalWhoseBuildNeverRanBuilds() {
        XCTAssertEqual(resolve("78BA18B6"), .build(book[1].id))
    }

    func testTheWholeIdWorksToo() {
        XCTAssertEqual(resolve("2024E176-0000-4000-8000-000000000001"), .build(book[0].id))
    }

    func testNothingBuildsWhileSelfUpgradeIsOff() {
        guard case .refuse(let why) = resolve("2024E176", enabled: false) else { return XCTFail("built while off") }
        XCTAssertTrue(why.contains("self-upgrade is off"), why)
    }

    func testAnEmptyOrTooShortNameIsRefusedWithHowToName() {
        for token in ["", "  \n", "202"] {
            guard case .refuse(let why) = resolve(token) else { return XCTFail("built from '\(token)'") }
            XCTAssertTrue(why.contains("first 8 characters"), why)
        }
        // Exactly the minimum resolves.
        XCTAssertEqual(resolve("2024"), .build(book[0].id))
    }

    func testAnUnknownIdIsRefused() {
        guard case .refuse(let why) = resolve("FFFFFFFF") else { return XCTFail("built an unknown id") }
        XCTAssertTrue(why.contains("no proposal"), why)
    }

    func testAnAmbiguousPrefixIsRefusedNotGuessed() {
        guard case .refuse(let why) = resolve("49DD") else { return XCTFail("guessed between two") }
        XCTAssertTrue(why.contains("2 proposals"), why)
    }

    func testASettledProposalIsNotBuiltAgain() {
        guard case .refuse(let why) = resolve("49DD242B") else { return XCTFail("rebuilt a landed proposal") }
        XCTAssertTrue(why.contains("Landed"), why)
    }

    func testNothingBuildsWhileTheTestBaselineIsBeingMeasured() {
        let r = FoundryEngine.resolveBuildRequest(token: "2024E176", proposals: book, foundryEnabled: true,
                                                  inFlight: [], baselineMeasuring: true)
        guard case .refuse(let why) = r else { return XCTFail("built during a measure") }
        XCTAssertTrue(why.contains("measured"), why)
    }

    func testAProposalAlreadyOnTheRailIsNotKickedTwice() {
        guard case .refuse(let why) = resolve("2024E176", inFlight: [book[0].id]) else { return XCTFail("double kick") }
        XCTAssertTrue(why.contains("already building"), why)
    }
}
