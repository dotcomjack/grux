import XCTest
@testable import Grux

/// D166 item 4 (sense pass 20): first run's How Grux works opened on the
/// self-upgrade ladder ("Grux can improve its own code", TIER 0 to TIER 2), the
/// one thing on the screen that is off and stays off for a stranger, and its
/// privacy point said "the capture layer redacts before anything is sent",
/// jargon that also promised more than the code does (what you type goes as
/// typed; screen, mail and notification text is redacted, and a file holding a
/// secret is not read for a model at all).
@MainActor
final class HowGruxWorksOrderTests: XCTestCase {

    private var titles: [String] {
        HowItWorksStep.parts.map {
            switch $0 {
            case .point(let p): return p.title
            case .selfUpgradeLadder: return "LADDER"
            }
        }
    }

    func test_theScreenOpensOnWhatStaysHere_notOnTheSelfUpgradeLadder() {
        XCTAssertEqual(titles.first, "What stays here", "\(titles)")
    }

    func test_theLadderSitsWithTheThingsThatAreOffUntilYouSaySo() throws {
        let ladder = try XCTUnwrap(titles.firstIndex(of: "LADDER"), "the ladder left the screen: \(titles)")
        let screen = try XCTUnwrap(titles.firstIndex(of: "Screen control is off too"), "\(titles)")
        XCTAssertEqual(ladder, screen + 1, "\(titles)")
        XCTAssertEqual(titles.filter { $0 == "LADDER" }.count, 1)
    }

    func test_everyPointIsStillOnTheScreen() {
        for t in ["What stays here", "Most tabs need nothing", "Core and labs", "What it costs",
                  "You can hand the rest to your agent", "What is off until you say so",
                  "Screen control is off too", "Grux can run a terminal for you", "How to stop it"] {
            XCTAssertTrue(titles.contains(t), "\(t) is gone: \(titles)")
        }
        for w in HowItWorksStep.wayfinding { XCTAssertTrue(titles.contains(w.title), w.title) }
        XCTAssertEqual(titles.last, "How to stop it")
    }

    func test_whatStaysHereSaysWhatIsRedactedInPlainWords() {
        let line = HowItWorksStep.whatStaysHere
        XCTAssertFalse(line.contains("capture layer"), line)
        XCTAssertFalse(line.contains("before anything is sent"), "promises every send is redacted: \(line)")
        XCTAssertTrue(line.contains("API key"), line)
        XCTAssertTrue(line.contains("Your notes, mail, contacts and files are read on this Mac."), line)
        XCTAssertTrue(line.contains("Settings, General turns it off"), "the update check line is kept: \(line)")
    }

    /// The point the screen draws is the constant this test reads.
    func test_theDrawnPointIsTheConstant() {
        let drawn = HowItWorksStep.parts.compactMap { part -> String? in
            if case .point(let p) = part, p.title == "What stays here" { return p.body }
            return nil
        }
        XCTAssertEqual(drawn, [HowItWorksStep.whatStaysHere])
    }
}
