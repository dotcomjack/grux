import XCTest
@testable import Grux

// Validates proposal book 001, the kickoff cycle's first ranked book.
// The committed copy at docs/foundry/proposal-book-001.json is decoded
// through the exact ProposalStore load path (Persistence.load with
// ISO8601 dates), proving the live store at
// ~/Library/Application Support/Grux/foundry/proposals.json (same
// bytes) loads cleanly. Never touches the real store on disk.
@MainActor
final class FoundryProposalBookTests: XCTestCase {

    private var bookURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // GruxTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // Grux-Mac
            .appendingPathComponent("docs/foundry/proposal-book-001.json")
    }

    func test_book001_decodesThroughProposalStore() throws {
        let store = ProposalStore(storageURL: bookURL)
        XCTAssertEqual(store.proposals.count, 22, "kickoff book carries 22 proposals")
        // Every proposal enters the ranked queue (all proposed, none terminal).
        XCTAssertEqual(store.ranked().count, 22)
        // Ranked head is the highest expected gain in the book.
        let maxGain = store.proposals.map(\.expectedGain).max() ?? 0
        XCTAssertEqual(store.ranked().first?.expectedGain, maxGain)
    }

    func test_book001_invariants() throws {
        let store = ProposalStore(storageURL: bookURL)
        XCTAssertFalse(store.proposals.isEmpty)
        for p in store.proposals {
            XCTAssertEqual(p.status, .proposed, p.title)
            XCTAssertEqual(p.tierRequired, .propose, "every pair starts at propose: \(p.title)")
            XCTAssertTrue(p.estCostLabel.contains("estimated"), "cost must be labeled estimated: \(p.title)")
            XCTAssertTrue(p.estCostLabel.hasPrefix("$"), "cost written as $N: \(p.title)")
            XCTAssertTrue(p.expectedGain > 0 && p.expectedGain <= 1, p.title)
            XCTAssertFalse(p.evidence.isEmpty, "no proposal without evidence: \(p.title)")
            XCTAssertFalse(p.readyPrompt.isEmpty, p.title)
            XCTAssertTrue(p.readyPrompt.contains(".worktrees/grux-roadmap"),
                          "ready prompt carries the worktree path: \(p.title)")
            // The dash ban holds across every string the book ships.
            for text in [p.title, p.readyPrompt, p.estCostLabel] + p.evidence.map(\.detail) {
                XCTAssertFalse(text.contains("\u{2014}"), "em dash in \(p.title)")
                XCTAssertFalse(text.contains("\u{2013}"), "en dash in \(p.title)")
            }
        }
    }

    func test_book001_nothingTouchesProtectedZones() throws {
        let store = ProposalStore(storageURL: bookURL)
        for p in store.proposals {
            XCTAssertFalse(TrustLedger.touchesProtectedZone(p),
                           "book 001 stays clear of protected zones: \(p.title)")
            XCTAssertNotEqual(p.riskClass, .protected, p.title)
        }
    }

    func test_book001_lanesAndDomainsCoverTheEstate() throws {
        let store = ProposalStore(storageURL: bookURL)
        let lanes = Set(store.proposals.map(\.lane))
        let domains = Set(store.proposals.map(\.domain))
        XCTAssertEqual(lanes, Set(UpgradeLane.allCases), "all six lanes carry at least one proposal")
        XCTAssertEqual(domains, Set(UpgradeDomain.allCases), "all four domains carry at least one proposal")
    }
}
