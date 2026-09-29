import XCTest
@testable import Grux

/// The rail showed 245, which is an inbox size: the same number on a calm day
/// and on a terrible one. A count that never moves is wallpaper.
final class MailNeedsYouTests: XCTestCase {

    private func message(from: String = "sarah@example.com", unread: Bool = true,
                         snippet: String = "can you look at the invoice",
                         body: String = "") -> EmailMessage {
        EmailMessage(id: UUID().uuidString, accountId: UUID(), sequenceNumber: 1,
                     messageId: "", fromName: "Sarah", fromEmail: from, to: "me@example.com",
                     subject: "Invoice", date: Date(), snippet: snippet, bodyText: body,
                     isUnread: unread, fetchedAt: Date(), triageDraftId: nil)
    }

    func test_somethingAlreadyReadIsSomethingAlreadyDealtWith() {
        XCTAssertFalse(MailNeedsYou.needsYou(message(unread: false)))
    }

    func test_aPersonAskingForSomethingCounts() {
        XCTAssertTrue(MailNeedsYou.needsYou(message()))
    }

    func test_anAddressThatOnlyEverSendsDoesNotCount() {
        for sender in ["noreply@stripe.com", "no-reply@github.com", "notifications@slack.com",
                       "newsletter@substack.com", "alerts@bank.com", "mailer-daemon@host"] {
            XCTAssertFalse(MailNeedsYou.needsYou(message(from: sender)),
                           "\(sender) counted as needing a reply")
        }
    }

    func test_mailSentToAListDoesNotCount() {
        for marker in ["Unsubscribe at any time", "View in browser",
                       "You are receiving this because you signed up"] {
            XCTAssertFalse(MailNeedsYou.needsYou(message(body: marker)),
                           "list mail counted: \(marker)")
        }
    }

    /// Conservative in one direction on purpose: a missed message is worse
    /// than one extra in the badge.
    func test_anUnfamiliarSenderWithNoListMarkersStillCounts() {
        XCTAssertTrue(MailNeedsYou.needsYou(message(from: "someone@unknown-domain.io")))
    }

    func test_theCountIsWhatNeedsYouAndNotHowMuchMailExists() {
        let inbox = [
            message(),                                      // counts
            message(from: "noreply@stripe.com"),            // bulk
            message(unread: false),                         // read
            message(body: "unsubscribe"),                   // list
            message(from: "dave@example.com"),              // counts
        ]
        XCTAssertEqual(MailNeedsYou.count(inbox), 2)
        XCTAssertNotEqual(MailNeedsYou.count(inbox), inbox.filter(\.isUnread).count,
                          "the count is still just the unread total")
    }

    func test_anEmptyInboxCountsZeroRatherThanCrashing() {
        XCTAssertEqual(MailNeedsYou.count([]), 0)
    }
}

/// The rail carries the setup count and drops the standing sentence, and no
/// row carries a BETA pill any more.
final class RailBadgeTests: XCTestCase {
    private func launchRoot() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/LaunchRootView.swift")
        let t = try String(contentsOf: url, encoding: .utf8)
        XCTAssertGreaterThan(t.count, 500, "LaunchRootView did not load")
        return t
    }

    /// The pills go when the Labs door arrives to carry the promise, not
    /// before. See Phase C task C2. BetaBadgeTests guards the other half:
    /// onboarding promises experimental features are labelled, and removing
    /// the label before its replacement exists makes onboarding lie.
    func test_theBetaPillStaysUntilTheLabsDoorCanCarryThePromise() throws {
        XCTAssertTrue(try launchRoot().contains("BetaBadge()"),
                      "the labelling promise is broken and the Labs door does not exist yet")
    }

    func test_theMailCountIsWhatNeedsYou() throws {
        let t = try launchRoot()
        // The rail reads MailStore's memo of MailNeedsYou.count (P-R-8), and
        // MailNeedsYouMemoTests pins that memo equal to a fresh count.
        XCTAssertTrue(t.contains("mailStore.needsYouCount"), "the rail is back to counting unread mail")
        XCTAssertFalse(t.contains("mailStore.unreadCount()"), "the rail is back to counting unread mail")
    }

    func test_theSetupNagIsABadgeRatherThanAStandingSentence() throws {
        let t = try launchRoot()
        XCTAssertFalse(t.contains("features need setup"),
                       "the permanent setup sentence is back in the foot of the rail")
        XCTAssertTrue(t.contains("case \"settings\": return FeatureRegistry.featuresNeedingSetup.count"),
                      "the setup count is not on the Settings row")
    }

    func test_listeningAndMuteAreReachableFromTheFoot() throws {
        let t = try launchRoot()
        XCTAssertTrue(t.contains("private var listeningFoot"), "listening left the foot of the rail")
        // The call names its caller since 2026-09-22, so the log line can say
        // which of the four surfaces muted.
        XCTAssertTrue(t.contains("MicController.toggle(source:"), "mute is not reachable from the foot")
    }
}

/// The rail reads the Mail badge on every render. It must not rescan the
/// mailbox each time, and it must never show a count staler than the mailbox.
@MainActor
final class MailNeedsYouMemoTests: XCTestCase {

    private func message(from: String = "sarah@example.com", unread: Bool = true,
                         body: String = "") -> EmailMessage {
        EmailMessage(id: UUID().uuidString, accountId: UUID(), sequenceNumber: 1,
                     messageId: "", fromName: "Sarah", fromEmail: from, to: "me@example.com",
                     subject: "Invoice", date: Date(), snippet: "can you look at the invoice",
                     bodyText: body, isUnread: unread, fetchedAt: Date(), triageDraftId: nil)
    }

    func test_theMemoMatchesAFreshCountAndFollowsEveryWrite() {
        let a = message(), b = message(), c = message()
        let store = MailStore(inMemory: [a, b, c, message(unread: false),
                                         message(from: "newsletter@substack.com")])
        XCTAssertEqual(store.needsYouCount, 3)
        XCTAssertEqual(store.needsYouCount, MailNeedsYou.count(store.messages))

        store.markRead(a.id)
        XCTAssertEqual(store.needsYouCount, 2, "reading a message must lower the badge")

        store.upsert([message()])
        XCTAssertEqual(store.needsYouCount, 3, "new mail must raise the badge")

        store.update(b.id) { $0.bodyText = "Unsubscribe at any time" }
        XCTAssertEqual(store.needsYouCount, 2, "an edit in place must be seen too")

        store.remove(accountId: c.accountId)
        XCTAssertEqual(store.needsYouCount, 1)
        XCTAssertEqual(store.needsYouCount, MailNeedsYou.count(store.messages))
    }

    /// The regression this exists for: the rail calling the scan directly, once
    /// per row per render. 58 main thread samples in five idle seconds.
    func test_theRailReadsTheMemoNotTheScan() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf: root.appendingPathComponent("Sources/Grux/LaunchRootView.swift"),
                             encoding: .utf8)
        XCTAssertTrue(src.contains("mailStore.needsYouCount"), "the rail badge must read the memo")
        XCTAssertFalse(src.contains("MailNeedsYou.count("),
                       "the rail is scanning every message on every render again")
    }
}
