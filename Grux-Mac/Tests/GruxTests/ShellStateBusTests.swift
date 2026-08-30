import XCTest
@testable import Grux

// Pins the bus arbitration SHAPE: coalescing of identical content, the
// priority ladder, hold-window latching, expiry, and the same-source
// downgrade escape hatch. Also pins the palette fuzzy scorer's contract
// (subsequence-or-nil, prefix beats scatter, case-insensitive).
final class ShellStateBusTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    private func moment(
        _ mode: ShellMode,
        headline: String = "h",
        detail: String = "",
        source: String = "test",
        at timestamp: Date? = nil,
        hold: TimeInterval = 0
    ) -> ShellMoment {
        ShellMoment(
            mode: mode,
            headline: headline,
            detail: detail,
            source: source,
            timestamp: timestamp ?? t0,
            hold: hold
        )
    }

    // MARK: - resolve: priority

    func test_higherPriorityReplacesLowerEvenInsideHold() {
        let current = moment(.listening, source: "wake", hold: 30)
        let candidate = moment(.speaking, headline: "Speaking", source: "speech")
        let resolved = ShellStateBus.resolve(current: current, candidate: candidate, now: t0)
        XCTAssertEqual(resolved?.mode, .speaking)
    }

    func test_equalPriorityReplaces() {
        let current = moment(.thinking, headline: "Thinking", source: "chat", hold: 30)
        let candidate = moment(.thinking, headline: "Agents working", source: "agents")
        let resolved = ShellStateBus.resolve(current: current, candidate: candidate, now: t0)
        XCTAssertEqual(resolved?.headline, "Agents working")
    }

    func test_lowerPriorityDroppedWhileHoldLive() {
        let current = moment(.alert, headline: "Off task", source: "focus", hold: 20)
        let candidate = moment(.idle, headline: "Idle", source: "wake")
        let resolved = ShellStateBus.resolve(
            current: current,
            candidate: candidate,
            now: t0.addingTimeInterval(5)
        )
        XCTAssertNil(resolved)
    }

    func test_lowerPriorityAcceptedAfterHoldExpires() {
        let current = moment(.alert, headline: "Off task", source: "focus", hold: 20)
        let candidate = moment(.idle, headline: "Idle", source: "wake")
        let resolved = ShellStateBus.resolve(
            current: current,
            candidate: candidate,
            now: t0.addingTimeInterval(21)
        )
        XCTAssertEqual(resolved?.mode, .idle)
    }

    func test_zeroHoldIsFreelyReplaceable() {
        let current = moment(.thinking, headline: "Thinking", source: "chat", hold: 0)
        let candidate = moment(.idle, headline: "Idle", source: "wake")
        // Same instant: hold 0 means already expired, any candidate lands.
        let resolved = ShellStateBus.resolve(current: current, candidate: candidate, now: t0)
        XCTAssertEqual(resolved?.mode, .idle)
    }

    // MARK: - resolve: same-source downgrade

    func test_owningSourceMayDowngradeInsideHold() {
        let current = moment(.speaking, headline: "Speaking", source: "speech", hold: 60)
        let candidate = moment(.idle, headline: "Idle", source: "speech")
        let resolved = ShellStateBus.resolve(
            current: current,
            candidate: candidate,
            now: t0.addingTimeInterval(1)
        )
        XCTAssertEqual(resolved?.mode, .idle)
    }

    func test_foreignSourceCannotDowngradeInsideHold() {
        let current = moment(.speaking, headline: "Speaking", source: "speech", hold: 60)
        let candidate = moment(.idle, headline: "Idle", source: "chat")
        let resolved = ShellStateBus.resolve(
            current: current,
            candidate: candidate,
            now: t0.addingTimeInterval(1)
        )
        XCTAssertNil(resolved)
    }

    // MARK: - resolve: coalescing

    func test_identicalMomentCoalescesToNil() {
        let current = moment(.listening, headline: "Listening", source: "wake")
        let candidate = moment(.listening, headline: "Listening", source: "wake")
        XCTAssertNil(ShellStateBus.resolve(current: current, candidate: candidate, now: t0))
    }

    func test_sameModeDifferentDetailIsNotCoalesced() {
        let current = moment(.onTask, headline: "On task", detail: "Ship the release", source: "focus")
        let candidate = moment(.onTask, headline: "On task", detail: "Fix glow", source: "focus")
        let resolved = ShellStateBus.resolve(current: current, candidate: candidate, now: t0)
        XCTAssertEqual(resolved?.detail, "Fix glow")
    }

    // MARK: - publish() end to end

    @MainActor
    func test_publishInstallsWinnersAndDropsLosers() {
        let bus = ShellStateBus()
        XCTAssertEqual(bus.current.mode, .idle)

        bus.publish(mode: .speaking, headline: "Speaking", source: "speech", hold: 60)
        XCTAssertEqual(bus.current.mode, .speaking)

        // Foreign lower-priority candidate inside the hold: dropped.
        bus.publish(mode: .listening, headline: "Listening", source: "wake")
        XCTAssertEqual(bus.current.mode, .speaking)

        // Owning source downgrades: lands.
        bus.publish(mode: .idle, headline: "Idle", source: "speech")
        XCTAssertEqual(bus.current.mode, .idle)
    }

    @MainActor
    func test_modeMappingsAreTotal() {
        // Every mode resolves to an accent and an orb state without trapping.
        for mode in ShellMode.allCases {
            _ = mode.accent
            _ = mode.orbState
            XCTAssertFalse(mode.label.isEmpty)
        }
    }

    // MARK: - PaletteFuzzy

    func test_fuzzyRejectsNonSubsequence() {
        XCTAssertNil(PaletteFuzzy.score(query: "xyz", candidate: "Open Chat"))
    }

    func test_fuzzyMatchesSubsequenceCaseInsensitive() {
        XCTAssertNotNil(PaletteFuzzy.score(query: "OPCH", candidate: "open chat"))
    }

    func test_fuzzyPrefixBeatsScatteredMatch() {
        let prefix = PaletteFuzzy.score(query: "open", candidate: "Open Chat")
        let scattered = PaletteFuzzy.score(query: "open", candidate: "Promote subtask to top-level pane")
        XCTAssertNotNil(prefix)
        XCTAssertNotNil(scattered)
        XCTAssertGreaterThan(prefix ?? 0, scattered ?? 0)
    }

    func test_fuzzyEmptyQueryScoresZero() {
        XCTAssertEqual(PaletteFuzzy.score(query: "", candidate: "anything"), 0)
    }

    func test_rankFiltersAndOrders() {
        let actions = [
            PaletteAction(id: "a", title: "Open Chat", subtitle: "Go to tab", systemImage: "x", run: {}),
            PaletteAction(id: "b", title: "Stop listening", subtitle: "Mute the mic", systemImage: "x", run: {}),
            PaletteAction(id: "c", title: "New chat", subtitle: "Start a fresh thread", systemImage: "x", run: {})
        ]
        let ranked = PaletteFuzzy.rank(actions, query: "chat")
        XCTAssertEqual(ranked.map(\.id).sorted(), ["a", "c"])
        // Empty query passes through untouched.
        XCTAssertEqual(PaletteFuzzy.rank(actions, query: "  ").map(\.id), ["a", "b", "c"])
    }
}
