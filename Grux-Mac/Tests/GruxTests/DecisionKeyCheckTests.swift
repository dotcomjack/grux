import XCTest
@testable import Grux

/// W33-P3 item 1: a TypeSafe key that failed Save & Test stayed in the
/// Keychain, so reopening Integrations read "Connected" over a key TypeSafe
/// had refused, and hid the link to get a working one. "Connected" now means
/// the last check of THIS key worked; a refused key is not kept.
final class DecisionKeyCheckTests: XCTestCase {

    private let key = "apikey_0123456789abcd"
    private let at = Date(timeIntervalSince1970: 1_800_000_000)

    private func record(_ r: DecisionsSection.KeyCheck, for k: String? = nil) -> DecisionsSection.KeyCheckRecord {
        DecisionsSection.KeyCheckRecord(result: r, at: at, keyTail: DecisionsSection.tail(k ?? key))
    }

    func test_noKeyReadsNotConnected() {
        XCTAssertEqual(DecisionsSection.headline(key: "", record: nil), "Not connected")
        XCTAssertEqual(DecisionsSection.headline(key: "  \n", record: record(.worked)), "Not connected")
    }

    /// A key that arrived without a check (first run, the import, a check
    /// that never ran) is saved, not Connected.
    func test_aKeyNeverCheckedIsSavedNotConnected() {
        XCTAssertEqual(DecisionsSection.headline(key: key, record: nil), "Key saved, not checked yet")
        XCTAssertFalse(DecisionsSection.isConnected(key: key, record: nil))
    }

    func test_onlyAWorkingCheckOfThisKeyReadsConnected() {
        XCTAssertEqual(DecisionsSection.headline(key: key, record: record(.worked)), "Connected")
        XCTAssertTrue(DecisionsSection.isConnected(key: key, record: record(.worked)))
        XCTAssertEqual(DecisionsSection.headline(key: key, record: record(.refused)), "Key saved, TypeSafe refused it")
        XCTAssertEqual(DecisionsSection.headline(key: key, record: record(.unanswered)),
                       "Key saved, not checked yet: TypeSafe did not answer")
        XCTAssertFalse(DecisionsSection.isConnected(key: key, record: record(.refused)))
        XCTAssertFalse(DecisionsSection.isConnected(key: key, record: record(.unanswered)))
    }

    /// A check of an earlier key says nothing about this one.
    func test_aCheckOfAnotherKeyDoesNotCount() {
        let other = record(.worked, for: "apikey_0123456789wxyz")
        XCTAssertEqual(DecisionsSection.headline(key: key, record: other), "Key saved, not checked yet")
        XCTAssertFalse(DecisionsSection.isConnected(key: key, record: other))
    }

    /// The tail is a fingerprint a person can read, never the key: at most
    /// four characters, and the whole key is never stored.
    func test_theTailIsFourCharactersAtMost() {
        XCTAssertEqual(DecisionsSection.tail(key), "abcd")
        XCTAssertEqual(DecisionsSection.tail("  \(key)\n"), "abcd")
        XCTAssertEqual(DecisionsSection.tail("abc"), "abc")
        XCTAssertEqual(DecisionsSection.tail("abcd"), "abcd")
        XCTAssertEqual(DecisionsSection.tail("abcde"), "bcde")
        XCTAssertEqual(DecisionsSection.tail(""), "")
    }

