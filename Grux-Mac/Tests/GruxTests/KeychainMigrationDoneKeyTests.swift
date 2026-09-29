import XCTest
@testable import Grux

/// The keychain migration is meant to run once. Its done flag was keyed on
/// `String.hashValue`, which Swift seeds PER PROCESS, so every launch computed a new key,
/// never found the flag the last launch wrote, re-queried the keychain, and wrote one more
/// flag. One operator's defaults held 154 of them.
///
/// None of these tests touches the keychain.
final class KeychainMigrationDoneKeyTests: XCTestCase {

    /// THE CROSS-PROCESS PROOF. The key is pinned to a literal, which only a stable digest
    /// can match: any per-process hash produces a different string on every run. The value
    /// is the first 8 bytes of SHA-256 of the rename table as the migrator joins it,
    /// computed outside Swift with `shasum -a 256`.
    func testTheDoneKeyIsTheSameInEveryProcess() {
        XCTAssertEqual(KeychainServiceMigrator.doneKey,
                       "grux.keychain.serviceMigration.done.31543166fa0ec570",
                       "the done key is not a stable digest of the rename table, so the next "
                       + "launch will not find the flag this one writes")
    }

    func testTheKeyIsIdenticalAcrossTwoComputations() {
        XCTAssertEqual(KeychainServiceMigrator.doneKey, KeychainServiceMigrator.doneKey)
        XCTAssertEqual(KeychainServiceMigrator.doneKey(for: KeychainServiceMigrator.renames),
                       KeychainServiceMigrator.doneKey)
    }

    /// Still keyed on the table: a future rename asks the question again.
    func testAnotherRenameTableGetsAnotherKey() {
        let extended = KeychainServiceMigrator.renames + [(old: "a.b", new: "c.d")]
        XCTAssertNotEqual(KeychainServiceMigrator.doneKey(for: extended), KeychainServiceMigrator.doneKey)
        XCTAssertTrue(KeychainServiceMigrator.doneKey.hasPrefix(KeychainServiceMigrator.doneKeyPrefix))
    }

    /// The second run finds the flag the first one wrote and does not go near the keychain.
    func testASecondRunFindsTheDoneFlag() {
        let key = KeychainServiceMigrator.doneKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.set(true, forKey: key)
        XCTAssertEqual(KeychainServiceMigrator.runOnce(), 0,
                       "a run after the flag was written did not stop at the flag")
    }
}
