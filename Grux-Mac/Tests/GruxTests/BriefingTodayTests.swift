import XCTest
@testable import Grux

/// Phase D, D4: the briefing carries the day's decision line, and its mail
/// rows follow the same needs-you rule as the badge and the Today card.
final class BriefingTodayTests: XCTestCase {

    private func row(_ ms: Int, cost jev: Bool = true) -> DecisionLedgerEntry {
        DecisionLedgerEntry(surface: "voice", provider: jev ? .jev : .local, latencyMs: ms,
                            inputTokens: jev ? 2000 : 0, outputTokens: 0, at: Date(), summary: "Heard: x -> y")
    }

    func test_theDecisionLineIsThereOnADayWithDecisions() throws {
        let summary = DecisionUsageSummary.today([row(400), row(500), row(3, cost: false)])
        let item = try XCTUnwrap(BriefingEngine.decisionItem(summary))
        XCTAssertEqual(item.kind, .decisions)
        XCTAssertEqual(item.title, summary.line)
        XCTAssertTrue(item.title.hasPrefix("3 decisions today"), item.title)
    }

    /// "No decisions yet today" at 7 AM every morning is noise.
    func test_theDecisionLineIsOmittedOnADayWithout() {
        XCTAssertNil(BriefingEngine.decisionItem(DecisionUsageSummary.today([])))
    }

    func test_briefingMailFollowsTheBadgesRule() {
        func m(_ subject: String, unread: Bool = true, p: Double? = nil, from: String = "Sam",
               body: String = "", minutesAgo: Double = 0) -> EmailMessage {
            var e = EmailMessage(id: UUID().uuidString, accountId: UUID(), sequenceNumber: 1, messageId: "",
                                 fromName: from, fromEmail: "sam@example.com", to: "me@example.com",
                                 subject: subject, date: Date().addingTimeInterval(-minutesAgo * 60),
                                 snippet: "can you look", bodyText: body, isUnread: unread,
                                 fetchedAt: Date(), triageDraftId: nil)
            e.needsYouProbability = p
            return e
        }
        let messages = [m("Invoice question", minutesAgo: 3), m("Weekly digest", body: "Unsubscribe here"),
                        m("Judged not for you", p: 0.1), m("Already read", unread: false),
                        m("Can we meet", minutesAgo: 1)]
        let items = BriefingEngine.mailItems(messages)
        XCTAssertEqual(items.map(\.title), ["Can we meet", "Invoice question"])
        XCTAssertEqual(items.count, MailNeedsYou.count(messages), "the briefing and the badge disagree")
    }

    func test_theBriefingAssemblyUsesBoth() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf: root.appendingPathComponent("Sources/Grux/Jax/BriefingEngine.swift"), encoding: .utf8)
        XCTAssertTrue(src.contains("items += Self.mailItems(MailStore.shared.messages)"))
        XCTAssertTrue(src.contains("Self.decisionItem(DecisionUsageSummary.today(DecisionLedger.shared.recent))"))
        XCTAssertFalse(src.contains(".filter { $0.isUnread }\n            .prefix(5)"), "the briefing is back to every unread message")
    }
}
