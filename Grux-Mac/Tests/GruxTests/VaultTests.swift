import XCTest
@testable import Grux

final class VaultTests: XCTestCase {
    func test_setGetDelete_roundTrip() {
        let path = "social/test-brand/threads/password"
        Vault.delete(path)
        XCTAssertEqual(Vault.get(path), "")
        XCTAssertTrue(Vault.set(path, "s3cret"))
        XCTAssertEqual(Vault.get(path), "s3cret")
        XCTAssertTrue(Vault.list(prefix: "social/test-brand/").contains(path))
        XCTAssertTrue(Vault.delete(path))
        XCTAssertEqual(Vault.get(path), "")
    }
}
