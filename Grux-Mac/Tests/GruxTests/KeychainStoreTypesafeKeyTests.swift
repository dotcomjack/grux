import XCTest
@testable import Grux

final class KeychainStoreTypesafeKeyTests: XCTestCase {
    func test_typesafeKeyCaseExists_andIsStableString() {
        // The raw value is the Keychain account name, so it must never change
        // once shipped: a rename would orphan every user's stored key.
        XCTAssertEqual(KeychainStore.Key.typesafeApiKey.rawValue, "typesafeApiKey")
    }
}
