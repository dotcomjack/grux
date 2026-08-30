import XCTest
@testable import Grux

// CreativeEngine.decodeCopy is where model JSON becomes the ad copy that gets
// persisted to ~/.grux/creative/<brand>/<timestamp>.json. The brief tells the
// model "No em or en dashes", and instruction-only enforcement is precisely what
// DashSanitizer exists because of.
//
// This one is not a display concern. A headline or CTA written to that file is
// ad copy that can end up in front of customers, so a dash reaching disk is
// already past us.
final class CreativeCopyScrubTests: XCTestCase {

    private func decode(_ headline: String, _ body: String, _ cta: String) -> CreativeCopy? {
        CreativeEngine.decodeCopy(["headline": headline, "body": body, "cta": cta])
    }

    func testStripsBannedDashesFromEveryField() {
        guard let c = decode("Shine on \u{2014} all day",
                             "Built for it \u{2013} not around it",
                             "Shop now \u{2014} today") else {
            return XCTFail("decode returned nil")
        }
        for field in [c.headline, c.body, c.cta] {
            XCTAssertFalse(field.unicodeScalars.contains("\u{2014}"), "em dash would be saved as ad copy: \(field)")
            XCTAssertFalse(field.unicodeScalars.contains("\u{2013}"), "en dash would be saved as ad copy: \(field)")
        }
    }

    func testPreservesAsciiHyphensInProductCopy() {
        guard let c = decode("Cruelty-free", "A 2-pack of small-batch soap", "Buy the 3-pack") else {
            return XCTFail("decode returned nil")
        }
        XCTAssertTrue(c.headline.contains("Cruelty-free"), "got \(c.headline)")
        XCTAssertTrue(c.body.contains("2-pack"), "got \(c.body)")
        XCTAssertTrue(c.body.contains("small-batch"), "got \(c.body)")
        XCTAssertTrue(c.cta.contains("3-pack"), "got \(c.cta)")
    }

    // Missing keys and a non-dictionary payload keep their existing behaviour.
    func testMissingFieldsAndNonDictionaryAreUnchanged() {
        let partial = CreativeEngine.decodeCopy(["headline": "Only this"])
        XCTAssertEqual(partial?.headline, "Only this")
        XCTAssertEqual(partial?.body, "")
        XCTAssertEqual(partial?.cta, "")
        XCTAssertNil(CreativeEngine.decodeCopy("not a dictionary"))
        XCTAssertNil(CreativeEngine.decodeCopy(nil))
    }
}
