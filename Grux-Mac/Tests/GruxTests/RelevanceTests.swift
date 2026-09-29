import XCTest
@testable import Grux

/// What the panel's Now list shows, decided by one pure function. Every rule
/// in spec section 4.2 is a test here, and the function takes a value struct
/// so none of these needs a store.
final class RelevanceTests: XCTestCase {

    private func next(_ title: String) -> TodayModel.Next {
        TodayModel.Next(kind: .task, title: title, when: "", tab: "tasks", then: [])
    }

    private func job(_ id: String, _ title: String = "Job") -> RunningJob {
        RunningJob(id: id, title: title)
    }

    func test_nothingInGivesNothingOut() {
        XCTAssertEqual(Relevance.now(RelevanceState()), [])
    }

    func test_everyRowCarriesAnAction() {
        var s = RelevanceState()
        s.approvalsPending = 1
        s.mail = [TodayModel.MailSummary(id: "m1", from: "Ana", subject: "Invoice")]
        s.jobsRunning = [job("j1"), job("j2")]
        s.next = next("Write the plan")
        s.proposals = 1
        s.setupGaps = [SetupGap(featureId: "mailbox", label: "Mail", missing: "an IMAP account")]
        s.oldHookNeedsRemoval = true
        // No cap: a new rule's eighth row must show up in the count, not fall off the end.
        let items = Relevance.now(s, cap: .max)
        for item in items {
            switch item.action {
            case .open, .openApprovals, .openWorkOrder, .setup, .openOptimize, .openJob, .claudeSignIn,
                 .revealClaudeSettings: break
            }
        }
        XCTAssertEqual(items.count, 8,
                       "1 approvals row + 1 mail + 1 old hook + 2 running jobs + 1 next + 1 setup gap + 1 proposals = 8")
        XCTAssertTrue(items.allSatisfy { !$0.id.isEmpty }, "every row has an id")
        XCTAssertEqual(Set(items.map(\.id)).count, items.count, "ids are unique")
        XCTAssertEqual(items.map(\.action).filter { if case .openJob = $0 { return true } else { return false } },
                       [.openJob(id: "j1"), .openJob(id: "j2")], "each running job row opens that job")
    }

    func test_classesComeInOrder_needsYouRunningNextSuggested() {
        var s = RelevanceState()
        s.proposals = 1                              // suggested
        s.next = next("Call Sam")                    // next
        s.jobsRunning = [job("j1")]                  // running
        s.approvalsPending = 2                       // needsYou
        let classes = Relevance.now(s).map(\.cls)
        XCTAssertEqual(classes, [.needsYou, .running, .next, .suggested])
    }

