import XCTest
@testable import Grux

/// THE MODEL'S REPLY IS UNTRUSTED. `FileNamePrompt.clean` is the only way a
/// reply becomes a file name, and nil means "leave the file alone". Each case
/// here is a way a reply could hurt: leave the folder, hide the file, invent
/// words the file does not hold, or put a number someone wants private into
/// Finder.
final class FileNamePromptTests: XCTestCase {

    private let source = """
    Northwind Studio
    Invoice 2041
    October 2026
    Design retainer for Acme Corp
    Amount due 1,250.00 USD
    """

    func testAPlainReplyIsKept() {
        XCTAssertEqual(FileNamePrompt.clean("Northwind Studio Invoice Oct 2026", sourceText: source),
                       "Northwind Studio Invoice Oct 2026")
    }

    func testQuotesBackticksAndMarkdownAreTrimmed() {
        XCTAssertEqual(FileNamePrompt.clean("\"Northwind Studio Invoice\"", sourceText: source), "Northwind Studio Invoice")
        XCTAssertEqual(FileNamePrompt.clean("`Northwind Studio Invoice`", sourceText: source), "Northwind Studio Invoice")
        XCTAssertEqual(FileNamePrompt.clean("**Northwind Studio Invoice**", sourceText: source), "Northwind Studio Invoice")
        XCTAssertEqual(FileNamePrompt.clean("# Northwind Studio Invoice", sourceText: source), "Northwind Studio Invoice")
        XCTAssertEqual(FileNamePrompt.clean("\u{201C}Northwind Studio Invoice\u{201D}", sourceText: source),
                       "Northwind Studio Invoice")
    }

    func testOnlyTheFirstLineCounts() {
        XCTAssertEqual(FileNamePrompt.clean("\nAcme Corp Retainer Invoice\nThis is an invoice from", sourceText: source),
                       "Acme Corp Retainer Invoice")
    }

    func testAPathSeparatorCannotLeaveTheFolder() {
        let got = FileNamePrompt.clean("Northwind/Studio:Invoice", sourceText: source)
        XCTAssertEqual(got, "Northwind Studio Invoice")
        XCTAssertFalse(got?.contains("/") ?? true)
        let climb = FileNamePrompt.clean("../../Northwind Invoice", sourceText: source)
        XCTAssertNotNil(climb)
        XCTAssertFalse(climb?.contains("/") ?? true)
        XCTAssertFalse(climb?.hasPrefix(".") ?? true, "a leading period would hide the file in Finder")
    }

    func testATrailingExtensionOrPeriodIsDropped() {
        XCTAssertEqual(FileNamePrompt.clean("Northwind Studio Invoice.pdf", sourceText: source), "Northwind Studio Invoice")
        XCTAssertEqual(FileNamePrompt.clean("Northwind Studio Invoice.", sourceText: source), "Northwind Studio Invoice")
    }

    /// EVERY TRAILING EXTENSION GOES. A reply of `Acme Invoice.pdf.txt` used
    /// to lose only `.txt`, so a PNG became `Acme Invoice.pdf.png`, which
    /// Finder, hiding the real extension, shows as a PDF (review 2026-10-28).
    func testEveryTrailingExtensionIsStripped() {
        XCTAssertEqual(FileNamePrompt.clean("Northwind Invoice.pdf.txt", sourceText: source), "Northwind Invoice")
        XCTAssertEqual(FileNamePrompt.clean("Northwind Invoice.PDF.TXT.", sourceText: source), "Northwind Invoice")
        XCTAssertEqual(FileNamePrompt.clean("\"Northwind Invoice.pdf\".", sourceText: source), "Northwind Invoice")
        XCTAssertEqual(FileNamePrompt.clean("Northwind Invoice.pdf.png", sourceText: source, fileExtension: "png"),
                       "Northwind Invoice")
        // The file's own extension counts even when it is not a known one.
        XCTAssertEqual(FileNamePrompt.clean("Northwind Invoice.xyz", sourceText: source, fileExtension: "xyz"),
                       "Northwind Invoice")
        XCTAssertEqual(FileNamePrompt.clean("Northwind Invoice.xyz", sourceText: source), "Northwind Invoice.xyz",
                       "control: an unknown tail that is not the file's own stays")
        XCTAssertEqual(FileNamePrompt.clean("Northwind Release v2.1", sourceText: source), "Northwind Release v2.1",
                       "a version number is not an extension")
    }

