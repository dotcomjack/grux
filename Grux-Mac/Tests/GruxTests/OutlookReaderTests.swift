import XCTest
@testable import Grux

// Tests for the OWA list-row subject parser used by the hardened live sweep.
// The aria-label shape is "[Unread] <sender> <subject> <h:mm AM/PM> <preview>";
// with the DOM sender name we strip the read-state + sender and cut at the time
// token to recover the subject. Pure + deterministic, so unit tested.
final class OutlookReaderTests: XCTestCase {

    func testSubjectFromAriaRealShape() {
        let aria = "Unread dana reyes Order shipping status 9:32 AM I can't find it. Can you check"
        let s = OutlookReader.subjectFromAria(aria, sender: "dana reyes", fallback: "(no subject)")
        XCTAssertEqual(s, "Order shipping status")
    }

    func testSubjectFromAriaWeekdayTime() {
        let aria = "Unread Tina at Simple Bundles Bundles that look good and ship right Mon 4:31 PM The smarte"
        let s = OutlookReader.subjectFromAria(aria, sender: "Tina at Simple Bundles", fallback: "(no subject)")
        XCTAssertEqual(s, "Bundles that look good and ship right")
    }

    func testSubjectFallsBackWhenNoTimeToken() {
        // No time token + nothing left after sender -> fallback is used.
        let aria = "Unread dana reyes"
        let s = OutlookReader.subjectFromAria(aria, sender: "dana reyes", fallback: "(no subject)")
        XCTAssertEqual(s, "(no subject)")
    }

    func testSubjectToleratesMissingReadState() {
        let aria = "Emily Steele Retail velocity, live: Join us June 22nd 8:43 AM A first look"
        let s = OutlookReader.subjectFromAria(aria, sender: "Emily Steele", fallback: "(no subject)")
        XCTAssertEqual(s, "Retail velocity, live: Join us June 22nd")
    }
}
