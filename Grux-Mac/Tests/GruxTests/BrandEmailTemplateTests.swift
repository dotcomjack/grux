import XCTest
@testable import Grux

// Tests for the brand email formatting that wraps support replies in HTML.
final class BrandEmailTemplateTests: XCTestCase {

    func testParagraphsSplitEscapeAndBreak() {
        let html = BrandEmailTemplate.paragraphs("Hi <Ada> & team\nline two\n\nSecond para", ink: "#111")
        XCTAssertEqual(html.components(separatedBy: "<p ").count - 1, 2)  // two paragraphs
        XCTAssertTrue(html.contains("Hi &lt;Ada&gt; &amp; team"))         // escaped
        XCTAssertTrue(html.contains("line two"))
        XCTAssertTrue(html.contains("<br>"))                                // single newline -> br
        XCTAssertTrue(html.contains("Second para"))
        XCTAssertFalse(html.contains("<Ada>"))                              // no raw angle brackets
    }

    func testShellCarriesTheBrandVoiceAndTheReply() {
        let html = BrandEmailTemplate.html(voice: "acme", replyText: "We will look it up by your email.")
        XCTAssertTrue(html.contains("<!doctype html"))
        XCTAssertTrue(html.contains("ACME"))                                // header eyebrow
        XCTAssertTrue(html.contains("We will look it up by your email."))   // the reply body
    }

    // The shell is deliberately generic. The brand voice token is the ONLY
    // thing that varies between two brands: no palette, tagline, font, postal
    // line, or site is compiled in for any particular company.
    func testShellShipsNoCompiledInBrandData() {
        let a = BrandEmailTemplate.html(voice: "acme", replyText: "Thanks for reaching out.")
        let b = BrandEmailTemplate.html(voice: "globex", replyText: "Thanks for reaching out.")
        XCTAssertTrue(a.contains("ACME"))
        XCTAssertTrue(b.contains("GLOBEX"))
        XCTAssertFalse(a.contains("GLOBEX"))
        XCTAssertFalse(b.contains("ACME"))
        // Strip the eyebrow and title and the two shells are byte-identical.
        XCTAssertEqual(
            a.replacingOccurrences(of: "ACME", with: "BRAND"),
            b.replacingOccurrences(of: "GLOBEX", with: "BRAND")
        )
    }

    // No site is configured, so the footer renders no link rather than a
    // broken or borrowed one.
    func testFooterLinkOmittedWhenNoSiteConfigured() {
        let html = BrandEmailTemplate.html(voice: "acme", replyText: "Thanks for reaching out.")
        XCTAssertFalse(html.contains("<a href=\"https://"))
    }
}
