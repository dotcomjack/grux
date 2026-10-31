import XCTest
@testable import Grux

/// D46: the Approvals tray on the Mini read "2 waiting" every day for a month,
/// two cards saying the same "Save your note "The gate code is on the fridge"."
/// asked 59 seconds apart in chat on 2026-09-28, each held with "Not clearly
/// routine and reversible. Pausing for your call." (`logs/s3-shots/approvals-2.png`).
/// The hold itself is the gate's deliberate fail safe and stays; what a person
/// reads changes: one card per thing asked, saying plainly why it waits.
@MainActor
final class ApprovalAskOnceTests: XCTestCase {

    private func tempURL() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("approval-once-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("approvals.json")
    }

    private func noteSave(_ title: String = "The gate code is on the fridge") -> ProposedAction {
        ProposedAction(kind: .other, summary: "Run tool 'create_note' (unclassified side effect).",
                       target: "create_note",
                       detail: ["tool": "create_note", "__replay_tool": "create_note",
                                "__replay_input": "{\"title\":\"\(title)\",\"body\":\"\(title.lowercased())\"}"])
    }

    private func queued(_ action: ProposedAction) throws -> PendingApproval {
        var held: PendingApproval?
        if case .queueForApproval(let item) = DecisionGate.shared.evaluate(action) { held = item }
        return try XCTUnwrap(held, "a note save is held for the person's OK")
    }

    // MARK: - Why it waits, in plain words

    func test_aNoteSaveSaysPlainlyWhyItWaits() throws {
        let item = try queued(noteSave())
        XCTAssertEqual(item.reason, DecisionGate.asksFirstReason)
        XCTAssertEqual(item.reason, "This waits for your OK before it runs.")
        XCTAssertFalse(item.reason.contains("routine"), item.reason)
    }

    /// Cards already on disk carry the old sentence. Every reader (the tray,
    /// the urgent banner, the grux_approvals tool and, once the app has saved,
    /// `grux approvals`) reads the item, so the item is what changes.
    func test_aStoredOldReasonReadsTheNewWayAndIsSavedSo() throws {
        let url = tempURL()
        let legacy = """
        [{"id":"C017EA5A-6BBD-41DF-ABBA-73933836C436","createdAt":"2026-09-28T08:40:26Z","state":"pending",
          "reason":"Not clearly routine and reversible. Pausing for your call.","urgent":false,"persona":"none",
          "action":{"id":"DACD9689-0B96-4B96-9BD4-C2561225CC6A","kind":"other","summary":"Save your note.",
                    "target":"create_note","detail":{"tool":"create_note"},"isSpend":false,"isExternalComms":false,
                    "isPublicPost":false,"touchesSecrets":false}}]
        """
        try Data(legacy.utf8).write(to: url)
        let queue = ApprovalQueue(storeURL: url)
        XCTAssertEqual(queue.pending.first?.reason, DecisionGate.asksFirstReason)
        let onDisk = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(onDisk.contains("Not clearly routine"), "the file is the CLI's queue too")
    }

    /// Any other reason is the gate's own words for that item and stays as written.
    func test_anyOtherReasonIsLeftAlone() throws {
        let url = tempURL()
        let queue = ApprovalQueue(storeURL: url)
        queue.judgeRisk = nil
        let spend = queue.enqueue(ProposedAction(kind: .spend, summary: "Spend $50.", target: "ads"),
                                  urgent: false, reason: "Spend may only be approved by you.")
        XCTAssertEqual(ApprovalQueue(storeURL: url).items.first { $0.id == spend.id }?.reason,
                       "Spend may only be approved by you.")
    }

    // MARK: - One card per thing asked

    func test_askingTheSameThingTwiceWaitsOnce() throws {
        let queue = ApprovalQueue(storeURL: tempURL())
        queue.judgeRisk = nil
        let first = queue.enqueue(try queued(noteSave()))
        let second = queue.enqueue(try queued(noteSave()))
        XCTAssertEqual(queue.pendingCount, 1)
        XCTAssertEqual(second.id, first.id, "the caller is told about the card already waiting")
    }

    /// Off by one in the other direction: a different note is a different ask.
    func test_aDifferentAskStillWaitsOnItsOwn() throws {
        let queue = ApprovalQueue(storeURL: tempURL())
        queue.judgeRisk = nil
        queue.enqueue(try queued(noteSave("The gate code is on the fridge")))
        queue.enqueue(try queued(noteSave("The gate code is in the drawer")))
        XCTAssertEqual(queue.pendingCount, 2)
    }

