import XCTest
@testable import Grux

/// D168 (sense pass 21): Settings, Privacy and capture said "Grux photographs
/// your screen on a timer and sends the frame to a vision model." as a present
/// fact while Screen Recording was not allowed and screen analysis was off,
/// beside "Frames sent to a model 0 this launch". A privacy line a person acts on.
@MainActor
final class CapturePrivacyLeadTests: XCTestCase {

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    /// On and allowed: the present fact stands.
    func test_onAndAllowedSaysWhatGruxDoesNow() {
        let line = CapturePrivacyCopy.lead(analysisOn: true, watching: true, skip: nil, permitted: true)
        XCTAssertTrue(line.hasPrefix("Grux photographs your screen on a timer and sends the frame to a vision model."), line)
        XCTAssertFalse(line.contains("no frame now"), line)
    }

    /// Every other state says what Grux would do, that it is off now, and why.
    func test_offOrNotAllowedSaysItWouldAndThatItIsOffNow() {
        let cases: [(on: Bool, permitted: Bool, why: String)] = [
            (true, false, "macOS has not allowed Screen Recording."),
            (false, false, "macOS has not allowed Screen Recording."),
            (false, true, "Screen analysis is off in Settings, General."),
        ]
        for c in cases {
            let line = CapturePrivacyCopy.lead(analysisOn: c.on, watching: c.on, skip: nil, permitted: c.permitted)
            XCTAssertFalse(line.hasPrefix("Grux photographs"), "a present fact while nothing is captured: \(line)")
            XCTAssertTrue(line.contains("While Focus log runs, Grux photographs your screen on a timer and sends the frame to a vision model."), line)
            XCTAssertTrue(line.contains("It takes no frame now"), line)
            XCTAssertTrue(line.contains(c.why), "on \(c.on) permitted \(c.permitted): \(line)")
        }
    }

    /// The rest of the paragraph (what the lists below do) is kept in every state.
    func test_theListsExplanationIsKept() {
        for on in [true, false] {
            for permitted in [true, false] {
                let line = CapturePrivacyCopy.lead(analysisOn: on, watching: on, skip: nil, permitted: permitted)
                XCTAssertTrue(line.contains("These are the things it refuses to look at."), line)
                XCTAssertTrue(line.contains("so their pixels are never captured, even when the app is not in front."), line)
            }
        }
    }

    /// The caption on screen goes through the rule with the saved setting and
    /// the watcher's live state (W56-FIX), never the pane's unsaved toggle.
    func test_theSectionReadsTheRule() throws {
        let settings = try source("Sources/Grux/SettingsView.swift")
        guard let at = settings.range(of: "Section(\"Privacy and capture\")") else {
            return XCTFail("the Privacy and capture section moved; point this test at it")
        }
        let around = String(settings[at.lowerBound...].prefix(500))
        XCTAssertTrue(around.contains("CapturePrivacyCopy.lead(analysisOn: state.config.screenAnalysisEnabled, watching: state.watching, skip: state.focusSkip, permitted: state.screenPermissionGranted)"), around)
        XCTAssertFalse(settings.contains("Text(\"Grux photographs your screen"), "the fixed present-tense caption is still drawn")
    }
}
