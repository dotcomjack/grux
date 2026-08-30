import XCTest
@testable import Grux

/// `grux remove` run twice on an unchanged world reports the same thing twice.
///
/// The memory that makes that true was keyed on `id`, and a schedule's id IS ITS TITLE, so
/// two jobs both called "Daily backup" collapsed onto one entry: removing the second EVICTED
/// the first, and the first uuid became unrecoverable. Rerunning the first removal exited 1
/// against a command that had exited 0 on an unchanged world, which is the idempotence rule
/// this whole mechanism exists to keep.
///
/// Identity is the alias when there is one, because two things can be called the same thing
/// and only one can have the same uuid.
@MainActor
final class RemovalMemoryTests: XCTestCase {

    private let noun = "unit-test-noun"

    /// REMOVED, NOT RESTORED. UserDefaults survives a `swift test` run, so putting a value
    /// back that was never there is how a suite starts carrying state between runs.
    override func tearDown() async throws {
        UserDefaults.standard.removeObject(
            forKey: GruxControlTools.removalMemoryKey(noun))
    }

    override func setUp() async throws {
        UserDefaults.standard.removeObject(
            forKey: GruxControlTools.removalMemoryKey(noun))
    }

    // MARK: - Identity

    func testTheAliasIsTheIdentityWhenThereIsOne() {
        XCTAssertEqual(GruxControlTools.removalIdentity(id: "Daily backup", alias: "UUID-A"),
                       "uuid-a")
        XCTAssertEqual(GruxControlTools.removalIdentity(id: "d1.example.com", alias: ""),
                       "d1.example.com")
        // Case insensitively, like every other match in this pair of handlers.
        XCTAssertEqual(GruxControlTools.removalIdentity(id: "Work", alias: ""),
                       GruxControlTools.removalIdentity(id: "work", alias: ""))
    }

    // MARK: - The eviction that lost a uuid

    /// The measured failure: two jobs with one title, and the second removal ate the first.
    func testTwoThingsWithOneTitleBothSurviveInMemory() {
        GruxControlTools.removalRemember(noun: noun, id: "Daily backup",
                                         label: "Daily backup", alias: "uuid-a")
        GruxControlTools.removalRemember(noun: noun, id: "Daily backup",
                                         label: "Daily backup", alias: "uuid-b")

        let entries = GruxControlTools.removalList(GruxControlTools.removalMemoryKey(noun))
        let aliases = entries.map { GruxControlTools.removalMemoryParts($0).alias }
        XCTAssertEqual(Set(aliases), ["uuid-a", "uuid-b"],
            "removing the second job with the same title evicted the first, so rerunning "
            + "the first removal cannot find it and exits 1 on an unchanged world")
        XCTAssertEqual(entries.count, 2)
    }

    /// The same thing removed, added back and removed again is ONE entry, not two. That is
    /// what the dedupe is for, and keying on identity must not lose it.
    func testTheSameThingRemovedTwiceIsOneEntry() {
        GruxControlTools.removalRemember(noun: noun, id: "Daily backup",
                                         label: "Daily backup", alias: "uuid-a")
        GruxControlTools.removalRemember(noun: noun, id: "Renamed backup",
                                         label: "Renamed backup", alias: "uuid-a")
        let entries = GruxControlTools.removalList(GruxControlTools.removalMemoryKey(noun))
        XCTAssertEqual(entries.count, 1,
            "one thing, removed twice under two titles, is remembered twice")
        XCTAssertEqual(GruxControlTools.removalMemoryParts(entries[0]).label, "Renamed backup",
            "the newer entry did not replace the older one")
    }

    // MARK: - The round trip, and the older format

    func testAnEntryReadsBackAsWhatWasWritten() {
        GruxControlTools.removalRemember(noun: noun, id: "Daily backup",
                                         label: "Daily backup", alias: "uuid-a")
        let parts = GruxControlTools.removalMemoryParts(
            GruxControlTools.removalList(GruxControlTools.removalMemoryKey(noun))[0])
        XCTAssertEqual(parts.id, "Daily backup")
        XCTAssertEqual(parts.alias, "uuid-a")
    }

    /// A two field entry written by an older build still reads, with no alias, which is
    /// exactly what it meant before there was one.
    func testAnOlderTwoFieldEntryStillReads() {
        let old = "d1.example.com\u{1F}Example one"
        let parts = GruxControlTools.removalMemoryParts(old)
        XCTAssertEqual(parts.id, "d1.example.com")
        XCTAssertEqual(parts.label, "Example one")
        XCTAssertEqual(parts.alias, "")
    }

    // MARK: - The cap

    /// A teardown script that removes twenty things and is re-run from the top must not find
    /// its first steps evicted. 16 did, which is the case the memory exists to serve.
    func testABatchTeardownDoesNotEvictItsOwnEarliestSteps() {
        XCTAssertGreaterThanOrEqual(GruxControlTools.removalMemoryLimit, 100,
            "the memory holds \(GruxControlTools.removalMemoryLimit) removals, so a script "
            + "that removes more than that and re-runs exits 1 on its earliest steps")

        for i in 1...25 {
            GruxControlTools.removalRemember(noun: noun, id: "d\(i).example.com",
                                             label: "", alias: "")
        }
        let ids = GruxControlTools.removalList(GruxControlTools.removalMemoryKey(noun))
            .map { GruxControlTools.removalMemoryParts($0).id }
        XCTAssertTrue(ids.contains("d1.example.com"),
            "the first of twenty five removals was evicted, so re-running the script from "
            + "the top fails on it")
        XCTAssertEqual(ids.count, 25)
    }
}
