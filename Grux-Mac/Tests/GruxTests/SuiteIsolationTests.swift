import XCTest
@testable import Grux

/// THE SUITE NEVER READS THE OPERATOR'S CREDENTIALS OR THEIR DIARY.
///
/// `Persistence` has been isolated for a long time and these two were not, so
/// a test could read a real API key and a real calendar. Both were measured
/// during P-F-1: a render of `IntegrationsView` drew the real Decisions key,
/// and a render of the first-run flow drew real calendar events into a PNG.
/// Neither read prompts, which is exactly why nothing caught them.
@MainActor
final class SuiteIsolationTests: XCTestCase {

    private static func source(_ relative: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(relative), encoding: .utf8)
    }

    func test_theKeychainIsAnEmptyRoomUntilATestPutsSomethingInIt() {
        XCTAssertTrue(KeychainStore.isUnderTest, "control: this is a test run")
        // Every shipped slot reads empty, whatever this Mac actually holds.
        for key in [KeychainStore.Key.anthropicApiKey, .typesafeApiKey, .elevenLabsApiKey, .braveApiKey] {
            XCTAssertEqual(KeychainStore.get(key), "", "\(key.rawValue) read a real credential")
            XCTAssertFalse(KeychainStore.exists(key), "\(key.rawValue) reports present from the real keychain")
        }
        // And a test that wants one gets exactly what it set, nothing else.
        XCTAssertTrue(KeychainStore.set(.braveApiKey, "set-by-this-test"))
        XCTAssertEqual(KeychainStore.get(.braveApiKey), "set-by-this-test")
        XCTAssertTrue(KeychainStore.exists(.braveApiKey))
        XCTAssertTrue(KeychainStore.delete(.braveApiKey))
        XCTAssertEqual(KeychainStore.get(.braveApiKey), "")
    }

    /// The behavioural test above passes on a Mac that simply holds no keys,
    /// so the structural half is what makes it mean something: every door
    /// into the keychain answers from the in-process store under test.
    func test_everyKeychainDoorIsGuarded() throws {
        let src = try Self.source("Sources/Grux/KeychainStore.swift")
        for door in ["static func set(_ key: Key, _ value: String) -> Bool {",
                     "static func get(_ key: Key) -> String {",
                     "static func exists(_ key: Key) -> Bool {",
                     "static func delete(_ key: Key) -> Bool {"] {
            let r = try XCTUnwrap(src.range(of: door), "\(door) moved")
            let head = String(src[r.upperBound...].prefix(220))
            XCTAssertTrue(head.contains("if isUnderTest {"),
                          "\(door) reaches securityd from a test run")
        }
    }

    func test_theCalendarIsEmptyUnderTest() throws {
        XCTAssertTrue(CalendarService.isUnderTest)
        XCTAssertFalse(CalendarService.shared.hasAccess, "a test can read the operator's calendar")
        let day = Date()
        XCTAssertEqual(CalendarService.shared.events(from: day.addingTimeInterval(-86_400),
                                                     to: day.addingTimeInterval(86_400)).count, 0)
        XCTAssertEqual(CalendarCorrelator.eventsInWindow(windowStart: day.addingTimeInterval(-86_400),
                                                         windowEnd: day.addingTimeInterval(86_400)).count, 0)
        // Both readers, because one guarded reader with an unguarded twin is
        // not isolation. `CalendarCorrelator` is the twin.
        let correlator = try Self.source("Sources/Grux/Ambient/CalendarCorrelator.swift")
        XCTAssertTrue(correlator.contains("!CalendarService.isUnderTest"), "the second reader is unguarded")
    }
}
