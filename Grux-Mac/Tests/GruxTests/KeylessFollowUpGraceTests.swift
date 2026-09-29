import XCTest
@testable import Grux

/// Operator ruling A7 (2026-09-27): on a keyless install the on-device
/// matcher cannot tell a reply to Grux from a television line, so inside the
/// 45 s follow-up window it gets ONE grace chunk. The first line it calls
/// not_a_command still reaches Chat; the window then ends for that reply and
/// the next one is dropped, with a line in wake.log. Measured live iter 7:
/// "the finder of lost things was on TV" 25 s after a reply went to Chat.
@MainActor
final class KeylessFollowUpGraceTests: XCTestCase {
    private func router(reply: @escaping () -> (age: TimeInterval, text: String)?) -> (VoiceCommandRouter, Box) {
        let engine = DecisionEngine(keyLookup: { "" }, ledger: DecisionLedger(storeURL: nil))
        let r = VoiceCommandRouter(engine: engine, threshold: { 0.70 }, macros: { [] })
        let box = Box()
        r.recentReply = reply
        r.sendToChat = { box.sent.append($0) }
        r.log = { box.logged.append($0) }
        return (r, box)
    }

    final class Box { var sent: [String] = []; var logged: [String] = [] }

    func test_keyless_theWindowEndsAfterOneGraceChunk() async {
        let (r, box) = router(reply: { (age: 20, text: "Here is your summary.") })
        let first = await r.consider(chunk: "yes send that one to my sister please")
        await r.chatHandOff?.value
        let second = await r.consider(chunk: "the finder of lost things was on TV")
        await r.chatHandOff?.value
        XCTAssertEqual(first?.outcome, .executed, "the first line after a reply is the grace chunk")
        XCTAssertEqual(second?.outcome, .ignored, "the window ended after the grace chunk")
        XCTAssertEqual(second?.commandId, LocalDecisionProvider.notACommand)
        XCTAssertEqual(box.sent, ["yes send that one to my sister please"])
        XCTAssertTrue(box.logged.contains { $0.contains("follow-up window closed") && $0.contains("the finder of lost things") },
                      "the drop is logged: \(box.logged)")
    }

    func test_aNewReplyOpensANewWindowWithItsOwnGrace() async {
        var reply: (age: TimeInterval, text: String) = (age: 20, text: "Here is your summary.")
        let (r, box) = router(reply: { reply })
        _ = await r.consider(chunk: "yes send that one to my sister please")
        await r.chatHandOff?.value
        reply = (age: 3, text: "Sent it to your sister.")
        let next = await r.consider(chunk: "thanks and what is on tomorrow")
        await r.chatHandOff?.value
        XCTAssertEqual(next?.outcome, .executed)
        XCTAssertEqual(box.sent.count, 2)
    }

    func test_byNameStillReachesGruxAfterTheGraceIsSpent() async {
        let (r, box) = router(reply: { (age: 20, text: "Here is your summary.") })
        _ = await r.consider(chunk: "yes send that one to my sister please")
        _ = await r.consider(chunk: "the finder of lost things was on TV")
        let named = await r.consider(chunk: "hey Grux what did you just say")
        await r.chatHandOff?.value
        XCTAssertEqual(named?.outcome, .executed)
        XCTAssertEqual(box.sent.count, 2)
    }

    func test_aCommandInsideTheWindowDoesNotSpendTheGrace() async {
        let (r, box) = router(reply: { (age: 20, text: "Here is your summary.") })
        r.navigate = { _ in }
        let cmd = await r.consider(chunk: "open my calendar")
        let answer = await r.consider(chunk: "yes send that one to my sister please")
        await r.chatHandOff?.value
        XCTAssertEqual(cmd?.commandId, "tab:calendar")
        XCTAssertEqual(answer?.outcome, .executed)
        XCTAssertEqual(box.sent, ["yes send that one to my sister please"])
    }
}