    /// Answered asks do not swallow a new one: once the first is approved or
    /// skipped, asking again is a new card.
    func test_anAnsweredAskDoesNotSwallowANewOne() throws {
        let queue = ApprovalQueue(storeURL: tempURL())
        queue.judgeRisk = nil
        let first = queue.enqueue(try queued(noteSave()))
        queue.skip(first.id)
        let again = queue.enqueue(try queued(noteSave()))
        XCTAssertNotEqual(again.id, first.id)
        XCTAssertEqual(queue.pendingCount, 1)
    }

    /// Who was told "pending" is not part of the ask: the same save asked in
    /// chat and from elsewhere is one card, and chat still hears the outcome.
    func test_theSameAskFromChatAndElsewhereIsOneCardThatTellsChat() throws {
        let queue = ApprovalQueue(storeURL: tempURL())
        queue.judgeRisk = nil
        let quiet = queue.enqueue(try queued(noteSave()))
        var fromChat = try queued(noteSave())
        fromChat.action.detail[ApprovalQueue.askedInKey] = ApprovalQueue.askedInChat
        queue.enqueue(fromChat)
        XCTAssertEqual(queue.pendingCount, 1)
        XCTAssertEqual(queue.items.first { $0.id == quiet.id }?.action.detail[ApprovalQueue.askedInKey],
                       ApprovalQueue.askedInChat)
    }

    /// Money and outbound messages are never folded: two identical payments
    /// may be two payments, and each must be its own tap. Queued not urgent
    /// here only because an urgent item posts a banner, which xctest cannot;
    /// folding goes by kind, never by urgency.
    func test_spendAndOutboundAsksAreNeverFolded() {
        let queue = ApprovalQueue(storeURL: tempURL())
        queue.judgeRisk = nil
        let pay = ProposedAction(kind: .spend, summary: "Spend $50 on ads.", target: "ads", isSpend: true)
        queue.enqueue(pay)
        queue.enqueue(pay)
        let mail = ProposedAction(kind: .externalComms, summary: "Email Sam.", target: "sam@example.com",
                                  isExternalComms: true)
        queue.enqueue(mail)
        queue.enqueue(mail)
        XCTAssertEqual(queue.pendingCount, 4)
    }

    /// Wave 12 review P2: a tool nobody classified is declared kind other, and
    /// the gate still holds it as a spend when its words read as one. Two
    /// identical charges asked are two cards. Only the residual hold folds.
    func test_aSpendTheGateHeldFromAnUnclassifiedToolIsNeverFolded() throws {
        let charge = ProposedAction(kind: .other, summary: "Run tool 'stripe_create_charge' (unclassified side effect).",
                                    target: "stripe_create_charge",
                                    detail: ["tool": "stripe_create_charge", "__replay_tool": "stripe_create_charge",
                                             "__replay_input": "{\"amount\":5000}"])
        var held: PendingApproval?
        if case .queueForApproval(let item) = DecisionGate.shared.evaluate(charge) { held = item }
        let item = try XCTUnwrap(held)
        XCTAssertNotEqual(item.reason, DecisionGate.asksFirstReason, "the gate held it as a spend")
        XCTAssertNil(ApprovalQueue.sameAskKey(item), "a spend hold has no fold key")
        // Queued not urgent only because an urgent enqueue posts a banner,
        // which xctest cannot; the spend reason alone must keep them apart.
        var quiet = item
        quiet.urgent = false
        let queue = ApprovalQueue(storeURL: tempURL())
        queue.judgeRisk = nil
        queue.enqueue(quiet)
        queue.enqueue(PendingApproval(action: quiet.action, urgent: false, reason: quiet.reason))
        XCTAssertEqual(queue.pendingCount, 2)
    }

    /// Wave 12 review P2: an urgent ask that folded posted no banner, so a
    /// voice ask-first said twice showed nothing the second time. Urgent
    /// items never fold.
    func test_anUrgentAskNeverFolds() throws {
        let urgent = PendingApproval(action: noteSave(), urgent: true, reason: DecisionGate.asksFirstReason)
        XCTAssertNil(ApprovalQueue.sameAskKey(urgent))
        let url = tempURL()
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try enc.encode([urgent, PendingApproval(action: noteSave(), urgent: true, reason: DecisionGate.asksFirstReason)])
            .write(to: url)
        XCTAssertEqual(ApprovalQueue(storeURL: url).pendingCount, 2)
    }

