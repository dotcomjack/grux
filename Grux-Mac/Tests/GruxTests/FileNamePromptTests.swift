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

    /// grux-local:4b once handed back a prompt example for a file it did not
    /// describe (2026-10-28). A name carrying an example's words the file
    /// lacks is refused; the same words drawn from the file are fine.
    func testACopiedPromptExampleIsRefused() {
        let typescript = "src/api/orders.ts(14,7): error TS2322: Type 'string' is not assignable to type 'number'.\nFound 1 error."
        XCTAssertNil(FileNamePrompt.clean("Rust Borrow Checker Error", sourceText: typescript, fileExtension: "png"))
        XCTAssertEqual(FileNamePrompt.clean("TypeScript Type Error", sourceText: "TypeScript " + typescript, fileExtension: "png"),
                       "TypeScript Type Error", "control: a grounded name passes")
        let rust = "error[E0502]: cannot borrow `ledger` as mutable because it is also borrowed as immutable\nrustc checker"
        XCTAssertEqual(FileNamePrompt.clean("Rust Borrow Checker Error", sourceText: rust, fileExtension: "png"),
                       "Rust Borrow Checker Error", "the example's words drawn from the file are fine")
        for example in FileNamePrompt.examples {
            XCTAssertTrue(FileNamePrompt.system.contains(example), "\(example) is not in the prompt, so the guard is stale")
        }
    }

    /// A STOP WORD GROUNDS NOTHING. "the", "and" and "for" are whole words of
    /// nearly every text, so a recipe grounded "The Lost Treasure Map"
    /// (review 2026-10-28).
    func testAStopWordDoesNotGroundAName() {
        let recipe = "Banana bread\nMix the flour and the sugar for 10 minutes"
        XCTAssertNil(FileNamePrompt.clean("The Lost Treasure Map", sourceText: recipe))
        XCTAssertNil(FileNamePrompt.clean("And Then There Were None", sourceText: recipe))
        XCTAssertNil(FileNamePrompt.clean("Tax Return For Acme", sourceText: recipe))
        XCTAssertNil(FileNamePrompt.clean("Your New Thing", sourceText: "your new phone has shipped"),
                     "grounded only by stop words that the text does hold")
        XCTAssertEqual(FileNamePrompt.clean("Banana Bread Recipe", sourceText: recipe), "Banana Bread Recipe",
                       "control: a real word of the text still grounds a name")
        XCTAssertEqual(FileNamePrompt.clean("The Banana Bread", sourceText: recipe), "The Banana Bread",
                       "control: a stop word does not spoil a name another word grounds")
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
        // 6 or more digits in a row.
        XCTAssertNil(FileNamePrompt.clean("Northwind Card 4111111111111111", sourceText: source))
        XCTAssertNil(FileNamePrompt.clean("Northwind Account 123456", sourceText: source))
        XCTAssertNil(FileNamePrompt.clean("Northwind Card \u{FF14}\u{FF11}\u{FF11}\u{FF11}\u{FF11}\u{FF11}", sourceText: source),
                     "full-width digits are digits")
        // 6 or more joined by hyphens, dots or slashes (review 2026-10-28:
        // a dotted card number passed).
        XCTAssertNil(FileNamePrompt.clean("Northwind Account 123-456", sourceText: source))
        XCTAssertNil(FileNamePrompt.clean("Northwind Ref 12.34.56", sourceText: source))
        XCTAssertNil(FileNamePrompt.clean("Northwind Ref 12/34/56", sourceText: source))
        XCTAssertNil(FileNamePrompt.clean("Northwind Card 4111.1111.1111.1111", sourceText: source))
        XCTAssertNil(FileNamePrompt.clean("Northwind Invoice 2026-10-27", sourceText: source), "a date stamp")
        // 8 or more joined by any mix of spaces, hyphens, dots and slashes.
        XCTAssertNil(FileNamePrompt.clean("Northwind Card 4111 1111 1111 1111", sourceText: source))
        XCTAssertNil(FileNamePrompt.clean("Northwind Card 4111-1111-1111-1111", sourceText: source))
        XCTAssertNil(FileNamePrompt.clean("Northwind Account 1234 5678", sourceText: source))
        XCTAssertNil(FileNamePrompt.clean("Northwind Account 12 34-56.78", sourceText: source))
        // Commas, underscores and short runs such as " - " join a number too
        // (review 2026-10-28).
        XCTAssertNil(FileNamePrompt.clean("Northwind Card 4111, 1111, 1111, 1111", sourceText: source))
        XCTAssertNil(FileNamePrompt.clean("Northwind Card 4111,1111,1111,1111", sourceText: source))
        XCTAssertNil(FileNamePrompt.clean("Northwind Card 4111_1111_1111_1111", sourceText: source))
        XCTAssertNil(FileNamePrompt.clean("Card 4111 - 1111 - 1111 - 1111", sourceText: "Card statement"),
                     "groups split by \" - \"")
        XCTAssertNil(FileNamePrompt.clean("Visa Card 4111 - 1111 - 1111 - 1111", sourceText: "Visa Card statement"),
                     "cut to 8 words, it still holds 12 digits")
        XCTAssertNil(FileNamePrompt.clean("Northwind Account 123,456", sourceText: source), "six, joined by a comma")
        XCTAssertNil(FileNamePrompt.clean("Northwind Account 123_456", sourceText: source), "six, joined by an underscore")
        XCTAssertNil(FileNamePrompt.clean("Northwind Account 123 - 456", sourceText: source), "six, joined by \" - \"")
        // Allowed: fewer than 8 digits split only by spaces, so a day and a
        // year stay.
        XCTAssertEqual(FileNamePrompt.clean("Northwind Invoice Oct 14 2026", sourceText: source),
                       "Northwind Invoice Oct 14 2026", "a day and a year are a date, not a number to hide")
        XCTAssertNotNil(FileNamePrompt.clean("Northwind Account 12 34 56", sourceText: source),
                        "six digits split by spaces are under the spaced rule's eight")
        XCTAssertNotNil(FileNamePrompt.clean("Northwind Ref 123 4567", sourceText: source), "seven, split by a space")
        XCTAssertNotNil(FileNamePrompt.clean("Northwind Account 12345", sourceText: source), "five in a row")
        XCTAssertNotNil(FileNamePrompt.clean("Northwind Ref 12-345", sourceText: source), "five, split by a hyphen")
        XCTAssertNotNil(FileNamePrompt.clean("Northwind Invoice 2041 Oct", sourceText: source),
                        "control: four digits then a word is not a run")
        XCTAssertNotNil(FileNamePrompt.clean("Northwind Invoice 2041", sourceText: source), "control: a short number is fine")
        XCTAssertNil(FileNamePrompt.clean("Northwind [REDACTED:key] Invoice", sourceText: source))
    }

    /// THE LARGEST-TEXT LABEL NEVER GROUNDS A NAME. The reader puts
    /// "Largest text: " first on every image, so "largest" and "text" were
    /// words of every source (review 2026-10-28).
    func testTheLargestTextLabelIsNotPartOfTheSource() {
        let labelled = FileTextReader.largestTextLabel + "Northwind Studio | Invoice 2041\nNorthwind Studio\nInvoice 2041"
        XCTAssertNil(FileNamePrompt.clean("Largest Text Screenshot", sourceText: labelled),
                     "a name grounded only on the label's words was kept")
        XCTAssertNil(FileNamePrompt.clean("Group Text Conversation", sourceText: labelled))
        XCTAssertEqual(FileNamePrompt.clean("Northwind Studio Invoice", sourceText: labelled), "Northwind Studio Invoice",
                       "control: the body still grounds a name")
        XCTAssertNotNil(FileNamePrompt.clean("Group Text Conversation", sourceText: labelled + "\nText messages"),
                        "control: a word the body holds still counts")
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
