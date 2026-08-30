import XCTest
@testable import Grux

/// The bridge between the contract's key names and the properties that implement them.
///
/// The bug this closes is a naming mismatch, not a missing feature, so the test that matters
/// is the ROUND TRIP: writing through the contract key has to change the property the app
/// reads, and reading it back has to return what was written. A bridge that stored values in
/// its own corner would pass a shallower test and change nothing.
@MainActor
final class ConfigBridgeTests: XCTestCase {

    private var saved: GruxConfig!

    override func setUp() async throws {
        try await super.setUp()
        saved = AppState.shared.config
    }

    override func tearDown() async throws {
        AppState.shared.config = saved
        AppState.shared.saveConfig()
        try await super.tearDown()
    }

    // MARK: - The round trip

    /// Writing through the contract key lands on the property the rest of the app reads.
    /// This one specifically, because it is the case that proved the "implemented nowhere"
    /// claim wrong: the window-title privacy gate reads it on every capture.
    func testWritingTheContractKeyChangesThePropertyTheAppReads() throws {
        let entry = try XCTUnwrap(ConfigBridge.entry(for: "grux.capture.excluded_bundle_ids"))
        XCTAssertNotNil(entry.write("com.example.one, com.example.two"))
        XCTAssertEqual(AppState.shared.config.captureExcludedBundleIds,
                       ["com.example.one", "com.example.two"],
                       "the bridge wrote somewhere other than the property the capture gate reads")
        XCTAssertEqual(entry.read(), "com.example.one, com.example.two")
    }

    /// And clearing it clears the property rather than storing an empty string in it.
    func testAnEmptyListClearsRatherThanStoringNothing() throws {
        let entry = try XCTUnwrap(ConfigBridge.entry(for: "grux.capture.excluded_window_titles"))
        _ = entry.write("secret, private")
        XCTAssertEqual(AppState.shared.config.captureExcludedTitlePatterns.count, 2)
        _ = entry.write("")
        XCTAssertTrue(AppState.shared.config.captureExcludedTitlePatterns.isEmpty)
    }

    func testBooleanKeysRoundTripThroughEveryAcceptedSpelling() throws {
        let entry = try XCTUnwrap(ConfigBridge.entry(for: "grux.focus.enabled"))
        for on in ["true", "yes", "on", "1", "TRUE"] {
            _ = entry.write("false")
            XCTAssertNotNil(entry.write(on), "\(on) was rejected")
            XCTAssertTrue(AppState.shared.config.screenAnalysisEnabled, "\(on) did not read as true")
        }
        for off in ["false", "no", "off", "0"] {
            _ = entry.write("true")
            XCTAssertNotNil(entry.write(off), "\(off) was rejected")
            XCTAssertFalse(AppState.shared.config.screenAnalysisEnabled, "\(off) did not read as false")
        }
    }

    func testTheVoiceProviderMapsBothWaysOntoTheBoolThatImplementsIt() throws {
        let entry = try XCTUnwrap(ConfigBridge.entry(for: "grux.voice.tts_provider"))
        XCTAssertNotNil(entry.write("elevenlabs"))
        XCTAssertTrue(AppState.shared.config.useElevenLabs)
        XCTAssertEqual(entry.read(), "elevenlabs")
        XCTAssertNotNil(entry.write("system"))
        XCTAssertFalse(AppState.shared.config.useElevenLabs)
        XCTAssertEqual(entry.read(), "system")
    }

    // MARK: - Refusals

    /// RANGE CHECKED, NOT CLAMPED, and this is the assertion that says so. Clamping 25 to 23
    /// would report success for a value the person did not ask for, and they would find out
    /// from the behaviour rather than from the answer.
    func testAnHourOutsideTheDayIsRefusedRatherThanClamped() throws {
        let entry = try XCTUnwrap(ConfigBridge.entry(for: "grux.focus.active_hours_start"))
        _ = entry.write("7")
        XCTAssertEqual(AppState.shared.config.activeHoursStart, 7)
        for bad in ["25", "-1", "half past", "", "7.5"] {
            XCTAssertNil(entry.write(bad), "\(bad) was accepted")
            XCTAssertEqual(AppState.shared.config.activeHoursStart, 7,
                           "\(bad) changed the value on its way to being refused")
        }
    }

    func testAnUnknownVoiceProviderIsRefusedAndChangesNothing() throws {
        let entry = try XCTUnwrap(ConfigBridge.entry(for: "grux.voice.tts_provider"))
        _ = entry.write("system")
        XCTAssertNil(entry.write("azure"))
        XCTAssertFalse(AppState.shared.config.useElevenLabs, "a refused write still changed the value")
    }

    func testAnUnknownBooleanIsRefused() throws {
        let entry = try XCTUnwrap(ConfigBridge.entry(for: "grux.focus.enabled"))
        _ = entry.write("true")
        XCTAssertNil(entry.write("maybe"))
        XCTAssertTrue(AppState.shared.config.screenAnalysisEnabled)
    }

    // MARK: - The table itself

    /// NO CREDENTIAL MAY EVER APPEAR HERE. `grux config` takes its value as a command
    /// argument, which puts it in the shell history and in the process table for any local
    /// `ps`. The contract marks eleven keys secret; this asserts the bridge carries none of
    /// them, read from the contract rather than from a list copied into this test, so a new
    /// secret key is covered the day it is declared.
    func testNoSecretFromTheContractIsReachableThroughThisBridge() throws {
        let contract = try String(
            contentsOf: LaunchConsentGateTests.repoRoot().appendingPathComponent("docs/contract.md"),
            encoding: .utf8)
        var secrets: Set<String> = []
        for line in contract.components(separatedBy: "\n") {
            guard line.hasPrefix("| `grux."), line.contains("**yes**") else { continue }
            guard let open = line.firstIndex(of: "`") else { continue }
            let rest = line[line.index(after: open)...]
            guard let close = rest.firstIndex(of: "`") else { continue }
            secrets.insert(String(rest[rest.startIndex..<close]))
        }
        XCTAssertGreaterThan(secrets.count, 5,
                             "the contract parser found \(secrets.count) secret keys, which is "
                             + "too few to be right, so this test proves nothing")
        let bridged = Set(ConfigBridge.keys)
        XCTAssertTrue(bridged.isDisjoint(with: secrets),
                      "these are credentials and are reachable as a command argument: "
                      + "\(bridged.intersection(secrets).sorted().joined(separator: ", "))")
    }

    /// Every bridged key is one the contract actually declares. A bridge to a key nobody
    /// wrote down is a private setting wearing a contract key's clothes.
    func testEveryBridgedKeyIsDeclaredInTheContract() throws {
        let contract = try String(
            contentsOf: LaunchConsentGateTests.repoRoot().appendingPathComponent("docs/contract.md"),
            encoding: .utf8)
        for key in ConfigBridge.keys {
            XCTAssertTrue(contract.contains("| `\(key)` |"),
                          "\(key) is bridged but docs/contract.md does not declare it")
        }
    }

    /// And no key is bridged twice, which would make `entry(for:)` silently pick one.
    func testNoKeyIsBridgedTwice() {
        let keys = ConfigBridge.keys
        XCTAssertEqual(Set(keys).count, keys.count, "duplicate keys in the bridge: \(keys)")
    }

    /// Every entry can be READ without throwing or trapping, which is what `grux config`
    /// with no arguments does to all of them at once.
    func testEveryEntryCanBeListed() {
        for entry in ConfigBridge.entries {
            _ = entry.read()
            XCTAssertFalse(entry.shape.isEmpty, "\(entry.key) has no shape to show the reader")
        }
    }
}
