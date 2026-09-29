import XCTest
@testable import Grux

/// What a first launch is allowed to do to somebody who has never seen Grux.
///
/// Reported from a fresh install on a Mac that had never run it: the app did something
/// at boot that the person had not been told about and could not answer.
@MainActor
final class FirstRunSilenceTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(path)
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - No launch-time Keychain modal

    /// A launch-time migration may not put a password prompt on somebody's screen.
    ///
    /// `SecItemCopyMatching` asks macOS to unlock the login keychain, and macOS answers with
    /// a modal. Measured on a fresh install: it named `grux-vault`, one of this migrator's
    /// own rename targets, it blocked the launch, and it returned on every boot. On a Mac
    /// whose account password was ever reset through an Apple ID the login keychain keeps
    /// the OLD password, so the dialog cannot be answered by the person looking at it.
    func testTheKeychainMigrationNeverRaisesUI() throws {
        let migrator = try source("Sources/Grux/KeychainServiceMigrator.swift")

        let queries = migrator.components(separatedBy: "kSecClass as String: kSecClassGenericPassword")
            .count - 1
        XCTAssertGreaterThanOrEqual(queries, 2,
            "found \(queries) keychain queries in the migrator, so this scan is not seeing them")

        let skips = migrator.components(
            separatedBy: "kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip").count - 1
        XCTAssertGreaterThanOrEqual(skips, 2,
            "\(queries) keychain queries and only \(skips) of them decline to raise UI. A "
            + "launch time migration that prompts is a launch the owner cannot get past.")
    }

    /// And it actually runs once, which is what the name always claimed.
    ///
    /// Nothing recorded that the migration had finished, so every boot re-queried every
    /// rename. Invisible while the keychain is unlocked; the whole defect while it is not.
    func testTheMigrationRecordsThatItFinished() throws {
        let migrator = try source("Sources/Grux/KeychainServiceMigrator.swift")
        XCTAssertTrue(migrator.contains("UserDefaults.standard.bool(forKey: doneKey)"),
            "runOnce does not check whether it has already finished, so it runs on every "
            + "launch forever and the name is a lie")
        XCTAssertTrue(migrator.contains("UserDefaults.standard.set(true, forKey: doneKey)"),
            "nothing ever records that the migration finished")

        // AND ONLY WHEN THE KEYCHAIN WAS READABLE. Marking it done after a locked-keychain
        // pass would skip the migration forever on the one machine that still needs it.
        XCTAssertTrue(migrator.contains("if everyPassComplete {"),
            "the done flag is not conditional on the keychain having been readable")
        XCTAssertTrue(migrator.contains("if status == errSecItemNotFound {"),
            "nothing separates an empty keychain from an unreadable one, so the two are "
            + "recorded as the same answer")
    }

    /// The rename table is what the flag is keyed on, so a future rename asks again.
    func testTheDoneFlagIsKeyedOnTheRenameTable() {
        let key = KeychainServiceMigrator.doneKey
        XCTAssertTrue(key.hasPrefix("grux.keychain.serviceMigration.done."),
            "the done key changed shape: \(key)")
        XCTAssertGreaterThan(key.count, "grux.keychain.serviceMigration.done.".count,
            "the key carries no digest of the rename table, so adding a rename would "
            + "inherit the old answer and never run")
    }
}
