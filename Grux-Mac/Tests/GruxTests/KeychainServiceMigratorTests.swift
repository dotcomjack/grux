import XCTest
import Security
@testable import Grux

/// The bundle id and every Keychain service string were renamed from
/// `com.dcj.*` to `com.gruxai.*` for the open source release. A service string
/// is part of a Keychain item's primary key, so without this migration every
/// stored credential would still be on the machine and unreachable by the app.
///
/// These tests use their own throwaway service names, never the real ones, so a
/// run can never touch a developer's actual stored keys.
final class KeychainServiceMigratorTests: XCTestCase {

    private var oldService = ""
    private var newService = ""

    override func setUpWithError() throws {
        let id = UUID().uuidString
        oldService = "test.grux.migrator.old.\(id)"
        newService = "test.grux.migrator.new.\(id)"
    }

    override func tearDownWithError() throws {
        for svc in [oldService, newService] {
            SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: svc,
            ] as CFDictionary)
        }
    }

    // MARK: - helpers

    @discardableResult
    private func put(_ service: String, _ account: String, _ value: String) -> Bool {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
        return SecItemAdd([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ] as CFDictionary, nil) == errSecSuccess
    }

    private func read(_ service: String, _ account: String) -> String? {
        var out: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ] as CFDictionary, &out)
        guard status == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    // MARK: - tests

    /// The whole point: a credential filed under the old service is readable
    /// under the new one afterwards, with its VALUE intact. Asserting only that
    /// an item exists would pass for an empty item.
    func testItemMovesWithItsValueIntact() throws {
        try XCTSkipUnless(put(oldService, "anthropicApiKey", "sk-test-value-123"),
                          "could not write to the test keychain in this environment")

        let moved = KeychainServiceMigrator.migrate(from: oldService, to: newService)

        XCTAssertEqual(moved, 1)
        XCTAssertEqual(read(newService, "anthropicApiKey"), "sk-test-value-123")
        XCTAssertNil(read(oldService, "anthropicApiKey"),
                     "the original must be removed once the copy is verified")
    }

    /// Multiple accounts under one service all move. The real `com.dcj.grux`
    /// service holds every API key as a separate account, so a migrator that
    /// moved only the first would look like it worked and lose the rest.
    func testEveryAccountUnderTheServiceMoves() throws {
        let wanted = ["anthropicApiKey": "a1", "braveApiKey": "b2", "falApiKey": "c3"]
        for (k, v) in wanted {
            try XCTSkipUnless(put(oldService, k, v), "test keychain unavailable")
        }

        let moved = KeychainServiceMigrator.migrate(from: oldService, to: newService)

        XCTAssertEqual(moved, wanted.count)
        for (k, v) in wanted {
            XCTAssertEqual(read(newService, k), v, "account \(k) did not survive the move")
        }
    }

    /// A value already present under the NEW service is authoritative and must
    /// not be clobbered by a stale copy under the old one. The new service is
    /// what the running app has been reading and writing.
    func testExistingNewValueIsNotOverwritten() throws {
        try XCTSkipUnless(put(oldService, "anthropicApiKey", "STALE"), "test keychain unavailable")
        try XCTSkipUnless(put(newService, "anthropicApiKey", "CURRENT"), "test keychain unavailable")

        KeychainServiceMigrator.migrate(from: oldService, to: newService)

        XCTAssertEqual(read(newService, "anthropicApiKey"), "CURRENT")
    }

    /// Running twice must not fail or resurrect anything. This runs on every
    /// launch, so it is called far more often than it does work.
    func testIsIdempotent() throws {
        try XCTSkipUnless(put(oldService, "braveApiKey", "value"), "test keychain unavailable")

        XCTAssertEqual(KeychainServiceMigrator.migrate(from: oldService, to: newService), 1)
        XCTAssertEqual(KeychainServiceMigrator.migrate(from: oldService, to: newService), 0)
        XCTAssertEqual(read(newService, "braveApiKey"), "value")
    }

    /// Nothing to migrate is the normal case on a fresh install and on every
    /// launch after the first. It must be a silent no-op, not an error.
    func testEmptySourceIsANoOp() {
        XCTAssertEqual(KeychainServiceMigrator.migrate(from: oldService, to: newService), 0)
    }

    /// A rename row whose old and new names are equal must do nothing at all.
    /// Without the guard, the migrator would copy every item onto itself and
    /// then delete the original it had just verified, which is exactly the
    /// data-loss shape the copy-verify-delete order exists to prevent.
    func testSameServiceIsRefused() throws {
        try XCTSkipUnless(put(oldService, "anthropicApiKey", "keepme"), "test keychain unavailable")

        XCTAssertEqual(KeychainServiceMigrator.migrate(from: oldService, to: oldService), 0)
        XCTAssertEqual(read(oldService, "anthropicApiKey"), "keepme")
    }

    /// The shipped rename table must cover every service the app actually uses,
    /// and must point at the current names. A service renamed in code but not
    /// listed here strands that store's credentials silently.
    func testRenameTableCoversEveryShippedService() {
        let targets = Set(KeychainServiceMigrator.renames.map(\.new))
        for shipped in [KeychainStore.service, WebhookSecretStore.service, Vault.service] {
            XCTAssertTrue(targets.contains(shipped),
                          "\(shipped) is a live Keychain service with no migration row")
        }
        for row in KeychainServiceMigrator.renames {
            XCTAssertNotEqual(row.old, row.new, "a no-op rename row is a mistake, not a guard")
            XCTAssertTrue(row.new.hasPrefix("com.gruxai."), "\(row.new) is not a current name")
        }
    }
}
