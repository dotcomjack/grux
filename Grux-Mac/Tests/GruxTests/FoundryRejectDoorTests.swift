import XCTest
@testable import Grux

// Turn a proposal down without a click: ~/.grux/fire-foundry-reject names a
// proposal by the start of its id, then the reason in plain words. The card's
// Reject has no door on a Mac nobody can click on, so a proposal Grux should
// never have filed (37A54595, D76) sat proposed with no way to say no.
final class FoundryRejectDoorTests: XCTestCase {

    private func proposal(_ id: String, _ title: String, status: ProposalStatus = .proposed) -> UpgradeProposal {
        var p = UpgradeProposal(
            title: title,
            lane: .reliability,
            domain: .mac,
            expectedGain: 0.9,
            riskClass: .low,
            estCostLabel: "$3 estimated",
            tierRequired: .propose,
            readyPrompt: "Fix it."
        )
        p.id = UUID(uuidString: id)!
        p.status = status
        return p
    }

    private lazy var book: [UpgradeProposal] = [
        proposal("37A54595-0000-4000-8000-000000000001", "Swarm job failed: 'Reply with the single word hi'"),
        proposal("78BA18B6-0000-4000-8000-000000000002", "fs-audit gated", status: .accepted),
        proposal("49DD242B-0000-4000-8000-000000000003", "repeated asks", status: .landed),
        proposal("49DD9999-0000-4000-8000-000000000004", "another 49DD", status: .rejected),
    ]

    private func resolve(_ token: String) -> FoundryEngine.RejectRequest {
        FoundryEngine.resolveRejectRequest(token: token, proposals: book)
    }

    func testAProposedProposalIsTurnedDownWithItsReason() {
        XCTAssertEqual(resolve("37a54595 the jobs failed only on Claude's sign-in\n"),
                       .reject(book[0].id, reason: "the jobs failed only on Claude's sign-in"))
        XCTAssertEqual(resolve("37A54595-0000-4000-8000-000000000001\nsign-in only"),
                       .reject(book[0].id, reason: "sign-in only"))
    }

    func testNoReasonIsRefusedWithHowToGiveOne() {
        for token in ["37A54595", "37A54595   \n ", "37A54595\n"] {
            guard case .refuse(let why) = resolve(token) else { return XCTFail("turned down with no reason: '\(token)'") }
            XCTAssertTrue(why.contains("reason"), why)
        }
    }

    func testAnEmptyOrTooShortNameIsRefused() {
        for token in ["", "  \n", "37A because"] {
            guard case .refuse(let why) = resolve(token) else { return XCTFail("turned down from '\(token)'") }
            XCTAssertTrue(why.contains("first 8 characters"), why)
        }
        // Exactly the minimum resolves.
        XCTAssertEqual(resolve("37A5 because"), .reject(book[0].id, reason: "because"))
    }

    func testAnUnknownOrAmbiguousIdIsRefusedNotGuessed() {
        guard case .refuse(let unknown) = resolve("FFFFFFFF no") else { return XCTFail("unknown id") }
        XCTAssertTrue(unknown.contains("no proposal"), unknown)
        guard case .refuse(let two) = resolve("49DD no") else { return XCTFail("guessed between two") }
        XCTAssertTrue(two.contains("2 proposals"), two)
    }

    /// Only a proposal still waiting for a yes or no, the same as the card's
    /// Reject: one accepted, on the rail, landed or already turned down says so.
    func testOnlyAWaitingProposalCanBeTurnedDown() {
        for (token, status) in [("78BA18B6 no", "accepted"), ("49DD242B no", "landed"), ("49DD9999 no", "rejected")] {
            guard case .refuse(let why) = resolve(token) else { return XCTFail("turned down a \(status) proposal") }
            // The status reads as a word in the sentence, not a badge (W19-P3 item 7).
            XCTAssertTrue(why.contains("is \(status), not waiting"), why)
        }
    }

    /// wake.log keeps one line per door: a reason written over several lines
    /// reads as one sentence there and in the timeline (W19-P3 item 6).
    func testAReasonOverSeveralLinesReadsAsOneLine() {
        XCTAssertEqual(resolve("37A54595 the jobs failed\nonly on\r\n\tClaude's   sign-in\n\n"),
                       .reject(book[0].id, reason: "the jobs failed only on Claude's sign-in"))
    }

    /// A reason is a sentence, not a pasted log: at the limit it is kept whole,
    /// one character over is refused with the limit named, never cut short.
    func testAReasonPastTheLimitIsRefusedNotCut() {
        let limit = FoundryEngine.rejectReasonLimit
        XCTAssertEqual(limit, 280)
        let atLimit = String(repeating: "a", count: limit)
        XCTAssertEqual(resolve("37A54595 \(atLimit)"), .reject(book[0].id, reason: atLimit))
        // Whitespace folded before counting: the limit is on what is kept.
        XCTAssertEqual(resolve("37A54595 \(String(atLimit.dropLast(2)))\n\n\nb"),
                       .reject(book[0].id, reason: String(atLimit.dropLast(2)) + " b"))
        guard case .refuse(let why) = resolve("37A54595 \(atLimit)a") else { return XCTFail("kept a reason past the limit") }
        XCTAssertTrue(why.contains("280 characters"), why)
        XCTAssertFalse(why.contains("\n"), why)
    }

    /// The reason is kept where the person reads it: the Self-Upgrade timeline.
    @MainActor
    func testTheCardsRejectKeepsTheReasonInTheTimeline() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("reject-door-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let timeline = FoundryTimelineStore(storageURL: url)
        let model = FoundryDashboardModel(timeline: timeline)
        var hooked: FoundryProposalCardModel?
        model.onReject = { hooked = $0 }
        model.proposals = [FoundryProposalCardModel(id: "p1", title: "Swarm job failed", lane: "reliability", domain: "mac")]
        model.reject(id: "p1", reason: "the jobs failed only on Claude's sign-in")
        XCTAssertEqual(hooked?.id, "p1")
        XCTAssertEqual(timeline.entries.first?.kind, .rejected)
        XCTAssertTrue(timeline.entries.first?.detail.contains("Reason: the jobs failed only on Claude's sign-in.") == true,
                      timeline.entries.first?.detail ?? "no entry")
    }
}
