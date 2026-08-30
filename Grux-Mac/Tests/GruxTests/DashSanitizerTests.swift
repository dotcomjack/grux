import XCTest
@testable import Grux

// DashSanitizer is the last line of defense for the global no-em/en-dash rule on
// every outbound support email. It must strip U+2014 / U+2013 but leave ASCII
// hyphens (U+002D) intact, so product copy like "2-pack" survives. [review-swarm]
final class DashSanitizerTests: XCTestCase {

    func testStripsEmDash() {
        XCTAssertEqual(DashSanitizer.clean("Looking into it \u{2014} will follow up."),
                       "Looking into it, will follow up.")
        XCTAssertEqual(DashSanitizer.clean("now\u{2014}then"), "now, then")
    }

    func testStripsEnDash() {
        XCTAssertEqual(DashSanitizer.clean("see pages 3 \u{2013} 5"), "see pages 3, 5")
    }

    func testPreservesAsciiHyphens() {
        // The old implementation turned every hyphen into a comma, corrupting
        // real product copy. These must pass through untouched.
        XCTAssertEqual(DashSanitizer.clean("cruelty-free 2-pack"), "cruelty-free 2-pack")
        XCTAssertEqual(DashSanitizer.clean("Subscribe-and-Save"), "Subscribe-and-Save")
        XCTAssertEqual(DashSanitizer.clean("no dashes here"), "no dashes here")
    }

    func testNoEmOrEnDashRemains() {
        let out = DashSanitizer.clean("a \u{2014} b \u{2013} c")
        XCTAssertFalse(out.unicodeScalars.contains("\u{2014}"))
        XCTAssertFalse(out.unicodeScalars.contains("\u{2013}"))
    }

    // The chat-display variant strips the banned dashes but must preserve
    // significant whitespace (code indentation, aligned columns) that clean()
    // would collapse. This is the regression guard for the 2026-07-19 fix.
    func testStripDashesOnlyPreservesIndentation() {
        let code = "def foo():\n    if x:\n        return 1"
        XCTAssertEqual(DashSanitizer.stripDashesOnly(code), code)
        // A double space with no dash present survives untouched.
        XCTAssertEqual(DashSanitizer.stripDashesOnly("a  b"), "a  b")
    }

    func testStripDashesOnlyRemovesDashesAndKeepsHyphens() {
        let out = DashSanitizer.stripDashesOnly("a \u{2014} b, cruelty-free, 2-pack \u{2013} done")
        XCTAssertFalse(out.unicodeScalars.contains("\u{2014}"))
        XCTAssertFalse(out.unicodeScalars.contains("\u{2013}"))
        XCTAssertTrue(out.contains("cruelty-free"))
        XCTAssertTrue(out.contains("2-pack"))
    }

    // MARK: - Every other dash scrubber in the app

    // These exist because DashSanitizer was NOT the only implementation. Three
    // more had been written by hand, and commit ccaf4ff, "sweep all em/en dashes
    // to hyphens", rewrote the em dash and en dash LITERALS inside two of them
    // along with every other dash in 195 files. The dash-removal pass disarmed
    // the dash-removal code.
    //
    // The damage was not merely inert. IssueExtractor.scrubDashes was left
    // replacing every ASCII hyphen with a comma, so it corrupted ordinary text
    // while removing no em dashes at all. DashSanitizer itself survived only
    // because it spells the banned characters as \u{2014} and \u{2013} escapes,
    // which a literal sweep cannot see.
    //
    // So the assertion that matters here is the hyphen one. A test that only
    // checked "the em dash is gone" would have passed against the corrupted
    // code, because replacing hyphens with commas also leaves no em dash behind.
    func testIssueExtractorScrubDashesRemovesDashesAndKeepsHyphens() {
        let out = IssueExtractor.scrubDashes("ship it \u{2014} then self-upgrade the e-mail flow")
        XCTAssertFalse(out.unicodeScalars.contains("\u{2014}"))
        XCTAssertTrue(out.contains("self-upgrade"), "ASCII hyphens must survive: got \(out)")
        XCTAssertTrue(out.contains("e-mail"), "ASCII hyphens must survive: got \(out)")
    }

    func testCloneExtractorStripDashesRemovesDashesAndKeepsHyphens() {
        let out = CloneExtractor.stripDashes("a \u{2013} b, well-known, 2-pack")
        XCTAssertFalse(out.unicodeScalars.contains("\u{2013}"))
        XCTAssertTrue(out.contains("well-known"), "ASCII hyphens must survive: got \(out)")
        XCTAssertTrue(out.contains("2-pack"), "ASCII hyphens must survive: got \(out)")
    }

    // Feature Review renders model-written prose directly into the tab, and had
    // no scrubbing at all. Observed live as "catch regressions<em dash>so you can
    // trust the autonomy layer".
    func testFeatureReviewPitchIsScrubbed() {
        let reply = """
        {"what":"Adds a gate \u{2014} nothing ships without review",
         "reasoning":"Guards the path \u{2013} cheaply",
         "helps":"You, on the self-upgrade path",
         "why":"So the 2-pack of checks stays honest"}
        """
        guard let pitch = FeatureReviewEngine.parse(reply) else {
            return XCTFail("pitch failed to parse")
        }
        for field in [pitch.what, pitch.reasoning, pitch.helps, pitch.why] {
            XCTAssertFalse(field.unicodeScalars.contains("\u{2014}"), "em dash survived in: \(field)")
            XCTAssertFalse(field.unicodeScalars.contains("\u{2013}"), "en dash survived in: \(field)")
        }
        XCTAssertTrue(pitch.helps.contains("self-upgrade"))
        XCTAssertTrue(pitch.why.contains("2-pack"))
    }
}
