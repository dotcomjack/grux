import XCTest
@testable import Grux

/// D143: the briefing told the model "2 waiting for your OK (Jax HQ approval
/// queue)" and nothing about what was waiting, so a draft guessed. Live
/// 2026-11-02 5:46 PM, qwen3.5:4b called two waiting approvals "a spend
/// request and a system upgrade proposal". The briefing now carries each
/// waiting title, as the approval card shows it, to the model, the row and the
/// composed fallback.
@MainActor
final class BriefingWaitingTitlesTests: XCTestCase {

    private let note = "Save your note \"The gate code is on the fridge\"."
    private let mail = "Send an email to Sam about Friday"

    func test_eachWaitingRowCarriesTheTitlesItStandsFor() {
        let items = BriefingEngine.waitingItems(approvals: [note, mail], proposals: ["Open chat faster"])
        XCTAssertEqual(items.map(\.kind), [.approvalPending, .proposalPending])
        XCTAssertEqual(items[0].title, "2 waiting for your OK")
        XCTAssertEqual(items[0].count, 2)
        XCTAssertEqual(items[0].names, [note, mail])
        XCTAssertEqual(items[0].detail, "Save your note \"The gate code is on the fridge\" and Send an email to Sam about Friday")
        XCTAssertEqual(items[1].title, "1 self-upgrade proposal")
        XCTAssertEqual(items[1].count, 1)
        XCTAssertEqual(items[1].names, ["Open chat faster"])
        XCTAssertEqual(items[1].detail, "Open chat faster")
        XCTAssertEqual(BriefingEngine.waitingItems(approvals: [], proposals: []), [])
    }

    func test_theModelIsHandedEachWaitingTitle() {
        let items = BriefingEngine.waitingItems(approvals: [note, mail], proposals: ["Open chat faster"])
        let lines = BriefingEngine.sourceLines(items, connected: true)
        XCTAssertTrue(lines.contains("- 2 waiting for your OK:\n  - Save your note \"The gate code is on the fridge\"\n  - Send an email to Sam about Friday"), lines)
        XCTAssertTrue(lines.contains("- 1 self-upgrade proposal:\n  - Open chat faster"), lines)
        XCTAssertFalse(lines.contains("Jax HQ approval queue"), "the queue's name says nothing about what waits")
    }

    /// On, under and over the five titles the prompt names.
    func test_thePromptNamesFiveAndCountsTheRest() {
        for n in [4, 5, 6, 7] {
            let titles = (1...n).map { "Approval number \($0)" }
            let lines = BriefingEngine.sourceLines(BriefingEngine.waitingItems(approvals: titles, proposals: []), connected: true)
            for i in 1...min(n, 5) { XCTAssertTrue(lines.contains("  - Approval number \(i)\n") || lines.hasSuffix("  - Approval number \(i)"), "\(n): \(lines)") }
            if n > 5 {
                XCTAssertFalse(lines.contains("Approval number 6"), lines)
                XCTAssertTrue(lines.hasSuffix("  - and \(n - 5) more"), lines)
            } else {
                XCTAssertFalse(lines.contains("more"), lines)
            }
        }
    }

    func test_theComposedBriefingNamesWhatWaits() {
        let one = BriefingEngine.waitingItems(approvals: [note], proposals: [])
        XCTAssertTrue(BriefingEngine.fallbackSpoken(slot: .morning, items: one)
            .contains("1 thing is waiting for your OK in Approvals: Save your note \"The gate code is on the fridge\"."))

        let two = BriefingEngine.waitingItems(approvals: [note], proposals: ["Open chat faster"])
        XCTAssertTrue(BriefingEngine.fallbackSpoken(slot: .morning, items: two)
            .contains("1 thing is waiting for your OK in Approvals: Save your note \"The gate code is on the fridge\". 1 self-upgrade proposal is waiting for your review in Self-Upgrade: Open chat faster."))

        let three = BriefingEngine.waitingItems(approvals: [note, mail], proposals: ["Open chat faster"])
        XCTAssertTrue(BriefingEngine.fallbackSpoken(slot: .morning, items: three)
            .contains("2 things are waiting for your OK in Approvals: Save your note \"The gate code is on the fridge\" and Send an email to Sam about Friday. 1 self-upgrade proposal is waiting for your review in Self-Upgrade: Open chat faster."))
    }

    /// An approval with no summary still counts, and is never named as blank.
    func test_aBlankTitleCountsButIsNotNamed() {
        let items = BriefingEngine.waitingItems(approvals: ["  ", mail], proposals: [])
        XCTAssertEqual(items[0].count, 2)
        XCTAssertEqual(items[0].names, [mail])
        XCTAssertTrue(BriefingEngine.fallbackSpoken(slot: .morning, items: items)
            .contains("2 things are waiting for your OK in Approvals: Send an email to Sam about Friday, and 1 more."))
        let lines = BriefingEngine.sourceLines(items, connected: true)
        XCTAssertTrue(lines.hasSuffix("  - Send an email to Sam about Friday\n  - and 1 more"), lines)
    }

    func test_theTitlesAreWhatTheQueueSaysIsWaiting() {
        let queue = ApprovalQueue.shared
        queue.judgeRisk = nil
        let marker = UUID().uuidString.prefix(8)
        let waiting = queue.enqueue(ProposedAction(kind: .other, summary: "D143 waiting \(marker)", target: "d143-a", detail: [:]))
        let skipped = queue.enqueue(ProposedAction(kind: .other, summary: "D143 skipped \(marker)", target: "d143-b", detail: [:]))
        defer { queue.skip(waiting.id) }
        queue.skip(skipped.id)
        let titles = JaxApprovalCount.titles()
        XCTAssertTrue(titles.contains("D143 waiting \(marker)"), "\(titles)")
        XCTAssertFalse(titles.contains("D143 skipped \(marker)"), "\(titles)")
        XCTAssertEqual(titles.count, JaxApprovalCount.pending())
    }

    /// A briefing saved before titles existed still reads.
    func test_anOldBriefingStillDecodes() throws {
        let json = #"{"id":"2F1C7B5E-6C0A-4D7B-9F43-8E2A1F3B9C11","kind":"approvalPending","title":"2 waiting for your OK","detail":"Jax HQ approval queue","count":2}"#
        let item = try JSONDecoder().decode(BriefingItem.self, from: Data(json.utf8))
        XCTAssertNil(item.names)
        XCTAssertTrue(BriefingEngine.fallbackSpoken(slot: .morning, items: [item]).contains("2 things are waiting for your OK in Approvals."))
    }
}
