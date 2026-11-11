import XCTest
@testable import Grux

/// D166 item 12 (sense pass 20): a contact with no name showed its address
/// twice, as the title (the fallback) and again as the line under it. The
/// same held for a contact with only an organization. The line under a name
/// never repeats it.
final class ContactSubtitleTests: XCTestCase {

    private func contact(given: String = "", family: String = "", org: String = "",
                         emails: [String] = []) -> GruxContact {
        GruxContact(id: UUID().uuidString, givenName: given, familyName: family, organization: org, emails: emails)
    }

    func test_aNamedContactShowsItsOrganizationOrElseItsAddress() {
        XCTAssertEqual(contact(given: "Ada", org: "Acme", emails: ["ada@acme.test"]).listSubtitle, "Acme")
        XCTAssertEqual(contact(given: "Ada", emails: ["ada@acme.test"]).listSubtitle, "ada@acme.test")
        XCTAssertNil(contact(given: "Ada").listSubtitle)
        XCTAssertEqual(contact(given: "Ada", org: "Acme").headerSubtitle, "Acme")
        XCTAssertNil(contact(given: "Ada").headerSubtitle)
    }

    func test_anAddressOnlyContactShowsItOnce() {
        let c = contact(emails: ["sam@example.test"])
        XCTAssertEqual(c.fullName, "sam@example.test")
        XCTAssertNil(c.listSubtitle)
        XCTAssertNil(c.headerSubtitle)
    }

    func test_anOrganizationOnlyContactShowsItOnceAndItsAddressUnder() {
        let c = contact(org: "Warranty Center", emails: ["help@warranty.test"])
        XCTAssertEqual(c.fullName, "Warranty Center")
        XCTAssertEqual(c.listSubtitle, "help@warranty.test")
        XCTAssertNil(c.headerSubtitle)
        XCTAssertNil(contact(org: "Warranty Center").listSubtitle)
    }

    /// Blank and differently cased copies of the title are the same words.
    func test_aSubtitleThatOnlyDiffersInCaseOrSpacesIsARepeat() {
        XCTAssertNil(contact(given: "Acme", org: " acme ").listSubtitle)
        XCTAssertNil(contact(given: "Acme", org: " acme ").headerSubtitle)
        XCTAssertNil(contact(org: "   ", emails: []).listSubtitle)
    }
}
