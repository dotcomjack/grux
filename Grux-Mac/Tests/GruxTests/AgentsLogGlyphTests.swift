import XCTest
import GruxAgentCore
@testable import Grux

/// D179 item 9: the Agents log drew "🎼" (a musical score, a pun on "orchestrator")
/// beside "job ended status=failed", so a stranger read a failed job as music. Every
/// line's glyph says what kind of line it is, and none is a music symbol.
final class AgentsLogGlyphTests: XCTestCase {
    private let kinds: [AgentStep.Kind] = [
        .workerStart, .workerEnd, .assistantText, .toolUse, .toolResult, .usage, .error,
        .orchestrator, .approvalRequested, .approvalGranted, .info,
        .authLimitDetected, .accountSwitched, .workerResumed,
    ]

    private func isMusic(_ s: Unicode.Scalar) -> Bool {
        (0x1F3B5...0x1F3BC).contains(s.value)     // musical note, notes, score, keyboard, instruments
            || (0x2669...0x266F).contains(s.value) // quarter note to sharp sign
            || (0x1D100...0x1D1FF).contains(s.value) // Musical Symbols block
    }

    func test_noLogGlyphIsAMusicSymbol() {
        for kind in kinds {
            let glyph = JobDetailView.prefix(for: kind)
            XCTAssertFalse(glyph.unicodeScalars.contains(where: isMusic), "\(kind) draws \(glyph)")
        }
    }

    func test_aJobLevelLineReadsAsTheJobsOwnMark() {
        XCTAssertEqual(JobDetailView.prefix(for: .orchestrator), "◆")
    }
}
