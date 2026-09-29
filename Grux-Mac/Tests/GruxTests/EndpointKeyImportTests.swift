import XCTest
@testable import Grux

final class EndpointKeyImportTests: XCTestCase {
    func test_parse_readsIdAndKey_andIgnoresWhitespace() {
        let text = "  7A1F0E5C-3B2D-4C8E-9A61-5D2F8E4B0C11 \n  sk-test-value  \n"
        let parsed = EndpointKeyImport.parse(text)
        XCTAssertEqual(parsed?.target, .endpoint(UUID(uuidString: "7A1F0E5C-3B2D-4C8E-9A61-5D2F8E4B0C11")!))
        XCTAssertEqual(parsed?.key, "sk-test-value")
    }

    func test_parse_typesafeLine_targetsTheDecisionProviderKey() {
        let parsed = EndpointKeyImport.parse("typesafe\nts-test-value\n")
        XCTAssertEqual(parsed?.target, .typesafe)
        XCTAssertEqual(parsed?.key, "ts-test-value")
    }

    func test_parse_rejectsMissingKeyOrBadId() {
        XCTAssertNil(EndpointKeyImport.parse("not-a-uuid\nsk-x"))
        XCTAssertNil(EndpointKeyImport.parse("7A1F0E5C-3B2D-4C8E-9A61-5D2F8E4B0C11\n"))
        XCTAssertNil(EndpointKeyImport.parse(""))
    }
}
