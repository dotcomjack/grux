import XCTest
@testable import Grux

final class LocalDecisionProviderTests: XCTestCase {
    let criteria = [
        "close_all": "close everything | close all windows | clear my screen",
        "open_calendar": "open my calendar | show the calendar",
        "not_a_command": "talking to someone else, thinking out loud, or nothing Grux can do",
    ]

    func test_exactPhrase_winsWithHighConfidence() {
        let a = LocalDecisionProvider.matchChoice(state: "okay close everything please", criteria: criteria)
        guard case .choice(let opt, let conf, _) = a else { return XCTFail("not a choice") }
        XCTAssertEqual(opt, "close_all")
        XCTAssertGreaterThanOrEqual(conf, 0.9)
    }

    func test_chatter_fallsToNotACommand() {
        let a = LocalDecisionProvider.matchChoice(state: "so I was thinking about the pricing page", criteria: criteria)
        guard case .choice(let opt, let conf, _) = a else { return XCTFail("not a choice") }
        XCTAssertEqual(opt, "not_a_command")
        XCTAssertGreaterThan(conf, 0.5)
    }

    func test_partialWords_neverExecuteACommand() {
        // Two shared words out of four is not a command. The honest answer is
        // not_a_command, and the command option itself scores well under the
        // execute threshold.
        let a = LocalDecisionProvider.matchChoice(state: "the calendar thing", criteria: criteria)
        guard case .choice(let opt, _, let probs) = a else { return XCTFail("not a choice") }
        XCTAssertEqual(opt, "not_a_command")
        XCTAssertLessThan(probs["open_calendar"] ?? 1, 0.70)
    }

    func test_noul_isNeverConfidentOnDevice() async throws {
        let r = try await LocalDecisionProvider().decide(state: "anything", questions: ["q": .noul(instructions: "Is it urgent?")])
        XCTAssertEqual(r.answers["q"], .noul(0.5))
        XCTAssertEqual(r.provider, .local)
    }
}
