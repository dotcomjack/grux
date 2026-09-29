import XCTest
@testable import Grux

/// What the decision provider is shown when it is asked whether a matched PIM
/// plan is what the person asked for. Live on 2026-09-27 with a Jev key, the
/// state named only the card title and time ("Lunch with Sarah. Fri Oct 2
/// 1:00 PM"), never the action and never today's date, and Jev held back
/// `put lunch with Sarah on my calendar Friday at 1pm` at 0.33 and a plain
/// `take a note that ...` at 0.46. The question tells it to answer low when a
/// date was guessed, and it had nothing to check "Friday" against.
final class PIMJudgeStateTests: XCTestCase {

    private let sunday = ISO8601DateFormatter().date(from: "2026-09-27T16:00:00Z")!

    func test_calendarStateNamesTheActionAndToday() throws {
        let words = "put lunch with Sarah on my calendar Friday at 1pm"
        let plan = try XCTUnwrap(ChatIntentClassifier.pimRoute(utterance: words, now: sunday))
        let state = ChatIntentClassifier.pimState(plan: plan, utterance: words, today: sunday)
        XCTAssertTrue(state.contains("add a calendar event"), state)
        XCTAssertTrue(state.contains("Today is Sunday, September 27 2026."), state)
        XCTAssertTrue(state.contains("Lunch with Sarah"), state)
    }

    func test_noteStateNamesTheAction() throws {
        let words = "take a note that the fence needs paint"
        let plan = try XCTUnwrap(ChatIntentClassifier.pimRoute(utterance: words, now: sunday))
        let state = ChatIntentClassifier.pimState(plan: plan, utterance: words, today: sunday)
        XCTAssertTrue(state.contains("save a note"), state)
    }

    func test_everyKindHasAnAction() {
        for kind in PIMIntentKind.allCases {
            XCTAssertFalse(kind.judgeAction.isEmpty, kind.rawValue)
        }
    }
}
