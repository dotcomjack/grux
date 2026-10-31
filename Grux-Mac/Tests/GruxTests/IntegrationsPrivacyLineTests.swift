import XCTest
@testable import Grux

/// Integrations' header is a privacy sentence a person relies on, so it says
/// only what the code does. It said "Nothing is sent to a server." above
/// Slack, Notion, the Decisions key and outbound webhooks, every one of which
/// sends to a server (sense pass 5, `s5-shots/integrations-1.png`, D69).
final class IntegrationsPrivacyLineTests: XCTestCase {

    func test_theHeaderNeverSaysNothingIsSent() {
        let line = IntegrationsView.headerLine.lowercased()
        XCTAssertFalse(line.contains("nothing is sent"), "every section on this pane sends to a service: \(line)")
        XCTAssertFalse(line.contains("nothing leaves"), line)
    }

    /// What is true: the tokens sit in the Keychain, and each service is
    /// reached straight from this Mac with no Grux server between.
    func test_theHeaderSaysWhatReallyHappens() {
        let line = IntegrationsView.headerLine
        XCTAssertTrue(line.contains("Keychain"), line)
        XCTAssertTrue(line.contains("no Grux server"), line)
    }

    /// The pane draws the line from the constant, so the test reads what a
    /// person reads.
    func test_thePaneDrawsTheTestedLine() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(contentsOf: root.appendingPathComponent("Sources/Grux/Integrations/IntegrationsView.swift"),
                              encoding: .utf8)
        XCTAssertTrue(view.contains("Text(Self.headerLine)"), "the header no longer draws the tested line")
        XCTAssertEqual(view.components(separatedBy: "Nothing is sent").count, 1,
                       "the old sentence is back somewhere on the pane")
    }
}