    func test_approvalsCollapseToOneRowWhateverTheCount() {
        var s = RelevanceState()
        s.approvalsPending = 9
        let rows = Relevance.now(s)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.title, "9 approvals waiting")
        XCTAssertEqual(rows.first?.action, .openApprovals)
    }

    func test_oneApprovalReadsInTheSingular() {
        var s = RelevanceState()
        s.approvalsPending = 1
        XCTAssertEqual(Relevance.now(s).first?.title, "1 approval waiting")
    }

    func test_aWorkOrderAtAReviewIsNeedsYou_andOpensThatOrder() {
        var s = RelevanceState()
        s.reviewsWaiting = [WorkOrderReview(id: "wo-abc123", request: "Make the accent red")]
        let row = Relevance.now(s)[0]
        XCTAssertEqual(row.cls, .needsYou)
        XCTAssertEqual(row.action, .openWorkOrder(id: "wo-abc123"))
        XCTAssertTrue(row.title.contains("Make the accent red"))
    }

    func test_mailRowsKeepTheirSourceOrderAndOpenMail() {
        var s = RelevanceState()
        s.mail = [TodayModel.MailSummary(id: "a", from: "Ana", subject: "One"),
                  TodayModel.MailSummary(id: "b", from: "Bo", subject: "Two")]
        let rows = Relevance.now(s)
        XCTAssertEqual(rows.map(\.title), ["Ana: One", "Bo: Two"])
        XCTAssertEqual(rows.map(\.action), [.open(tabKey: "mailbox"), .open(tabKey: "mailbox")])
    }

    func test_theCapIsSeven_andAParameter() {
        var s = RelevanceState()
        s.mail = (0..<10).map { TodayModel.MailSummary(id: "\($0)", from: "F\($0)", subject: "S") }
        XCTAssertEqual(Relevance.now(s).count, 7)
        XCTAssertEqual(Relevance.now(s, cap: 3).count, 3)
    }

    func test_theCapNeverPromotesALowerClass() {
        var s = RelevanceState()
        s.mail = (0..<9).map { TodayModel.MailSummary(id: "\($0)", from: "F\($0)", subject: "S") }
        s.next = next("Should not appear")
        let rows = Relevance.now(s)
        XCTAssertEqual(rows.count, 7)
        XCTAssertTrue(rows.allSatisfy { $0.cls == .needsYou })
        XCTAssertEqual(rows.map(\.id), (0..<7).map { "mail.\($0)" }, "source order inside the class")
    }

    func test_eachRunningJobIsItsOwnRow_andAWorkflowIsRunning() {
        var s = RelevanceState()
        s.jobsRunning = [job("j1", "Index the docs"), job("j2", "Draft the brief"), job("j3", "Tidy notes")]
        s.workflowRunning = "smoke-hello-world"
        let rows = Relevance.now(s)
        XCTAssertEqual(rows.map(\.cls), [.running, .running, .running, .running])
        XCTAssertEqual(rows.prefix(3).map(\.title), ["Index the docs", "Draft the brief", "Tidy notes"],
                       "one row per job, in source order")
        XCTAssertEqual(rows.prefix(3).map(\.action), [.openJob(id: "j1"), .openJob(id: "j2"), .openJob(id: "j3")])
        XCTAssertEqual(rows[3].action, .open(tabKey: "workflows"))
    }

    func test_jobsWaitingOnYouAreNeedsYouNotRunning() {
        var s = RelevanceState()
        s.jobsWaitingOnYou = [job("w1", "Pick a title"), job("w2", "Approve the plan")]
        let rows = Relevance.now(s)
        XCTAssertEqual(rows.map(\.cls), [.needsYou, .needsYou], "one row each, never collapsed")
        XCTAssertEqual(rows.map(\.title), ["Pick a title", "Approve the plan"])
        XCTAssertEqual(rows.map(\.action), [.openJob(id: "w1"), .openJob(id: "w2")])
    }

    func test_aRunningJobRowOpensThatJob() {
        var s = RelevanceState()
        s.jobsRunning = [job("job-42", "Index the docs")]
        XCTAssertEqual(Relevance.now(s).first?.action, .openJob(id: "job-42"))
    }

    func test_nextOpensTheTabItNames() {
        var s = RelevanceState()
        s.next = TodayModel.Next(kind: .event, title: "Standup", when: "At 9:30 AM", tab: "calendar", then: [])
        let row = Relevance.now(s)[0]
        XCTAssertEqual(row.cls, .next)
        XCTAssertEqual(row.action, .open(tabKey: "calendar"))
        XCTAssertEqual(row.detail, "At 9:30 AM")
    }

    func test_setupGapsAndProposalsAreSuggested() {
        var s = RelevanceState()
        // The missing thing is the registry's label, verbatim: a noun or a step.
        s.setupGaps = [SetupGap(featureId: "meetings", label: "Meetings", missing: "Confirm you will tell people")]
        s.proposals = 2
        let rows = Relevance.now(s)
        XCTAssertEqual(rows.map(\.cls), [.suggested, .suggested])
        XCTAssertEqual(rows[0].action, .setup(featureId: "meetings"))
        XCTAssertEqual(rows[0].title, "Set up Meetings")
        XCTAssertEqual(rows[0].detail, "Confirm you will tell people")
        XCTAssertEqual(rows[1].action, .open(tabKey: "selfUpgrade"))
    }

    func test_brandScopedRowsNeedABrand() {
        var s = RelevanceState()
        s.setupGaps = [SetupGap(featureId: "metaAds", label: "Meta Ads", missing: "an ad account", brandScoped: true),
                       SetupGap(featureId: "social", label: "Social", missing: "a brand", brandScoped: true)]
        XCTAssertEqual(Relevance.now(s), [], "brand-scoped gaps without a brand")
        s.hasBrand = true
        XCTAssertEqual(Relevance.now(s).count, 2)
    }

    func test_idsAreStableAndDistinct() {
        var s = RelevanceState()
        s.approvalsPending = 1; s.jobsRunning = [job("j1")]; s.next = next("x"); s.proposals = 1
        s.mail = [TodayModel.MailSummary(id: "m", from: "f", subject: "s")]
        let ids = Relevance.now(s).map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(Relevance.now(s).map(\.id), ids, "same input, same ids")
    }
}