    func test_theRecordRoundTripsThroughItsOwnDefaults() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "DecisionKeyCheckTests"))
        defaults.removePersistentDomain(forName: "DecisionKeyCheckTests")
        XCTAssertNil(DecisionsSection.loadCheck(defaults))
        DecisionsSection.saveCheck(record(.worked), defaults)
        XCTAssertEqual(DecisionsSection.loadCheck(defaults), record(.worked))
        let stored = try XCTUnwrap(defaults.data(forKey: DecisionsSection.checkDefaultsKey))
        XCTAssertFalse(String(decoding: stored, as: UTF8.self).contains(key), "the key itself is never stored")
        defaults.removePersistentDomain(forName: "DecisionKeyCheckTests")
    }

    /// What Save & Test does with each answer. A refused key is not kept:
    /// the earlier key, if there was one, stays.
    func test_saveAndTestKeepsOnlyAKeyTypeSafeDidNotRefuse() {
        XCTAssertEqual(DecisionsSection.keyToKeep(tried: key, previous: "", result: .worked), key)
        XCTAssertEqual(DecisionsSection.keyToKeep(tried: key, previous: "", result: .unanswered), key)
        XCTAssertEqual(DecisionsSection.keyToKeep(tried: key, previous: "", result: .refused), "")
        XCTAssertEqual(DecisionsSection.keyToKeep(tried: key, previous: "apikey_old", result: .refused), "apikey_old")
        XCTAssertEqual(DecisionsSection.keyToKeep(tried: key, previous: "apikey_old", result: .worked), key)
    }

    /// W34-P3 item 1: re-testing the saved key itself after TypeSafe revoked it
    /// kept it and said "Grux kept your earlier key", which was the refused key.
    func test_reTestingASavedKeyTypeSafeNowRefusesRemovesIt() {
        XCTAssertEqual(DecisionsSection.keyToKeep(tried: key, previous: key, result: .refused), "")
        XCTAssertEqual(DecisionsSection.keyToKeep(tried: key, previous: key, result: .unanswered), key)
        XCTAssertEqual(DecisionsSection.keyToKeep(tried: key, previous: key, result: .worked), key)
        XCTAssertEqual(DecisionsSection.refusedLine(tried: key, previous: key),
                       "TypeSafe no longer accepts this key, so Grux removed it")
        XCTAssertEqual(DecisionsSection.refusedLine(tried: key, previous: ""),
                       "That key was not accepted, so Grux did not keep it")
        XCTAssertEqual(DecisionsSection.refusedLine(tried: key, previous: "apikey_old"),
                       "That key was not accepted, so Grux kept your earlier key")
    }

    /// W34-P3 item 2: a Disconnect pressed while Save & Test waits was undone
    /// when the check came back. Disconnect waits for the check.
    func test_disconnectWaitsForAnInFlightCheck() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf: root.appendingPathComponent("Sources/Grux/Integrations/DecisionsSection.swift"),
                             encoding: .utf8)
        let button = try XCTUnwrap(src.range(of: "\"Disconnect\","))
        let after = src[button.upperBound...]
        let close = try XCTUnwrap(after.range(of: "{ disconnect() }"))
        let tail = after[close.upperBound...].prefix(160)
        XCTAssertTrue(tail.contains(".disabled(testing)"), String(tail))
    }

    /// Only 401 and 403 mean the key itself was refused; every other failure
    /// says nothing about the key.
    func test_onlyAnAuthRefusalCountsAsRefused() {
        XCTAssertEqual(DecisionsSection.checkResult(of: JevDecisionProvider.Failure.http(401)), .refused)
        XCTAssertEqual(DecisionsSection.checkResult(of: JevDecisionProvider.Failure.http(403)), .refused)
        for code in [400, 402, 404, 429, 500, 503] {
            XCTAssertEqual(DecisionsSection.checkResult(of: JevDecisionProvider.Failure.http(code)), .unanswered, "\(code)")
        }
        XCTAssertEqual(DecisionsSection.checkResult(of: JevDecisionProvider.Failure.malformed), .unanswered)
        XCTAssertEqual(DecisionsSection.checkResult(of: URLError(.notConnectedToInternet)), .unanswered)
    }

    /// The view draws the tested headline and reads its state from the record.
    func test_theSectionDrawsTheTestedHeadline() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf: root.appendingPathComponent("Sources/Grux/Integrations/DecisionsSection.swift"),
                             encoding: .utf8)
        XCTAssertTrue(src.contains("Text(Self.headline(key: savedKey, record: check))"))
        XCTAssertFalse(src.contains("connected ? \"Connected\" : \"Not connected\""))
    }

    /// A saved key that is not Connected (never checked, or TypeSafe did not
    /// answer) can still be removed: Disconnect follows the saved key, not
    /// the check (seen live, `w33p3i1-live`: no Disconnect beside "Key saved,
    /// not checked yet").
    func test_disconnectFollowsTheSavedKeyNotTheCheck() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf: root.appendingPathComponent("Sources/Grux/Integrations/DecisionsSection.swift"),
                             encoding: .utf8)
        let gate = try XCTUnwrap(src.range(of: "if Self.offersDisconnect(savedKey: savedKey)"))
        let button = try XCTUnwrap(src.range(of: "\"Disconnect\","))
        XCTAssertLessThan(gate.lowerBound, button.lowerBound)
        XCTAssertTrue(DecisionsSection.offersDisconnect(savedKey: key))
        XCTAssertTrue(DecisionsSection.offersDisconnect(savedKey: " x "))
        XCTAssertFalse(DecisionsSection.offersDisconnect(savedKey: ""))
        XCTAssertFalse(DecisionsSection.offersDisconnect(savedKey: " \n"))
    }
}
