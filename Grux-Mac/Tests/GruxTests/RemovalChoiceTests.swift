import XCTest
@testable import GruxSetupCore

/// `grux remove schedule <title>` against ONE live schedule refused as ambiguous.
///
/// Found live (loop sweep 2): a schedule titled "smoke: hello world" was removed, a new one
/// with the same title was added, and removing the new one by its title printed "More than
/// one thing here answers to smoke: hello world" and exited 1, listing the live uuid beside
/// the uuid of the one already gone. The app's own remover already knew that a thing already
/// gone cannot make a live one ambiguous; the CLI matched the rows again itself and did not.
final class RemovalChoiceTests: XCTestCase {

    private func row(_ label: String, alias: String, tracked: Bool) -> [String: Any] {
        ["id": label, "label": label, "alias": alias, "tracked": tracked]
    }

    func testARememberedRemovalDoesNotMakeALiveOneAmbiguous() {
        let rows = [row("smoke: hello world", alias: "LIVE", tracked: true),
                    row("smoke: hello world", alias: "GONE", tracked: false)]
        let hits = RemovalChoice.candidates(for: "smoke: hello world", in: rows)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?["alias"] as? String, "LIVE")
    }

    func testTwoLiveOnesWithOneTitleStillRefuse() {
        let rows = [row("Daily backup", alias: "A", tracked: true),
                    row("Daily backup", alias: "B", tracked: true),
                    row("Daily backup", alias: "C", tracked: false)]
        let hits = RemovalChoice.candidates(for: "daily backup", in: rows)
        XCTAssertEqual(hits.compactMap { $0["alias"] as? String }, ["A", "B"])
    }

    /// Idempotence stays: with nothing live, the remembered row is what the rerun finds.
    func testWithNothingLiveTheRememberedRowAnswers() {
        let rows = [row("Daily backup", alias: "GONE", tracked: false)]
        XCTAssertEqual(RemovalChoice.candidates(for: "GONE", in: rows).count, 1)
        XCTAssertEqual(RemovalChoice.candidates(for: "Daily backup", in: rows).count, 1)
    }

    /// Two removed things with one title: both are already gone, so a rerun has nothing to
    /// choose between and answers with one of them rather than refusing.
    func testTwoRememberedRowsWithOneTitleAreOneAnswer() {
        let rows = [row("Daily backup", alias: "GONE1", tracked: false),
                    row("Daily backup", alias: "GONE2", tracked: false)]
        XCTAssertEqual(RemovalChoice.candidates(for: "Daily backup", in: rows).count, 1)
    }

    func testTheUuidPicksExactlyThatOne() {
        let rows = [row("Daily backup", alias: "A", tracked: true),
                    row("Daily backup", alias: "B", tracked: true)]
        XCTAssertEqual(RemovalChoice.candidates(for: "b", in: rows)
            .first?["alias"] as? String, "B")
        XCTAssertTrue(RemovalChoice.candidates(for: "nothing", in: rows).isEmpty)
    }

    /// GruxCLI is an executable module and cannot be imported, so this pins that the
    /// shipped `grux remove` decides through the shared choice instead of its own filter.
    func testTheCLIRemoverUsesTheSharedChoice() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/GruxCLI/Commands/Remove.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("RemovalChoice.candidates(for: askedValue, in: items)"))
        XCTAssertFalse(text.contains("items.filter { Remove.matches(askedValue"))
    }
}
