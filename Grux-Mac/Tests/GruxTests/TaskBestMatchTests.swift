import XCTest
@testable import Grux

/// D150 (found removing D147's test tasks, `logs/d147/cleanup.txt`): with
/// "Stretch" and "Stretch in 2 minutes" both on the list, "remove the task
/// Stretch in 2 minutes" removed "Stretch", and "remove the task Call the
/// dentist tomorrow at 9 AM" removed "Call the dentist": the tools took the
/// first title that matched at all. The closest title wins now, an exact one
/// first, wherever a title is picked from the words.
@MainActor
final class TaskBestMatchTests: XCTestCase {

    private func pick(_ titles: [String], _ query: String) -> String? {
        ChatService.bestMatch(titles, title: { $0 }, query: query)
    }

    func testTheExactTitleWinsInEitherOrder() {
        for titles in [["Stretch", "Stretch in 2 minutes"], ["Stretch in 2 minutes", "Stretch"]] {
            XCTAssertEqual(pick(titles, "stretch in 2 minutes"), "Stretch in 2 minutes", "\(titles)")
            XCTAssertEqual(pick(titles, "Stretch"), "Stretch", "\(titles)")
            XCTAssertEqual(pick(titles, "  STRETCH "), "Stretch", "\(titles)")
        }
        for titles in [["Call the dentist", "Call the dentist tomorrow at 9 AM"],
                       ["Call the dentist tomorrow at 9 AM", "Call the dentist"]] {
            XCTAssertEqual(pick(titles, "call the dentist tomorrow at 9 am"), "Call the dentist tomorrow at 9 AM", "\(titles)")
            XCTAssertEqual(pick(titles, "call the dentist"), "Call the dentist", "\(titles)")
        }
    }

    /// With no exact title, the one closest to the words wins.
    func testTheClosestTitleWins() {
        XCTAssertEqual(pick(["Stretch", "Stretch in 2 minutes"], "stretch in 2"), "Stretch in 2 minutes")
        XCTAssertEqual(pick(["Water the office plants", "Water"], "water the office plants today"),
                       "Water the office plants")
        // A containment beats a token match.
        XCTAssertEqual(pick(["Plants: water the office ones", "Water the plants"], "water the plants"), "Water the plants")
        // Equally close: the first, as before.
        XCTAssertEqual(pick(["Back up the Mini", "Back up the iMac"], "back up"), "Back up the Mini")
    }

    /// W47-FIX P2 2: a short title inside the words beat the task they
    /// named, because any containment outranked any share of words.
    func testTheTitleThatHoldsMostOfTheWordsWins() {
        for titles in [["Email", "Email Sarah the deck"], ["Email Sarah the deck", "Email"]] {
            XCTAssertEqual(pick(titles, "email the deck"), "Email Sarah the deck", "\(titles)")
            XCTAssertEqual(pick(titles, "email"), "Email", "\(titles)")
        }
        for titles in [["Gym", "Book the gym class for Friday"], ["Book the gym class for Friday", "Gym"]] {
            XCTAssertEqual(pick(titles, "gym class"), "Book the gym class for Friday", "\(titles)")
            XCTAssertEqual(pick(titles, "gym"), "Gym", "\(titles)")
        }
        // A title found only inside another word ("run" in "prune") ranks last.
        XCTAssertEqual(pick(["Run", "Prune the plants"], "prune the office plants"), "Prune the plants")
        XCTAssertEqual(pick(["Prune the plants", "Run"], "prune the office plants"), "Prune the plants")
    }

    /// Round 2 P2 4: "the" counted as an asked word, so "mark the gym as
    /// done" (the words "the gym") picked "Book the gym class".
    func testLittleWordsDoNotCount() {
        for titles in [["Gym", "Book the gym class"], ["Book the gym class", "Gym"]] {
            XCTAssertEqual(pick(titles, "the gym"), "Gym", "\(titles)")
            XCTAssertEqual(pick(titles, "my gym"), "Gym", "\(titles)")
        }
    }

    func testOneLooseMatchStillMatchesAndNoneIsNone() {
        XCTAssertEqual(pick(["Water the office plants"], "water plants"), "Water the office plants")
        XCTAssertNil(pick(["Water the office plants"], "call mom"))
        XCTAssertNil(pick([], "call mom"))
        XCTAssertNil(pick(["Call mom"], "   "))
    }

    /// Every tool that picks a task or a proposed action by its words picks
    /// the closest one, never the first that matches.
    func testNoToolTakesTheFirstMatch() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Grux/ChatService.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(source.contains(".first(where: { Self.fuzzyMatches("), "a tool still takes the first match")
        XCTAssertEqual(source.components(separatedBy: "Self.bestMatch(").count - 1, 5)
    }
}
