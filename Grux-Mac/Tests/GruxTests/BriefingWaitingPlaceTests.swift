import XCTest
@testable import Grux

/// D179 item 1, sense pass 22 (`home-page1.png`, `jaxHQ-page1.png` beside
/// `approvals-2.png`): the briefing said "2 things are waiting for your OK: Save
/// your note ... and security-audit.log: 1059 error-shaped log lines" while the
/// tray's two were the note and "Start a self-upgrade cycle". The composed
/// briefing added Self-Upgrade's proposals to the approvals count, so a person
/// who opened Approvals found something else there. Each line now counts only
/// what waits in one place and says which place.
@MainActor
final class BriefingWaitingPlaceTests: XCTestCase {

    private let note = "Save your note \"The gate code is on the fridge\"."
    private let mail = "Send an email to Sam about Friday"
    private let cycle = "Start a self-upgrade cycle."
    private let audit = "security-audit.log: 1059 error-shaped log lines"

    private func spoken(_ approvals: [String], _ turnedDown: [String] = [], _ proposals: [String]) -> String {
        BriefingEngine.fallbackSpoken(slot: .morning, items:
            BriefingEngine.waitingItems(approvals: approvals, turnedDown: turnedDown, proposals: proposals))
    }

    /// The live case: one approval, one turned down, one proposal.
    func test_theLiveBriefingCountsOnlyWhatTheTrayHolds() {
        let text = spoken([note], [cycle], [audit])
        XCTAssertTrue(text.contains("1 thing is waiting for your OK in Approvals: Save your note \"The gate code is on the fridge\"."), text)
        XCTAssertTrue(text.contains("1 self-upgrade proposal is waiting for your review in Self-Upgrade: security-audit.log: 1059 error-shaped log lines."), text)
        XCTAssertTrue(text.contains("Start a self-upgrade cycle is in Approvals too, but it would be turned down if approved now; its card says why."), text)
        XCTAssertFalse(text.contains("2 things"), text)
    }

    /// On, under and over: zero, one and two of each, in every pairing.
    func test_eachPlaceIsCountedApartAtEveryCount() {
        let approvalSets: [[String]] = [[], [note], [note, mail]]
        let proposalSets: [[String]] = [[], ["Open chat faster"], ["Open chat faster", "Trim the log"]]
        for a in approvalSets {
            for p in proposalSets {
                let text = spoken(a, [], p)
                let ok = text.components(separatedBy: "waiting for your OK").count - 1
                let review = text.components(separatedBy: "waiting for your review").count - 1
                XCTAssertEqual(ok, a.isEmpty ? 0 : 1, "\(a.count) + \(p.count): \(text)")
                XCTAssertEqual(review, p.isEmpty ? 0 : 1, "\(a.count) + \(p.count): \(text)")
                switch a.count {
                case 1: XCTAssertTrue(text.contains("1 thing is waiting for your OK in Approvals: Save your note"), text)
                case 2: XCTAssertTrue(text.contains("2 things are waiting for your OK in Approvals: Save your note \"The gate code is on the fridge\" and Send an email to Sam about Friday."), text)
                default: break
                }
                switch p.count {
                case 1: XCTAssertTrue(text.contains("1 self-upgrade proposal is waiting for your review in Self-Upgrade: Open chat faster."), text)
                case 2: XCTAssertTrue(text.contains("2 self-upgrade proposals are waiting for your review in Self-Upgrade: Open chat faster and Trim the log."), text)
                default: break
                }
                // An approval title never lands on the proposal line, nor the reverse.
                if let reviewLine = text.components(separatedBy: ". ").first(where: { $0.contains("waiting for your review") }) {
                    XCTAssertFalse(reviewLine.contains("Save your note"), text)
                }
                XCTAssertEqual(text.hasSuffix(BriefingEngine.quietFallbackLine), a.isEmpty && p.isEmpty, text)
                XCTAssertNil(BriefingEngine.overclaim(text, sources: BriefingSources(mail: true, calendar: true, ops: true)), text)
            }
        }
    }

