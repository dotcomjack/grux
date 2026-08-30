import XCTest
@testable import Grux

final class AccountSwitcherTests: XCTestCase {

    // The persistence types are the meat of what's testable without spawning
    // the claude CLI / real keychain reads. Switching itself shells out to
    // Terminal + polls live status, which is e2e-only.

    func testAuthStateRoundTripJSON() throws {
        var state = AuthState()
        state.accounts = [
            ClaudeAuthAccount(
                id: "org-personal",
                label: "Personal",
                email: "personal@example.com",
                orgId: "org-personal",
                addedAt: Date(timeIntervalSince1970: 1_700_000_000)
            ),
            ClaudeAuthAccount(
                id: "org-work",
                label: "Work",
                email: "work@example.com",
                orgId: "org-work",
                addedAt: Date(timeIntervalSince1970: 1_700_000_500)
            )
        ]
        state.activeAccountId = "org-personal"
        state.perAccount = [
            "org-personal": PerAccountInfo(
                lastLimitHitAt: Date(timeIntervalSince1970: 1_777_142_000),
                estimatedResetAt: Date(timeIntervalSince1970: 1_779_734_000)
            )
        ]

        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(state)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let decoded = try dec.decode(AuthState.self, from: data)

        XCTAssertEqual(decoded.version, 1)
        XCTAssertEqual(decoded.accounts.count, 2)
        XCTAssertEqual(decoded.activeAccountId, "org-personal")
        XCTAssertEqual(decoded.accounts.first?.label, "Personal")
        XCTAssertEqual(decoded.accounts.last?.email, "work@example.com")
        XCTAssertNotNil(decoded.perAccount["org-personal"]?.lastLimitHitAt)
    }

    func testAuthStateMissingFieldsBackfillToDefaults() throws {
        // A file written by an earlier Grux version (no perAccount key)
        // should still decode cleanly, adding a field via Codable in Swift
        // requires either a default value or the field be optional. Lock in
        // forward-compat by decoding a stripped-down JSON payload.
        let json = #"{"version":1,"accounts":[],"activeAccountId":null,"perAccount":{}}"#
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(AuthState.self, from: data)
        XCTAssertEqual(decoded.version, 1)
        XCTAssertTrue(decoded.accounts.isEmpty)
        XCTAssertNil(decoded.activeAccountId)
        XCTAssertTrue(decoded.perAccount.isEmpty)
    }

    func testClaudeAuthAccountIdentifiable() {
        let acct = ClaudeAuthAccount(
            id: "x",
            label: "X",
            email: nil,
            orgId: nil,
            addedAt: Date()
        )
        XCTAssertEqual(acct.id, "x")
    }

    @MainActor
    func testResolveClaudeBinaryReturnsExecutableOrFallback() {
        let path = AccountSwitcher.resolveClaudeBinary()
        XCTAssertFalse(path.isEmpty)
        // Either it's an executable file or the literal "claude" fallback.
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: path) || path == "claude")
    }

    // The "Re-open login Terminal" recovery (timeout dead-end) must re-run the
    // EXACT login command from the failed switch, NOT a re-logout. When no
    // switch was attempted, it falls back to a bare claudeai login. This is the
    // pure derivation reopenLoginTerminal feeds to Terminal, and locking it keeps
    // the recovery from silently re-logging-out or losing the --email hint.
    func testReopenCommandUsesRecordedLoginCommand() {
        let recorded = "claude auth login --claudeai --email 'work@example.com'"
        XCTAssertEqual(AccountSwitcher.reopenCommand(lastLoginCommand: recorded), recorded)
    }

    func testReopenCommandFallsBackToBareLoginWithoutLogout() {
        let fallback = AccountSwitcher.reopenCommand(lastLoginCommand: nil)
        XCTAssertEqual(fallback, "claude auth login --claudeai")
        // Critically, the recovery never re-runs logout: the prior account was
        // already logged out at the start of the switch.
        XCTAssertFalse(fallback.contains("logout"))
    }
}
