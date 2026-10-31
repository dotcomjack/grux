import XCTest
@testable import Grux

/// D73: a Goal Pursuit card showed `run_approval_runner --queue-id=hq-01
/// --item-ids=item-8492,item-3301` and "2 items currently stuck", a command,
/// ids and a state the local model made up (the Oct 30 4:09 AM run, read from
/// `~/.grux/jax/goal-runs.json`). The planner's only check was the product
/// catalog, so anything else it invented reached the card. A plan now advances
/// one real signal word for word and names nothing no signal names; otherwise
/// the cycle falls back to the deterministic pick, which only quotes a signal.
final class GoalPlanGroundingTests: XCTestCase {

    typealias Engine = GoalPursuitEngine

    private let signals = [
        Engine.Signal(domain: "product/code", line: "[in progress] Ship v3.2: the update check"),
        Engine.Signal(domain: "comms", line: "4 unread emails in the inbox that may need a reply"),
        Engine.Signal(domain: "ops", line: "2 items already waiting in the Jax HQ approval queue"),
    ]

    private func plan(_ reply: String) -> Engine.Plan {
        guard let p = Engine.parsePlan(reply) else {
            XCTFail("reply did not parse: \(reply)")
            return Engine.Plan(domain: "", chosenGoal: "", rationale: "", action: nil)
        }
        return p
    }

    private func reason(_ r: Result<Engine.Plan, Engine.PlanRefusal>) -> String? {
        if case .failure(let f) = r { return f.reason }
        return nil
    }

