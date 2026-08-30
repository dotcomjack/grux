import XCTest
@testable import Grux

// DocumentAIAssist.rewrite has a model rewrite the whole document body, and the
// editor writes the result straight back into the user's file. Its only defence
// against the banned dashes was a line in the system prompt, which is exactly
// the instruction-only enforcement DashSanitizer was written because of.
//
// These matter more than the other scrub tests: a dash that slips through here
// is not a display glitch, it is persisted into the owner's document.
final class DocumentAIAssistNormalizeTests: XCTestCase {

    func testStripsBannedDashesFromARewrite() {
        let out = DocumentAIAssist.normalizeRewrite("Ship the thing \u{2014} then write it up.")
        XCTAssertFalse(out.unicodeScalars.contains("\u{2014}"), "em dash would be saved to the document: \(out)")
        XCTAssertFalse(out.unicodeScalars.contains("\u{2013}"))
    }

    func testTrimsSurroundingWhitespaceAsBefore() {
        XCTAssertEqual(DocumentAIAssist.normalizeRewrite("\n  # Title\n\nBody.\n  "), "# Title\n\nBody.")
    }

    // A document is markdown, so stripDashesOnly is the right variant: clean()
    // collapses runs of spaces and would silently reindent fenced code and
    // nested lists inside somebody's document.
    func testPreservesMarkdownIndentationAndCodeBlocks() {
        let doc = "- item\n    - nested\n\n```swift\nfunc f() {\n    return 1\n}\n```"
        XCTAssertEqual(DocumentAIAssist.normalizeRewrite(doc), doc)
    }

    func testPreservesAsciiHyphens() {
        let out = DocumentAIAssist.normalizeRewrite("A self-hosted, well-known 2-pack.")
        XCTAssertTrue(out.contains("self-hosted"), "ASCII hyphen mangled: \(out)")
        XCTAssertTrue(out.contains("well-known"))
        XCTAssertTrue(out.contains("2-pack"))
    }
}
