import XCTest
@testable import GruxSetupCore

/// `grux add` reports the exit code its own rows justify.
///
/// It ended in an unconditional `leave(.done)` two lines after drawing those rows with the
/// needed glyph, so every first-time `grux add mailbox` printed a needed Password row, said
/// only the Grux Mailbox window could take it, said the account would not sync until then,
/// and exited 0. This surface defines 0 as everything asked for being satisfied.
///
/// The two failure kinds are separate codes because they need different responses, and from
/// the CLI side they are indistinguishable, which is why the app labels them. A password
/// only a person can paste is exit 2: no invocation of this command can ever supply it. A
/// file that would not write is exit 1: the same call succeeds once the disk does.
final class AddOutcomeTests: XCTestCase {

    private func row(_ what: String, failed: Bool = false, needsPerson: Bool = false)
        -> [String: Any] {
        ["what": what, "where": "somewhere", "already": false,
         "failed": failed, "needsPerson": needsPerson]
    }

    func testEverythingLandedIsDone() {
        XCTAssertEqual(Exit.forWriteRows( [row("Mail accounts"), row("Registry")]), .done)
    }

    /// The measured case: a brand new mailbox, where the password cannot arrive here at all.
    func testARowOnlyAPersonCanFinishIsWaitingOnYou() {
        let rows = [row("Mail accounts"),
                    row("Password", failed: true, needsPerson: true)]
        XCTAssertEqual(Exit.forWriteRows( rows), .waitingOnYou,
            "a row no invocation of this command can ever satisfy is exactly what exit 2 "
            + "exists for, and reporting 0 tells an agent the work is finished")
    }

    /// A write that did not land is a retry, not a person.
    func testARowThatMerelyFailedIsFailed() {
        let rows = [row("Registry"), row("Spoken name", failed: true)]
        XCTAssertEqual(Exit.forWriteRows( rows), .failed,
            "a file that would not write succeeds on the same call once the disk does, so "
            + "reporting 2 would wake somebody up for nothing")
    }

    /// Precedence, and it is the only order that makes sense: if anything needs a person,
    /// the person is the blocker whatever else also went wrong.
    func testAPersonBeatsAPlainFailure() {
        let rows = [row("Spoken name", failed: true),
                    row("Password", failed: true, needsPerson: true)]
        XCTAssertEqual(Exit.forWriteRows( rows), .waitingOnYou)
    }

    /// An absent key is not a failure. The app has shipped rows without these flags and a
    /// missing one must read as fine rather than as broken.
    func testRowsWithNoFlagsAtAllAreDone() {
        XCTAssertEqual(Exit.forWriteRows( [["what": "Registry", "where": "x"]]), .done)
        XCTAssertEqual(Exit.forWriteRows( []), .done)
    }
}

/// How a `grux repair` run ends when something on the Mac needs a person.
///
/// Both run paths exited 0 whenever nothing they touched got stuck, on a Mac where doctor
/// had already found something only a person can fix, and neither mentioned it. An agent
/// reads 0 as "report done". It got worse once the LISTING learned to exit 3, because the
/// help then points at `--all` as the answer to a 3 and `--all` reported everything done.
final class RepairOutcomeTests: XCTestCase {

    func testNothingStuckAndNothingUnfixableIsDone() {
        XCTAssertEqual(Exit.forRepair(stuck: 0, unfixable: 0), .done)
    }

    /// The measured case: every repair took, and something else still needs a person.
    func testRepairingEverythingDoesNotClearWhatNeedsAPerson() {
        XCTAssertEqual(Exit.forRepair(stuck: 0, unfixable: 1), .waitingOnYou,
            "every repair ran and took, and a thing no repair can touch is still on this "
            + "Mac, so reporting done tells an agent to stop looking at it")
    }

    func testARepairThatDidNotTakeIsAlsoWaiting() {
        XCTAssertEqual(Exit.forRepair(stuck: 1, unfixable: 0), .waitingOnYou)
        XCTAssertEqual(Exit.forRepair(stuck: 2, unfixable: 3), .waitingOnYou)
    }
}
