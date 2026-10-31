import XCTest
@testable import Grux

/// D56: on a headless Mac a Keychain read put a SecurityAgent dialog on the
/// screen (2026-10-28 12:04 AM, one second after Grux launched) and it sat
/// there for two days, while every launch logged "read still out".
/// `kSecUseAuthenticationUISkip` governs access-controlled items only; a file
/// keychain's unlock and access-list dialogs answer to the process-wide
/// interaction switch. Headless, that switch is off before any read.
final class KeychainHeadlessTests: XCTestCase {

    // Any earlier test's Keychain read runs the gate in this process (a test run is
    // headless), so each test starts from macOS's default.
    override func setUp() {
        super.setUp()
        KeychainStore.resetInteractionGateForTests()
    }

    override func tearDown() {
        KeychainStore.resetInteractionGateForTests()
        super.tearDown()
    }

    func test_headlessTurnsKeychainDialogsOffAndBackOn() {
        var calls: [Bool] = []
        KeychainStore.interactionSetter = { calls.append($0) }
        KeychainStore.gateInteraction(headless: true)
        KeychainStore.gateInteraction(headless: true)
        XCTAssertEqual(calls, [false], "headless must switch Keychain dialogs off, once")
        KeychainStore.gateInteraction(headless: false)
        XCTAssertEqual(calls, [false, true], "leaving headless puts dialogs back")
    }

    // A Mac that never went headless keeps macOS's default and is never touched.
    func test_aMacThatIsNotHeadlessIsLeftAlone() {
        var calls: [Bool] = []
        KeychainStore.interactionSetter = { calls.append($0) }
        KeychainStore.gateInteraction(headless: false)
        XCTAssertEqual(calls, [])
    }

    // Headless, a read macOS would have asked about is a key nobody can reach this
    // run: it reads as not set, once, instead of "still out" on every ask.
    func test_aReadThatNeedsADialogWhileHeadlessReadsAsNotSet() {
        XCTAssertEqual(KeychainStore.readOutcome(status: errSecInteractionNotAllowed, headless: true), .notSet)
        XCTAssertEqual(KeychainStore.readOutcome(status: errSecInteractionNotAllowed, headless: false), .transient)
        XCTAssertEqual(KeychainStore.readOutcome(status: errSecItemNotFound, headless: false), .notSet)
        XCTAssertEqual(KeychainStore.readOutcome(status: errSecItemNotFound, headless: true), .notSet)
        XCTAssertEqual(KeychainStore.readOutcome(status: errSecAuthFailed, headless: true), .transient)
    }

    // The gate sits in the one read door, before the raw call, so no read can
    // reach macOS ahead of it.
    func test_theOneReadDoorGatesBeforeItReads() throws {
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let file = try String(contentsOf: src.appendingPathComponent("Sources/Grux/KeychainStore.swift"), encoding: .utf8)
        let door = try XCTUnwrap(file.range(of: "nonisolated static func copyMatching("))
        let body = String(file[door.upperBound...].prefix(500))
        let gate = try XCTUnwrap(body.range(of: "gateInteraction(headless: WindowFacade.isHeadless)"))
        let raw = try XCTUnwrap(body.range(of: "SecItemCopyMatching("))
        XCTAssertLessThan(gate.lowerBound, raw.lowerBound)
    }
}