    /// A proposal row saved before the count existed stands for one proposal.
    func test_anOldProposalRowStandsForOne() {
        let old = [BriefingItem(kind: .proposalPending, title: "1 self-upgrade proposal")]
        let text = BriefingEngine.fallbackSpoken(slot: .morning, items: old)
        XCTAssertTrue(text.contains("1 self-upgrade proposal is waiting for your review in Self-Upgrade."), text)
        XCTAssertFalse(text.contains("waiting for your OK"), text)
    }
}

/// Wave 61 review round 1: the same split for the briefing a model drafts
/// (cloud and custom routes), and the turned-down line's "too".
@MainActor
final class BriefingWaitingPlaceRound2Tests: XCTestCase {

    private let note = "Save your note \"The gate code is on the fridge\"."
    private let cycle = "Start a self-upgrade cycle."
    private let audit = "security-audit.log: 1059 error-shaped log lines"

    /// P2: the model was handed approvals and proposals under one
    /// "WAITING_FOR_YOUR_OK (approvals + self-upgrade proposals)" heading.
    func test_theDraftingModelIsHandedEachPlaceApart() throws {
        let items = BriefingEngine.waitingItems(approvals: [note], turnedDown: [cycle], proposals: [audit])
        let text = BriefingEngine.waitingPromptSections(items)
        let ok = try XCTUnwrap(text.range(of: "WAITING_FOR_YOUR_OK_IN_APPROVALS"))
        let review = try XCTUnwrap(text.range(of: "SELF_UPGRADE_PROPOSALS_FOR_REVIEW"))
        let down = try XCTUnwrap(text.range(of: "TURNED_DOWN_IF_APPROVED"))
        let okSection = String(text[ok.upperBound..<review.lowerBound])
        let reviewSection = String(text[review.upperBound..<down.lowerBound])
        XCTAssertTrue(okSection.contains("Save your note"), okSection)
        XCTAssertFalse(okSection.contains("security-audit"), okSection)
        XCTAssertTrue(reviewSection.contains("security-audit"), reviewSection)
        XCTAssertTrue(reviewSection.contains("never count these as waiting for an OK"), reviewSection)
        XCTAssertTrue(String(text[down.upperBound...]).contains("Start a self-upgrade cycle"), text)
        let src = try String(contentsOfFile: #filePath.replacingOccurrences(
            of: "Tests/GruxTests/BriefingWaitingPlaceTests.swift",
            with: "Sources/Grux/Jax/BriefingEngine.swift"), encoding: .utf8)
        XCTAssertFalse(src.contains("approvals + self-upgrade proposals"), "a second, merged heading is still in the prompt")
        XCTAssertTrue(src.contains("\\(Self.waitingPromptSections(items))"), "the drafted prompt uses the tested sections")
    }

    /// P3: "too" said only after an approvals line, never after a Self-Upgrade
    /// line or the quiet line.
    func test_tooFollowsOnlyAnApprovalsLine() {
        func spoken(_ a: [String], _ p: [String]) -> String {
            BriefingEngine.fallbackSpoken(slot: .morning, items:
                BriefingEngine.waitingItems(approvals: a, turnedDown: [cycle], proposals: p))
        }
        XCTAssertTrue(spoken([note], []).contains("Start a self-upgrade cycle is in Approvals too, but"))
        XCTAssertTrue(spoken([note], [audit]).contains("Start a self-upgrade cycle is in Approvals too, but"))
        for text in [spoken([], [audit]), spoken([], [])] {
            XCTAssertFalse(text.contains(" too,"), text)
            XCTAssertTrue(text.contains("Start a self-upgrade cycle is in Approvals, but it would be turned down if approved now; its card says why."), text)
        }
        let two = BriefingEngine.fallbackSpoken(slot: .morning, items:
            BriefingEngine.waitingItems(approvals: [], turnedDown: [cycle, "B."], proposals: []))
        XCTAssertTrue(two.contains("Start a self-upgrade cycle and B are in Approvals, but they would be turned down if approved now; their cards say why."), two)
    }
}