    func testAnOverlongReplyIsCutAtAWordBoundary() {
        let long = "Northwind Studio Invoice October 2026 Design Retainer For Acme Corp Amount Due"
        let got = FileNamePrompt.clean(long, sourceText: source)
        XCTAssertNotNil(got)
        XCTAssertLessThanOrEqual(got?.count ?? 99, FileNamePrompt.maxCharacters)
        XCTAssertLessThanOrEqual(got?.split(separator: " ").count ?? 99, FileNamePrompt.maxWords)
        XCTAssertTrue(long.hasPrefix(got ?? "-"), "the cut is not at a word boundary: \(got ?? "nil")")
        let oneHugeWord = String(repeating: "Northwind", count: 10) + " Invoice"
        XCTAssertNil(FileNamePrompt.clean(oneHugeWord, sourceText: source),
                     "a single word over the cap cannot be cut to a name")
    }

    /// THE HALLUCINATION GUARD. A name with no word from the file is not a
    /// name for this file.
    /// WHOLE WORDS. "Ice" is inside "Invoice" and "The" is inside almost any
    /// text, so a substring match let an invented name through
    /// (review 2026-10-28).
    func testGroundingIsByWholeWordsNotSubstrings() {
        let invoice = "Invoice 2041\nUnit price 40.00\nThere is a late fee"
        XCTAssertNil(FileNamePrompt.clean("Ice Hockey Tickets", sourceText: invoice), "Ice is only inside Invoice")
        XCTAssertNil(FileNamePrompt.clean("The Rice Event", sourceText: invoice), "The and Rice are only inside other words")
        XCTAssertNotNil(FileNamePrompt.clean("Late Fee Invoice", sourceText: invoice), "control: whole words ground it")
        XCTAssertNotNil(FileNamePrompt.clean("Unit Price Sheet", sourceText: invoice), "control")
    }

    func testANameWithNoWordFromTheFileIsRefused() {
        XCTAssertNil(FileNamePrompt.clean("Quarterly Tax Return", sourceText: source))
        XCTAssertNotNil(FileNamePrompt.clean("Quarterly Northwind Return", sourceText: source),
                        "control: one grounded word is enough")
        XCTAssertNotNil(FileNamePrompt.clean("NORTHWIND billing", sourceText: source), "case does not matter")
        XCTAssertNotNil(FileNamePrompt.clean("Cafe Specials", sourceText: "CAF\u{00C9} MENU for the week"),
                        "diacritics do not matter")
    }

    /// THE SECRET GUARD. A run of six digits could be an account or a card.
    func testADigitRunIsRefused() {
        XCTAssertNil(FileNamePrompt.clean("Northwind Card 4111111111111111", sourceText: source))
        XCTAssertNil(FileNamePrompt.clean("Northwind Account 123456", sourceText: source))
        // A card or account number written in groups is the same number
        // (review 2026-10-28).
        XCTAssertNil(FileNamePrompt.clean("Northwind Card 4111 1111 1111 1111", sourceText: source))
        XCTAssertNil(FileNamePrompt.clean("Northwind Card 4111-1111-1111-1111", sourceText: source))
        XCTAssertNil(FileNamePrompt.clean("Northwind Account 12 34 56", sourceText: source))
        XCTAssertNil(FileNamePrompt.clean("Northwind Account 123-456", sourceText: source))
        XCTAssertNotNil(FileNamePrompt.clean("Northwind Invoice 2041 Oct", sourceText: source),
                        "control: four digits then a word is not a run")
        XCTAssertNotNil(FileNamePrompt.clean("Northwind Invoice 2041", sourceText: source), "control: a short number is fine")
        XCTAssertNil(FileNamePrompt.clean("Northwind [REDACTED:key] Invoice", sourceText: source))
    }

    func testAOneWordReplyIsRefused() {
        XCTAssertNil(FileNamePrompt.clean("Northwind", sourceText: source))
        XCTAssertNil(FileNamePrompt.clean("Invoice.", sourceText: source))
    }

    func testAnEmptyReplyIsRefused() {
        XCTAssertNil(FileNamePrompt.clean("", sourceText: source))
        XCTAssertNil(FileNamePrompt.clean("  \n \n", sourceText: source))
        XCTAssertNil(FileNamePrompt.clean("\"\"", sourceText: source))
    }

    func testTheUserMessageCarriesTheText() {
        let message = FileNamePrompt.user(text: "Northwind Studio")
        XCTAssertTrue(message.contains("Northwind Studio"))
        XCTAssertFalse(FileNamePrompt.system.isEmpty)
    }
}