    /// The Oct 30 reply as the store holds it.
    private let oct30 = #"""
    {"domain":"ops","chosenGoal":"Execute pending approvals for the 2 items currently stuck in queue to unblock downstream dependencies","rationale":"Previous moves focused on clearing the backlog; now we must execute the actual work on the specific items identified as blockers, moving from prevention to active resolution.","action":{"title":"Process Queue Items","goal":"run_approval_runner --queue-id=hq-01 --item-ids=item-8492,item-3301 --priority=high","template":"singleWorker","budgetUSD":5}}
    """#

    func testTheOct30PlanIsRefused() {
        XCTAssertNotNil(reason(Engine.grounded(plan(oct30), signals: signals)))
    }

    func testTheSameCommandUnderARealGoalIsRefusedAndNamed() {
        let reply = #"{"signal":3,"domain":"ops","chosenGoal":"x","rationale":"Clear it.","action":{"title":"Process Queue Items","goal":"run_approval_runner --queue-id=hq-01 --item-ids=item-8492,item-3301","template":"singleWorker","budgetUSD":5}}"#
        let why = reason(Engine.grounded(plan(reply), signals: signals))
        XCTAssertNotNil(why)
        XCTAssertTrue(why?.contains("run_approval_runner") == true, why ?? "")
        XCTAssertTrue(why?.contains("item-8492") == true, why ?? "")
    }

    /// Each id-like shape on its own: snake_case, a flag, a key=value, letters
    /// with digits.
    func testEachInventedShapeAloneIsRefused() {
        for token in ["clear_stale_queue_root_cause", "--priority", "queue=main", "hq-01", "item8492", "Q4"] {
            let reply = #"{"signal":3,"domain":"ops","chosenGoal":"x","rationale":"r","action":{"title":"Review the queue","goal":"Review the approval queue and use \#(token).","template":"singleWorker","budgetUSD":5}}"#
            XCTAssertNotNil(reason(Engine.grounded(plan(reply), signals: signals)), token)
        }
    }

    func testAnInventedTokenInTheTitleOrRationaleIsRefused() {
        let inTitle = #"{"signal":3,"domain":"ops","chosenGoal":"x","rationale":"r","action":{"title":"clear_stale_queue","goal":"Review the approval queue.","template":"singleWorker","budgetUSD":5}}"#
        XCTAssertNotNil(reason(Engine.grounded(plan(inTitle), signals: signals)))
        let inWhy = #"{"signal":3,"domain":"ops","chosenGoal":"x","rationale":"Ticket ops-77 says so.","action":{"title":"Review","goal":"Review the approval queue.","template":"singleWorker","budgetUSD":5}}"#
        XCTAssertNotNil(reason(Engine.grounded(plan(inWhy), signals: signals)))
    }

    /// A plain plan that names the signal by number keeps the signal's own
    /// words and domain, whatever the model wrote there.
    func testASignalNumberMakesTheGoalTheSignalWordForWord() {
        let reply = #"{"signal":3,"domain":"comms","chosenGoal":"2 approvals are stuck","rationale":"The queue is waiting on a decision.","action":{"title":"Review the waiting approvals","goal":"Open the Jax HQ approval queue, read the 2 waiting items and write a one-line recommendation for each.","template":"singleWorker","budgetUSD":5}}"#
        guard case .success(let p) = Engine.grounded(plan(reply), signals: signals) else {
            return XCTFail("a plain plan was refused")
        }
        XCTAssertEqual(p.chosenGoal, "2 items already waiting in the Jax HQ approval queue")
        XCTAssertEqual(p.domain, "ops")
        XCTAssertEqual(p.action?.title, "Review the waiting approvals")
    }

    /// The number's edges: 1 and the last are signals; 0 and one past are not.
    func testSignalNumberBoundaries() {
        func reply(_ n: Int) -> String {
            #"{"signal":\#(n),"domain":"ops","chosenGoal":"made up","rationale":"r","action":{"title":"Review","goal":"Review it.","template":"singleWorker","budgetUSD":5}}"#
        }
        guard case .success(let first) = Engine.grounded(plan(reply(1)), signals: signals),
              case .success(let last) = Engine.grounded(plan(reply(3)), signals: signals) else {
            return XCTFail("signal 1 or 3 was refused")
        }
        XCTAssertEqual(first.chosenGoal, signals[0].line)
        XCTAssertEqual(last.chosenGoal, signals[2].line)
        XCTAssertNotNil(reason(Engine.grounded(plan(reply(0)), signals: signals)))
        XCTAssertNotNil(reason(Engine.grounded(plan(reply(4)), signals: signals)))
    }

    /// With no number, the goal must be a signal word for word (case and
    /// spacing aside); a paraphrase is refused.
    func testWithoutANumberOnlyAVerbatimGoalIsKept() {
        let verbatim = #"{"domain":"ops","chosenGoal":"2 Items already waiting in the  Jax HQ approval queue.","rationale":"r","action":{"title":"Review","goal":"Review the approval queue.","template":"singleWorker","budgetUSD":5}}"#
        guard case .success(let p) = Engine.grounded(plan(verbatim), signals: signals) else {
            return XCTFail("a verbatim goal was refused")
        }
        XCTAssertEqual(p.chosenGoal, signals[2].line)
        let paraphrase = #"{"domain":"ops","chosenGoal":"Execute pending approvals for the 2 items currently stuck","rationale":"r","action":{"title":"Review","goal":"Review the approval queue.","template":"singleWorker","budgetUSD":5}}"#
        XCTAssertNotNil(reason(Engine.grounded(plan(paraphrase), signals: signals)))
    }

    /// A token a signal does name is fine: `v3.2` comes from the roadmap line.
    func testATokenASignalNamesIsKept() {
        let reply = #"{"signal":1,"domain":"product/code","chosenGoal":"x","rationale":"r","action":{"title":"Next v3.2 step","goal":"Write the failing test for the v3.2 update check.","template":"singleWorker","budgetUSD":5}}"#
        guard case .success = Engine.grounded(plan(reply), signals: signals) else {
            return XCTFail("a token the signal names was refused")
        }
    }

    /// Plain numbers and dollar amounts are not identifiers.
    func testPlainNumbersAreNotIdentifiers() {
        let reply = #"{"signal":2,"domain":"comms","chosenGoal":"x","rationale":"r","action":{"title":"Draft replies","goal":"Draft replies to the 4 unread emails, at most 3 sentences each, step 2 of 3, under $5.","template":"singleWorker","budgetUSD":5}}"#
        guard case .success = Engine.grounded(plan(reply), signals: signals) else {
            return XCTFail("plain numbers were read as invented identifiers")
        }
    }

    /// "Nothing worth doing" stays as the model said it.
    func testNothingActionableIsKept() {
        let reply = #"{"domain":"none","chosenGoal":"nothing actionable now","rationale":"Everything is moving.","action":null}"#
        guard case .success(let p) = Engine.grounded(plan(reply), signals: signals) else {
            return XCTFail("a no-action plan was refused")
        }
        XCTAssertNil(p.action)
    }

    /// A huge or fractional number does not crash the parse and is no signal.
    func testAnOddSignalNumberIsNoSignal() {
        for n in ["1e300", "2.5", "-1"] {
            let reply = #"{"signal":\#(n),"domain":"ops","chosenGoal":"made up","rationale":"r","action":{"title":"Review","goal":"Review it.","template":"singleWorker","budgetUSD":5}}"#
            XCTAssertNotNil(reason(Engine.grounded(plan(reply), signals: signals)), n)
        }
    }

    // MARK: Wave 18 review

    private var block: String {
        signals.enumerated().map { "\($0.offset + 1). (\($0.element.domain)) \($0.element.line)" }.joined(separator: "\n")
    }

    /// The model said there is nothing to do, with a real domain: the cycle
    /// starts nothing. It used to be refused for naming no signal, and the
    /// refusal dispatched the deterministic $5 worker the model declined.
    @MainActor
    func testANoActionReplyWithARealDomainStartsNothing() {
        let reply = #"{"domain":"ops","chosenGoal":"nothing actionable now","rationale":"The queue is fine.","action":null}"#
        let kept = Engine.settle(plan(reply), signals: signals, signalBlock: block)
        XCTAssertNil(kept.action, "a declined move became a worker")
    }

    /// The same with an id-like word in the reason: still nothing starts, and
    /// the card does not repeat the word.
    @MainActor
    func testANoActionReplyWithAnInventedWordStartsNothing() {
        let reply = #"{"domain":"none","chosenGoal":"nothing actionable now","rationale":"Nothing until ticket ops-77 lands.","action":null}"#
        let kept = Engine.settle(plan(reply), signals: signals, signalBlock: block)
        XCTAssertNil(kept.action, "a declined move became a worker")
        XCTAssertFalse(kept.rationale.contains("ops-77"), kept.rationale)
    }

    /// A count no signal gives is made up: the signal says 2 items wait, the
    /// plan says 3 are stuck. In the title, the reason or the instruction.
    func testAnInventedCountIsRefused() {
        let inWhy = #"{"signal":3,"domain":"ops","chosenGoal":"x","rationale":"3 approvals are stuck.","action":{"title":"Review the queue","goal":"Review the approval queue.","template":"singleWorker","budgetUSD":5}}"#
        let inTitle = #"{"signal":3,"domain":"ops","chosenGoal":"x","rationale":"r","action":{"title":"Unstick the 3 stuck approvals","goal":"Review the approval queue.","template":"singleWorker","budgetUSD":5}}"#
        let inGoal = #"{"signal":3,"domain":"ops","chosenGoal":"x","rationale":"r","action":{"title":"Review","goal":"Open the queue and clear the 3 stuck approvals.","template":"singleWorker","budgetUSD":5}}"#
        for reply in [inWhy, inTitle, inGoal] {
            XCTAssertNotNil(reason(Engine.grounded(plan(reply), signals: signals)), reply)
        }
    }

    /// A count a signal does give is kept, and so are numbers that shape the
    /// work rather than report a state.
    func testARealCountAndShapingNumbersAreKept() {
        let reply = #"{"signal":3,"domain":"ops","chosenGoal":"x","rationale":"The 2 items have waited.","action":{"title":"Review the 2 waiting items","goal":"Read the 2 items, step 1 of 2, at most 3 lines each, the first 2 only, under 10 minutes.","template":"singleWorker","budgetUSD":5}}"#
        if case .failure(let f) = Engine.grounded(plan(reply), signals: signals) { XCTFail(f.reason) }
    }

    /// A file or path no signal names is made up too, plain words or not.
    func testInventedFilesAndPathsAreRefused() {
        for token in ["scripts/approve.sh", "README.md", "/usr/local/bin/approver", "src/queue/runner", "approve.sh"] {
            let reply = #"{"signal":3,"domain":"ops","chosenGoal":"x","rationale":"r","action":{"title":"Review","goal":"Review the approval queue with \#(token).","template":"singleWorker","budgetUSD":5}}"#
            XCTAssertNotNil(reason(Engine.grounded(plan(reply), signals: signals)), token)
        }
    }

    func testOrdinaryAbbreviationsAreNotFiles() {
        let reply = #"{"signal":3,"domain":"ops","chosenGoal":"x","rationale":"Approve and/or decline, e.g. the oldest first, i.e. today.","action":{"title":"Review","goal":"Review the approval queue.","template":"singleWorker","budgetUSD":5}}"#
        if case .failure(let f) = Engine.grounded(plan(reply), signals: signals) { XCTFail(f.reason) }
    }

    /// A number and a word-for-word goal that name different signals: the
    /// model is confused about what it advances, so the plan is refused.
    func testANumberThatContradictsAVerbatimGoalIsRefused() {
        let reply = #"{"signal":2,"domain":"ops","chosenGoal":"2 items already waiting in the Jax HQ approval queue","rationale":"r","action":{"title":"Review","goal":"Review the approval queue.","template":"singleWorker","budgetUSD":5}}"#
        XCTAssertNotNil(reason(Engine.grounded(plan(reply), signals: signals)))
        let agrees = #"{"signal":3,"domain":"ops","chosenGoal":"2 items already waiting in the Jax HQ approval queue","rationale":"r","action":{"title":"Review","goal":"Review the approval queue.","template":"singleWorker","budgetUSD":5}}"#
        if case .failure(let f) = Engine.grounded(plan(agrees), signals: signals) { XCTFail(f.reason) }
    }

    // MARK: Wave 18 review, round 2

    private func refused(_ reply: String) -> Bool { reason(Engine.grounded(plan(reply), signals: signals)) != nil }

    private func actionReply(signal: Int = 3, rationale: String = "r", title: String = "Review", goal: String) -> String {
        let esc = { (t: String) in t.replacingOccurrences(of: "\"", with: "\\\"") }
        return #"{"signal":\#(signal),"domain":"ops","chosenGoal":"x","rationale":"\#(esc(rationale))","action":{"title":"\#(esc(title))","goal":"\#(esc(goal))","template":"singleWorker","budgetUSD":5}}"#
    }

    /// A plan that starts nothing names no goal of its own on the card: its
    /// headline is the fixed line, whatever the model wrote there.
    @MainActor
    func testANoActionPlanCannotHeadlineAMadeUpGoal() {
        let reply = #"{"domain":"ops","chosenGoal":"Execute pending approvals for the 7 items stuck in queue hq-01","rationale":"Waiting on the owner.","action":null}"#
        let kept = Engine.settle(plan(reply), signals: signals, signalBlock: block)
        XCTAssertNil(kept.action)
        XCTAssertEqual(kept.chosenGoal, "nothing actionable now")
    }

    /// Numbers that shape the work are not counts of anything a signal counts.
    func testNumbersThatShapeTheWorkAreKept() {
        for goal in ["Draft replies to the 3 most urgent emails.", "Answer in 2 sentences.",
                     "Write 5 bullet points.", "Reply to 3 of them.", "Spend 10 minutes on it.",
                     "Make a 2-step plan with 3-sentence notes."] {
            XCTAssertFalse(refused(actionReply(signal: 2, goal: goal)), goal)
        }
    }

    /// A count of a kind of thing must be a count a signal gives of that
    /// kind: the mail count does not vouch for approvals.
    func testACountBorrowedFromAnotherSignalIsRefused() {
        XCTAssertTrue(refused(actionReply(rationale: "4 approvals are stuck.", goal: "Review the approval queue.")))
        XCTAssertFalse(refused(actionReply(rationale: "The 2 waiting approvals need a look.", goal: "Review the approval queue.")))
        XCTAssertFalse(refused(actionReply(signal: 2, goal: "Reply to the 4 unread emails.")))
    }

    /// Spelled, hedged and fractional counts are counts too.
    func testOtherShapesOfAMadeUpCountAreRefused() {
        for why in ["Three approvals are stuck.", "At least 3 approvals are stuck.", "More than 3 items are stuck.",
                    "The first 3 approvals are stuck.", "2.5 approvals are stuck."] {
            XCTAssertTrue(refused(actionReply(rationale: why, goal: "Review the approval queue.")), why)
        }
    }

    func testMorePathShapesAreRefused() {
        for token in ["/etc/hosts", "~/.grux/queue", "scripts/approve", "x.sh", "backup.tar.gz", "data.sqlite"] {
            XCTAssertTrue(refused(actionReply(goal: "Review the approval queue with \(token).")), token)
        }
    }

    /// Two signals with the same words: the number picks either.
    func testDuplicateSignalsDoNotRefuseTheSecond() {
        let twin = [Engine.Signal(domain: "product/code", line: "[queued] Polish"),
                    Engine.Signal(domain: "product/code", line: "[queued] Polish")]
        let reply = #"{"signal":2,"domain":"product/code","chosenGoal":"[queued] Polish","rationale":"r","action":{"title":"Polish","goal":"Polish it.","template":"singleWorker","budgetUSD":5}}"#
        if case .failure(let f) = Engine.grounded(plan(reply), signals: twin) { XCTFail(f.reason) }
    }

    // MARK: Wave 18 review, round 3

    /// A plan may take on part of what waits; it may not claim more than
    /// waits. Ordinary comms and ops phrasings pass.
    func testAPlanMayCountPartOfWhatWaits() {
        for goal in ["Reply to one email at a time.", "Reply to the top 3 emails.", "Draft 3 replies.",
                     "1. Read the inbox. 2. Reply to the urgent ones.", "Review the next 2 approvals.",
                     "Split the update check into 3 tasks.", "Approve/reject each one by 5pm, 24/7 if needed, the 2nd item first."] {
            XCTAssertFalse(refused(actionReply(signal: 2, goal: goal)), goal)
        }
    }

    /// The D73 shape: more stuck than wait.
    func testMoreThanWaitsIsRefused() {
        let one = [Engine.Signal(domain: "ops", line: "1 item already waiting in the Jax HQ approval queue")]
        let reply = #"{"signal":1,"domain":"ops","chosenGoal":"x","rationale":"2 items are currently stuck.","action":{"title":"Review","goal":"Review the approval queue.","template":"singleWorker","budgetUSD":5}}"#
        XCTAssertNotNil(reason(Engine.grounded(plan(reply), signals: one)))
    }

    /// With no mail signal there is no unread mail to count.
    func testAMailCountWithNoMailSignalIsRefused() {
        let noMail = [Engine.Signal(domain: "product/code", line: "[queued] Polish: 3 items left")]
        let reply = #"{"signal":1,"domain":"product/code","chosenGoal":"x","rationale":"5 unread emails wait.","action":{"title":"Polish","goal":"Polish it.","template":"singleWorker","budgetUSD":5}}"#
        XCTAssertNotNil(reason(Engine.grounded(plan(reply), signals: noMail)))
        // A roadmap line's own words are not the approval queue's count.
        let queue = #"{"signal":1,"domain":"product/code","chosenGoal":"x","rationale":"3 approvals are stuck.","action":{"title":"Polish","goal":"Polish it.","template":"singleWorker","budgetUSD":5}}"#
        XCTAssertNotNil(reason(Engine.grounded(plan(queue), signals: noMail)))
    }

    // MARK: D77: what waits for the person is theirs to answer

    /// The queue signal exactly as `gatherSignals` builds it.
    private let queue = Engine.Signal.approvalQueue(pending: 1)
    private var withQueue: [Engine.Signal] {
        [signals[0], signals[1], queue]
    }

    private func block(_ s: [Engine.Signal]) -> String {
        s.enumerated().map { "\($0.offset + 1). (\($0.element.domain)) \($0.element.line)" }.joined(separator: "\n")
    }

    func testTheQueueSignalReadsAsBefore() {
        XCTAssertEqual(queue.line, "1 item already waiting in the Jax HQ approval queue")
        XCTAssertEqual(queue.domain, "ops")
        XCTAssertEqual(Engine.Signal.approvalQueue(pending: 3).line, "3 items already waiting in the Jax HQ approval queue")
    }

    /// Sense pass 6 (`jaxCommand-1.png`): grounded on the queue, the plan was a
    /// $5 worker "to process the single item currently stuck in the Jax HQ
    /// approval queue". An approval is the person's to give, so the move is to
    /// ask them, and nothing starts.
    @MainActor
    func testAPlanOnTheApprovalQueueAsksThePersonAndStartsNothing() {
        for goal in ["Run the Claude Code worker session to process the single item currently stuck in the Jax HQ approval queue, finalizing its status.",
                     "Review the approval queue."] {
            let reply = #"{"signal":3,"domain":"ops","chosenGoal":"x","rationale":"The queue is the oldest thing waiting.","action":{"title":"Execute Pending Approval","goal":"\#(goal)","template":"singleWorker","budgetUSD":5}}"#
            let kept = Engine.settle(plan(reply), signals: withQueue, signalBlock: block(withQueue))
            XCTAssertNil(kept.action, "a worker was planned for the person's approval: \(goal)")
            XCTAssertEqual(kept.chosenGoal, queue.line)
            XCTAssertEqual(kept.rationale, Engine.yoursToAnswerRationale)
        }
    }

    /// The pick that needs no model never takes the queue either: with only
    /// the queue it asks the person, and with the queue first it advances the
    /// next real item a worker may take.
    @MainActor
    func testThePickInPlaceOfARefusedPlanNeverTakesTheQueue() {
        let refusedReply = #"{"signal":1,"domain":"ops","chosenGoal":"x","rationale":"Run run_approval_runner.","action":{"title":"Clear","goal":"Clear it.","template":"singleWorker","budgetUSD":5}}"#
        let alone = Engine.settle(plan(refusedReply), signals: [queue], signalBlock: block([queue]))
        XCTAssertNil(alone.action, "the fallback paid a worker to answer an approval")
        XCTAssertEqual(alone.chosenGoal, queue.line)
        XCTAssertEqual(alone.rationale, Engine.yoursToAnswerRationale)

        let queueFirst = [queue, signals[1]]
        let next = Engine.settle(plan(refusedReply), signals: queueFirst, signalBlock: block(queueFirst))
        XCTAssertEqual(next.chosenGoal, signals[1].line)
        XCTAssertNotNil(next.action)
    }

    /// Wave 19 review: a plan tagged to another signal whose worker is told to
    /// work the queue still paid a worker to answer an approval. A worker may
    /// speak of approvals only when the signal it advances does. Round 2:
    /// nothing starts on the queue. Wave 19 P3 item 1: the plan keeps its own
    /// signal (a correct mail plan that copies "do not touch the approval
    /// queue" still advances the mail), and only its worker's words are
    /// replaced by the plain step that names nothing the signal does not.
    @MainActor
    func testAWorkerOnAnotherSignalNeverWorksTheQueue() {
        let actions = [
            ("Clear what waits", "Work through the 1 item waiting in the Jax HQ approval queue and settle it."),
            ("Settle pending approvals", "Reply to the top email, then clear what waits."),
            ("Triage", "Approve the waiting item once the mail is answered."),
            ("Triage", "Reply to the top 3 emails and the approvals."),
            ("Triage", "Pre-approve the waiting item, then reply to the mail."),
            ("Triage mail", "Draft a reply to the unread email. Do not touch the approval queue; that is the user's."),
        ]
        for (title, goal) in actions {
            let reply = #"{"signal":2,"domain":"comms","chosenGoal":"x","rationale":"Mail and the queue both wait.","action":{"title":"\#(title)","goal":"\#(goal)","template":"singleWorker","budgetUSD":5}}"#
            let kept = Engine.settle(plan(reply), signals: withQueue, signalBlock: block(withQueue))
            XCTAssertEqual(kept.chosenGoal, signals[1].line, "the plan lost its own signal: \(title) / \(goal)")
            XCTAssertEqual(kept.domain, signals[1].domain, goal)
            XCTAssertEqual(kept.rationale, Engine.approvalWordsSetAsideRationale, goal)
            let worker = "\(kept.action?.title ?? "") \(kept.action?.goal ?? "")"
            XCTAssertNotNil(kept.action, "the plan's own signal lost its worker: \(goal)")
            XCTAssertTrue(worker.contains(signals[1].line), worker)
            XCTAssertFalse(Engine.namesApprovals(worker), "a worker was told about the queue: \(worker)")
        }
        // With only the mail and the queue, the set-aside pick is the mail.
        let mailAndQueue = [signals[1], queue]
        let reply = #"{"signal":1,"domain":"comms","chosenGoal":"x","rationale":"r","action":{"title":"Clear","goal":"Approve the waiting item.","template":"singleWorker","budgetUSD":5}}"#
        let kept = Engine.settle(plan(reply), signals: mailAndQueue, signalBlock: block(mailAndQueue))
        XCTAssertEqual(kept.chosenGoal, signals[1].line)
        XCTAssertFalse(Engine.namesApprovals(kept.action?.goal ?? ""))
    }

    /// A roadmap item that is itself about approvals still takes a worker
    /// while the queue waits, and with no queue the rule reads nothing.
    @MainActor
    func testARoadmapItemAboutApprovalsStillTakesAWorker() {
        let roadmap = Engine.Signal(domain: "product/code", line: "[in progress] Build the approvals inbox")
        let reply = #"{"signal":1,"domain":"product/code","chosenGoal":"x","rationale":"The inbox is in progress.","action":{"title":"Approvals inbox","goal":"Add the approvals inbox list view.","template":"singleWorker","budgetUSD":5}}"#
        for set in [[roadmap, queue], [roadmap]] {
            let kept = Engine.settle(plan(reply), signals: set, signalBlock: block(set))
            XCTAssertNotNil(kept.action, "a roadmap item about approvals lost its worker")
            XCTAssertEqual(kept.chosenGoal, roadmap.line)
        }
        let mail = #"{"signal":1,"domain":"comms","chosenGoal":"x","rationale":"Mail waits.","action":{"title":"Triage","goal":"Reply to the approval request emails.","template":"singleWorker","budgetUSD":5}}"#
        let noQueue = [signals[1]]
        XCTAssertNotNil(Engine.settle(plan(mail), signals: noQueue, signalBlock: block(noQueue)).action,
                        "with no queue waiting, approval words in a mail plan take nothing away")
    }

    /// W19-P3 items 2 and 3: the code read only "approv" while the prompt
    /// says "approvals or the queue", so "the Jax HQ queue" on mail passed;
    /// and a roadmap item naming approvals let any approval words through. A
    /// worker may use a queue word (approv..., queue..., HQ) only when the
    /// signal it advances uses that same word.
    @MainActor
    func testAWorkerNamesTheQueueOnlyInItsOwnSignalsWords() {
        let roadmap = Engine.Signal(domain: "product/code", line: "[in progress] Build the approvals inbox")
        let retry = Engine.Signal(domain: "product/code", line: "[queued] Add a retry queue for sends")
        let exportScreen = Engine.Signal(domain: "product/code", line: "[queued] Ship the export screen")
        let setAside: [(Engine.Signal, String)] = [
            (signals[1], "Clear the item waiting in the Jax HQ queue."),
            (signals[1], "Empty the queue, then reply to the top email."),
            (signals[1], "Settle what waits in Jax HQ, then reply to the mail."),
            (signals[1], "Reply to the mail, then work the queued items."),
            (roadmap, "Approve the 1 item waiting in the Jax HQ approval queue."),
            (roadmap, "Approve what waits, then build the approvals inbox."),
            (roadmap, "Build the approvals inbox, then clear the queue."),
            // Wave 23 round 1: HQ joined to another word, or possessive, was not read.
            (signals[1], "Clear what waits in Jax-HQ, then reply to the mail."),
            (signals[1], "Settle Jax HQ's items, then reply to the mail."),
            (signals[1], "Settle Jax HQ\u{2019}s items, then reply to the mail."),
            // Round 2: HQ joined by any other character, or run into a word.
            (signals[1], "Clear what waits in Jax HQ\u{2014}then reply to the mail."),
            (signals[1], "Clear what waits in Jax\u{2013}HQ, then reply to the mail."),
            (signals[1], "Clear what waits in Jax.HQ, then reply to the mail."),
            (signals[1], "Clear what waits in jax_hq, then reply to the mail."),
            (signals[1], "Clear what waits in Jax HQ\u{2026}then reply to the mail."),
            (signals[1], "Clear the HQs items, then reply to the mail."),
            (signals[1], "Clear what waits in JaxHQ, then reply to the mail."),
            (signals[1], "Clear what waits in Jax HQ\u{02BC}s list, then reply to the mail."),
            // A worker's own "[queued]" is its words, not the signal's tag.
            (signals[1], "Clear the [queued] items waiting for the person, then reply to the mail."),
            // Grux's own "[queued]" tag is not the item's words.
            (exportScreen, "Ship the export screen, then clear the queued items waiting in Jax."),
            (retry, "Start the queued item: a retry queue for sends."),
        ]
        for (own, goal) in setAside {
            let set = [own, queue]
            let reply = #"{"signal":1,"domain":"\#(own.domain)","chosenGoal":"x","rationale":"r","action":{"title":"Next step","goal":"\#(goal)","template":"singleWorker","budgetUSD":5}}"#
            let kept = Engine.settle(plan(reply), signals: set, signalBlock: block(set))
            // Set aside by the queue rule, or refused earlier by grounding ("jax_hq" reads as
            // an identifier): either way the model's worker is not kept.
            XCTAssertNotEqual(kept.action?.goal, goal, "the worker kept its queue words: \(goal)")
            XCTAssertNotEqual(kept.rationale, "r", goal)
            XCTAssertEqual(kept.chosenGoal, own.line, goal)
            XCTAssertNotNil(kept.action, goal)
            XCTAssertFalse(Engine.reachesIntoTheQueue("\(kept.action?.title ?? "") \(kept.action?.goal ?? "")", signal: own.line), goal)
        }
        // On the boundary: the same word the signal uses is the signal's own work.
        let kept: [(Engine.Signal, String)] = [
            (roadmap, "Add the approvals inbox list view."),
            (retry, "Add the retry queue for sends."),
            (retry, "Fix the retry queue's backoff for sends."),
            (exportScreen, "Ship the export screen."),
            (exportScreen, "[Queued] Ship the export screen."),
            (exportScreen, "[Queued]: Ship the export screen."),
            (exportScreen, "[queued]  Ship the export screen."),
            (exportScreen, "[queued] - Ship the export screen."),
            (signals[1], "Reply to the top 3 emails."),
        ]
        for (own, goal) in kept {
            let set = [own, queue]
            let reply = #"{"signal":1,"domain":"\#(own.domain)","chosenGoal":"x","rationale":"r","action":{"title":"Next step","goal":"\#(goal)","template":"singleWorker","budgetUSD":5}}"#
            let p = Engine.settle(plan(reply), signals: set, signalBlock: block(set))
            XCTAssertEqual(p.action?.goal, goal, "a worker on its own signal's words was set aside")
            XCTAssertEqual(p.rationale, "r", goal)
        }
    }

    /// A plain ops line Grux did not mark as the person's still takes a worker.
    @MainActor
    func testOtherSignalsStillTakeAWorker() {
        let reply = #"{"signal":2,"domain":"comms","chosenGoal":"x","rationale":"Mail waits.","action":{"title":"Triage","goal":"Reply to the top 3 emails.","template":"singleWorker","budgetUSD":5}}"#
        let kept = Engine.settle(plan(reply), signals: withQueue, signalBlock: block(withQueue))
        XCTAssertNotNil(kept.action)
        XCTAssertEqual(kept.chosenGoal, signals[1].line)
    }

    /// W18-P3 (2): a decline with an empty goal failed the parse and the
    /// fallback started the deterministic worker the model declined.
    @MainActor
    func testADeclineWithAnEmptyOrMissingGoalStartsNothing() {
        for reply in [#"{"domain":"none","chosenGoal":"","rationale":"All quiet.","action":null}"#,
                      #"{"domain":"none","rationale":"All quiet.","action":null}"#,
                      #"{"domain":"none","chosenGoal":"","rationale":"All quiet."}"#] {
            let p = plan(reply)
            XCTAssertNil(p.action, reply)
            XCTAssertNil(Engine.settle(p, signals: signals, signalBlock: block).action, reply)
        }
        // An empty goal with an action is still no plan.
        XCTAssertNil(Engine.parsePlan(#"{"domain":"ops","chosenGoal":"","rationale":"r","action":{"title":"T","goal":"G","template":"singleWorker","budgetUSD":5}}"#))
    }

    /// W19-P3 (4): a decline spelled any other way than null or absent
    /// ("none", false, {}, an action with an empty title or goal) failed the
    /// parse, and the fallback started the worker the model declined.
    @MainActor
    func testADeclineSpelledAnyWayStartsNothing() {
        for action in [#""none""#, #""""#, "false", "0", "{}", "[]",
                       #"{"title":"","goal":""}"#, #"{"title":"T","goal":""}"#, #"{"goal":""}"#,
                       // Wave 20 round 1: an empty or blank title, or a blank goal.
                       #"{"title":"","goal":"Nothing to do","template":"singleWorker","budgetUSD":5}"#,
                       #"{"title":"  ","goal":"Nothing to do"}"#, #"{"title":"T","goal":" \n "}"#,
                       #"{"goal":"Nothing to do"}"#] {
            let reply = #"{"domain":"none","chosenGoal":"","rationale":"All quiet.","action":"# + action + "}"
            guard let p = Engine.parsePlan(reply) else { XCTFail("read as no plan, so the fallback worker starts: \(reply)"); continue }
            XCTAssertNil(p.action, reply)
            XCTAssertNil(Engine.settle(p, signals: signals, signalBlock: block).action, reply)
        }
    }
}
