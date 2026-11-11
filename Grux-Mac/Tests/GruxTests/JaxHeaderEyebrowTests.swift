import XCTest
@testable import Grux

// D192 (3): Jax HQ and Jax Command opened under "YOUR CLONE, BETWEEN CHECK-INS" and
// "THE CONTROL ROOM FOR YOUR CLONE", a word neither pane explains to a stranger. The
// Labs shelf already says in plain words what each pane is for, so each header line
// is the opening of that shelf line, and the two cannot drift apart.
@MainActor
final class JaxHeaderEyebrowTests: XCTestCase {

    func testNoHeaderLineSaysClone() {
        for line in [JaxHQView.eyebrowText, JaxCommandView.eyebrowText] {
            XCTAssertFalse(line.lowercased().contains("clone"), line)
        }
    }

    func testEachHeaderLineOpensTheLabsShelfLineForItsPane() throws {
        let hq = try XCTUnwrap(LabsShelf.lines["jax.hq"])
        let command = try XCTUnwrap(LabsShelf.lines["jax.command"])
        XCTAssertFalse(JaxHQView.eyebrowText.isEmpty)
        XCTAssertFalse(JaxCommandView.eyebrowText.isEmpty)
        XCTAssertTrue(hq.hasPrefix(JaxHQView.eyebrowText), "\(JaxHQView.eyebrowText) | \(hq)")
        XCTAssertTrue(command.hasPrefix(JaxCommandView.eyebrowText), "\(JaxCommandView.eyebrowText) | \(command)")
    }

    func testTheHeaderLinesAreTheWordsAStrangerReads() {
        XCTAssertEqual(JaxHQView.eyebrowText, "The inbox agent's desk")
        XCTAssertEqual(JaxCommandView.eyebrowText, "Goals Grux pursues on its own")
    }

    func testBothViewsDrawTheirHeaderLineFromTheConstant() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        for file in ["JaxHQView.swift", "JaxCommandView.swift"] {
            let src = try String(contentsOf: root.appendingPathComponent("Sources/Grux/Jax/\(file)"), encoding: .utf8)
            XCTAssertTrue(src.contains("MetaAdsEyebrow(text: Self.eyebrowText"), file)
        }
    }
}
