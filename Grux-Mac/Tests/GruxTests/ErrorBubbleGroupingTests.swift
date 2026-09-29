import XCTest
@testable import Grux

final class ErrorBubbleGroupingTests: XCTestCase {
    private func notice(_ text: String) -> ChatMessage {
        ChatMessage(role: .assistant, content: text, isNotice: true)
    }
    private func real(_ text: String) -> ChatMessage {
        ChatMessage(role: .assistant, content: text)
    }

    func test_aRunOfTheSameNoticeCollapsesToOneRowWithACount() {
        let rows = ErrorBubbleGrouping.group([notice("no model"), notice("no model"), notice("no model")])
        XCTAssertEqual(rows.count, 1)
        guard case .repeatedNotice(let m, let n) = rows[0] else { return XCTFail("not grouped") }
        XCTAssertEqual(n, 3)
        XCTAssertEqual(m.content, "no model")
    }

    func test_oneNoticeIsStillJustOneNotice() {
        let rows = ErrorBubbleGrouping.group([notice("no model")])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].count, 1)
        XCTAssertEqual(ErrorBubbleGrouping.repeatLabel(count: 1), "", "\"1 time\" is noise")
        XCTAssertEqual(ErrorBubbleGrouping.repeatLabel(count: 4), "4 times")
    }

    func test_differentNoticesDoNotCollapseIntoEachOther() {
        let rows = ErrorBubbleGrouping.group([notice("no model"), notice("no key")])
        XCTAssertEqual(rows.count, 2)
    }

    /// A run must be consecutive, or the transcript reorders itself and an
    /// error appears above the turn that caused it.
    func test_aRealMessageBreaksTheRun() {
        let rows = ErrorBubbleGrouping.group([notice("no model"), real("hello"), notice("no model")])
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0].count, 1)
        XCTAssertEqual(rows[2].count, 1)
    }

    func test_ordinaryConversationIsUntouched() {
        let rows = ErrorBubbleGrouping.group([real("a"), real("b"), real("c")])
        XCTAssertEqual(rows.count, 3)
        for r in rows {
            guard case .message = r else { return XCTFail("a real message was grouped") }
        }
    }

    func test_everyMessageSurvivesInSomeRow() {
        let msgs = [real("a"), notice("x"), notice("x"), real("b"), notice("y")]
        let rows = ErrorBubbleGrouping.group(msgs)
        XCTAssertEqual(rows.map(\.count).reduce(0, +), msgs.count,
                       "grouping dropped or duplicated a message")
    }

    func test_anEmptyThreadGroupsToNothing() {
        XCTAssertTrue(ErrorBubbleGrouping.group([]).isEmpty)
    }

    /// The measured case: six failed turns in one thread, which is what put
    /// the same line in the history often enough to teach the model to repeat
    /// it. One card now, not six bubbles.
    func test_theMeasuredSixFailureCaseIsOneCard() {
        let six = (0..<6).map { _ in notice("invalid message format. Retry once that is resolved.") }
        let rows = ErrorBubbleGrouping.group(six)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].count, 6)
        XCTAssertEqual(ErrorBubbleGrouping.repeatLabel(count: rows[0].count), "6 times")
    }
}
