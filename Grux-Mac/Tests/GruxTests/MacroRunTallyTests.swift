import XCTest
@testable import Grux

/// `grux run <macro>` said `3 steps: 3 ran and reported back` when two of the
/// three came back refused (silent mode, iter 23). A step that answered with an
/// error still reported back, but it did not do its work, and the tally is the
/// one line a person reads.
final class MacroRunTallyTests: XCTestCase {
    func test_failedSteps_countsTheWaitedStepsThatAnsweredWithAnError() {
        let report = """
        running macro 'loop_silent_steps':
          - error: shell exit -1
        refused: silent mode is on (~/.grux/SILENT) and `afplay` would make sound
          - error: refused: silent mode is on (~/.grux/SILENT) and this AppleScript would make sound
          - ok: shell exit 0
        """
        XCTAssertEqual(GruxControlTools.failedSteps(inReport: report), 2)
    }

    func test_failedSteps_ignoresDetachedDisabledAndOkSteps() {
        let report = """
        running macro 'm':
          - ok: waited 1.0s
          - (detached) shell: echo error
          - (disabled, skipped) speak "error"
        """
        XCTAssertEqual(GruxControlTools.failedSteps(inReport: report), 0)
    }
}