    /// Wave 12 round 2 P2: a tool nobody classified reaches the gate as an
    /// opaque "Run tool" with its input stamped only after the verdict, so a
    /// residual hold says nothing about whether it sends or pays. An MCP
    /// `send_email` asked twice is two cards, and so is anything not on the
    /// short list of tools that only write this Mac's own notes and contacts.
    func test_aToolNotKnownToStayOnThisMacNeverFolds() throws {
        // update_note (wave 12 round 3): an append is not idempotent, so the
        // same line asked to be added on Monday and again on Wednesday is two.
        for tool in ["mcp_gmail_send_email", "mcp_stripe_create_payment_intent", "shell_run", "deep_research", "create_event",
                     "update_note"] {
            let fallback = ProposedAction(kind: .other, summary: "Run tool '\(tool)' (unclassified side effect).",
                                          target: tool, detail: ["tool": tool])
            var held: PendingApproval?
            if case .queueForApproval(var item) = DecisionGate.shared.evaluate(fallback) {
                item.action.detail["__replay_tool"] = tool
                item.action.detail["__replay_input"] = "{\"to\":\"bob@x.com\",\"body\":\"Running late\"}"
                held = item
            }
            let item = try XCTUnwrap(held, tool)
            XCTAssertEqual(item.reason, DecisionGate.asksFirstReason, "\(tool) is the residual hold this guards")
            XCTAssertNil(ApprovalQueue.sameAskKey(item), "\(tool) got a fold key")
            let queue = ApprovalQueue(storeURL: tempURL())
            queue.judgeRisk = nil
            queue.enqueue(item)
            queue.enqueue(PendingApproval(action: item.action, reason: item.reason))
            XCTAssertEqual(queue.pendingCount, 2, tool)
        }
    }

    /// The replay input is written in whatever key order the process hashed,
    /// so the same note asked in two sessions reads as the same ask.
    func test_theSameNoteWithItsInputInAnotherKeyOrderIsTheSameAsk() throws {
        var a = try queued(noteSave())
        var b = try queued(noteSave())
        a.action.detail["__replay_input"] = "{\"title\":\"Milk\",\"body\":\"milk\"}"
        b.action.detail["__replay_input"] = "{\"body\":\"milk\",\"title\":\"Milk\"}"
        XCTAssertNotNil(ApprovalQueue.sameAskKey(a))
        XCTAssertEqual(ApprovalQueue.sameAskKey(a), ApprovalQueue.sameAskKey(b))
    }

    /// Any hold the gate wrote other words for keeps its own card.
    func test_onlyTheResidualHoldFolds() throws {
        let queue = ApprovalQueue(storeURL: tempURL())
        queue.judgeRisk = nil
        queue.enqueue(noteSave(), reason: "A goal step wants to save this.")
        queue.enqueue(noteSave(), reason: "A goal step wants to save this.")
        XCTAssertEqual(queue.pendingCount, 2)
    }

    /// A twin judged high risk passes the flag to the card kept (wave 12 P3).
    func test_aFoldedTwinsRiskFlagIsKept() throws {
        let queue = ApprovalQueue(storeURL: tempURL())
        queue.judgeRisk = nil
        let first = queue.enqueue(try queued(noteSave()))
        var judged = try queued(noteSave())
        judged.risk = ApprovalRisk(score: 2, confidence: 0.98, raised: true)
        queue.enqueue(judged)
        XCTAssertEqual(queue.pendingCount, 1)
        XCTAssertEqual(queue.items.first { $0.id == first.id }?.risk?.raised, true)
    }

    /// The Mini's own file: two identical saves already waiting read as one,
    /// the older card kept (its age is when it was first asked).
    func test_twoIdenticalCardsAlreadyWaitingLoadAsOne() throws {
        let url = tempURL()
        let a = PendingApproval(action: noteSave(), createdAt: Date(timeIntervalSince1970: 1_790_000_000),
                                reason: DecisionGate.asksFirstReason)
        var b = PendingApproval(action: noteSave(), createdAt: Date(timeIntervalSince1970: 1_790_000_059),
                                reason: DecisionGate.asksFirstReason)
        b.action.detail[ApprovalQueue.askedInKey] = ApprovalQueue.askedInChat
        let other = PendingApproval(action: noteSave("Milk"), reason: DecisionGate.asksFirstReason)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try enc.encode([a, b, other]).write(to: url)

        let queue = ApprovalQueue(storeURL: url)
        XCTAssertEqual(queue.pendingCount, 2)
        let kept = try XCTUnwrap(queue.pending.first { $0.action.target == "create_note" && $0.id != other.id })
        XCTAssertEqual(kept.id, a.id, "the first ask is the one kept")
        XCTAssertEqual(kept.action.detail[ApprovalQueue.askedInKey], ApprovalQueue.askedInChat)
        XCTAssertEqual(ApprovalQueue(storeURL: url).pendingCount, 2, "and the file says so")
    }
}
