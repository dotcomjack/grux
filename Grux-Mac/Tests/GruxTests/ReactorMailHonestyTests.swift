import XCTest
@testable import Grux

/// D30 (3.2 sense pass): the Reactor's Mailbox card read "0 / Inbox zero" and
/// its ring "MAIL 0" on a Mac with no mailbox set up, while Now said "Set up
/// Mailbox". Zero unread from no mailbox is not an empty inbox.
final class ReactorMailHonestyTests: XCTestCase {
    func test_noMailboxIsNotInboxZero() {
        let none = ReactorView.mailboxReadout(hasAccount: false, unread: 0, newest: "")
        XCTAssertEqual(none.value, "Off")
        XCTAssertEqual(none.sub, "Not set up")
        XCTAssertEqual(ReactorView.mailRingReadout(hasAccount: false, unread: 0), "off")

        let zero = ReactorView.mailboxReadout(hasAccount: true, unread: 0, newest: "")
        XCTAssertEqual(zero.value, "0")
        XCTAssertEqual(zero.sub, "Inbox zero")
        XCTAssertEqual(ReactorView.mailRingReadout(hasAccount: true, unread: 0), "0")

        let some = ReactorView.mailboxReadout(hasAccount: true, unread: 3, newest: "Ana")
        XCTAssertEqual(some.value, "3")
        XCTAssertEqual(some.sub, "from Ana")
        XCTAssertEqual(ReactorView.mailboxReadout(hasAccount: true, unread: 3, newest: "").sub, "unread")
    }

    func test_theCardAndTheRingAskWhetherAMailboxExists() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf: root.appendingPathComponent("Sources/Grux/Reactor/ReactorView.swift"), encoding: .utf8)
        XCTAssertEqual(src.components(separatedBy: "hasAccount: !accounts.accounts.isEmpty").count - 1, 2,
                       "the card or the ring reads unread mail without asking whether a mailbox exists")
        XCTAssertFalse(src.contains("unread == 0 ? \"Inbox zero\""), "Inbox zero chosen from the count alone")
    }

    /// D51 (sense pass 3): the Meta Ads card read "$0.00" beside "offline" for a service that is
    /// not set up. No snapshot is no spend: the card says not set up, or offline when it is set
    /// up and did not answer, and shows a dollar figure only from a snapshot.
    func test_noMetaAdsSnapshotIsNoSpend() {
        let absent = ReactorView.metaAdsReadout(spendCents: nil, mode: nil, attention: 0, notSetUp: true)
        XCTAssertEqual(absent.value, "Off")
        XCTAssertEqual(absent.sub, "Not set up")
        let down = ReactorView.metaAdsReadout(spendCents: nil, mode: nil, attention: 0, notSetUp: false)
        XCTAssertEqual(down.value, "Offline")
        XCTAssertEqual(down.sub, "No numbers yet")
        let zero = ReactorView.metaAdsReadout(spendCents: 0, mode: "OBSERVE", attention: 2, notSetUp: false)
        XCTAssertEqual(zero.value, "$0.00", "a real snapshot with no spend today is $0.00")
        XCTAssertEqual(zero.sub, "OBSERVE · 2 need you")
        XCTAssertEqual(ReactorView.metaAdsReadout(spendCents: 1234, mode: "LIVE", attention: 0, notSetUp: true).value,
                       "$12.34", "a snapshot wins over a stale absence verdict")
    }
}
