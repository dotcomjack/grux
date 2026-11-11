import XCTest
@testable import Grux

// D120: the Cognition Map listed every chat question twice (the gate's
// "Confident enough to proceed." card with a score and no memories, then the
// completed turn with memories and "n/a"), so every count read doubled, and
// its Decision trace header said 500 over the 60 cards it lists.
@MainActor
final class CognitionMapOneCardPerTurnTests: XCTestCase {

    private func verdict(_ confidence: Double, confused: Bool = false) -> ConfidenceVerdict {
        confused
            ? .confused(confidence, question: "Which file do you mean?", reason: "test reason")
            : .confident(confidence, reason: "test reason")
    }

    private func events(_ trigger: String) -> [CognitionEvent] {
        CognitionTrace.shared.events.filter { $0.trigger == trigger }
    }

    func test_aConfidentChatTurnIsOneCardCarryingTheGateScoreAndItsMemories() {
        let q = "d120 confident \(UUID().uuidString)"
        let v = verdict(0.85)
        CognitionTrace.shared.noteGate(v, trigger: q, mode: "simulate")
        CognitionTrace.shared.noteTurn(trigger: q, gate: v, heuristicsFired: [],
                                       memoriesRetrieved: ["a", "b"], mode: "simulate",
                                       outcome: "204")
        let cards = events(q)
        XCTAssertEqual(cards.count, 1, "one question, one card")
        XCTAssertEqual(cards.first?.confidence, 0.85)
        XCTAssertEqual(cards.first?.memoriesRetrieved, ["a", "b"])
        XCTAssertEqual(cards.first?.outcome, "204")
        XCTAssertEqual(cards.first?.gateReason, "test reason")
    }

    func test_aTurnTheGateStopsToAskIsOneCardWithTheQuestion() {
        let q = "d120 confused \(UUID().uuidString)"
        let recorded = CognitionTrace.shared.noteGate(verdict(0.2, confused: true), trigger: q, mode: "simulate")
        XCTAssertNotNil(recorded)
        XCTAssertEqual(events(q).count, 1)
        XCTAssertEqual(events(q).first?.gateVerdict, "clarify")
        XCTAssertEqual(events(q).first?.outcome, "Which file do you mean?")
    }

    func test_aTurnWithNoGateRunCarriesNoInventedScore() {
        let q = "d120 image \(UUID().uuidString)"
        CognitionTrace.shared.noteTurn(trigger: q, gate: nil, heuristicsFired: [],
                                       memoriesRetrieved: [], mode: "simulate", outcome: "ok")
        XCTAssertEqual(events(q).count, 1)
        XCTAssertNil(events(q).first?.confidence)
    }

    func test_chatServiceRecordsTheGateOnlyThroughNoteGateAndTheTurnThroughNoteTurn() throws {
        let src = try String(contentsOfFile: Self.source("Sources/Grux/ChatService.swift"), encoding: .utf8)
        XCTAssertFalse(src.contains("note(confidence:"), "a confident gate verdict must not become its own card")
        XCTAssertTrue(src.contains("CognitionTrace.shared.noteGate("))
        XCTAssertTrue(src.contains("CognitionTrace.shared.noteTurn("))
    }

    // A log written before the fix: fold each gate card into the turn it led to.
    private func gateCard(_ q: String, at t: Date, conf: Double = 0.85) -> CognitionEvent {
        CognitionEvent(timestamp: t, kind: .prompt, trigger: q, gateReason: "clear request",
                       confidence: conf, mode: "simulate", outcome: "Confident enough to proceed.")
    }
    private func turnCard(_ q: String, at t: Date) -> CognitionEvent {
        CognitionEvent(timestamp: t, kind: .prompt, trigger: q, memoriesRetrieved: ["m"],
                       confidence: nil, mode: "simulate", outcome: "reply to \(q)")
    }

    func test_oldLogPairsFoldIntoOneCardPerQuestion() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        // Newest first, as stored.
        let log = [
            turnCard("two", at: t0.addingTimeInterval(130)),
            gateCard("two", at: t0.addingTimeInterval(120)),
            turnCard("one", at: t0.addingTimeInterval(4)),
            gateCard("one", at: t0, conf: 0.82),
        ]
        let folded = CognitionTrace.foldingChatGatePairs(log)
        XCTAssertEqual(folded.map(\.trigger), ["two", "one"])
        XCTAssertEqual(folded.map(\.confidence), [0.85, 0.82])
        XCTAssertEqual(folded.map(\.outcome), ["reply to two", "reply to one"])
        XCTAssertEqual(folded.map(\.gateReason), ["clear request", "clear request"])
    }

    func test_foldLeavesAloneWhatIsNotAPair() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let clarify = CognitionEvent(timestamp: t0, kind: .prompt, trigger: "x", gateVerdict: "clarify",
                                     confidence: 0.2, mode: "simulate", outcome: "Which one?")
        let log = [
            // A gate card whose turn never completed (the reply failed): kept.
            gateCard("lonely", at: t0.addingTimeInterval(500)),
            // A completed turn far later than the gate card for the same words: a new ask, kept apart.
            turnCard("again", at: t0.addingTimeInterval(400 + CognitionTrace.gatePairWindow + 1)),
            gateCard("again", at: t0.addingTimeInterval(400)),
            // Exactly at the window: still one turn.
            turnCard("edge", at: t0.addingTimeInterval(200 + CognitionTrace.gatePairWindow)),
            gateCard("edge", at: t0.addingTimeInterval(200)),
            // A completed turn OLDER than the gate card cannot be the turn it led to.
            gateCard("order", at: t0.addingTimeInterval(100)),
            turnCard("order", at: t0.addingTimeInterval(90)),
            clarify,
        ]
        let folded = CognitionTrace.foldingChatGatePairs(log)
        XCTAssertEqual(folded.map(\.trigger), ["lonely", "again", "again", "edge", "order", "order", "x"])
        XCTAssertEqual(folded.first(where: { $0.trigger == "edge" })?.confidence, 0.85)
        XCTAssertEqual(folded.last?.gateVerdict, "clarify")
    }

    func test_twoAsksOfTheSameWordsEachKeepTheirOwnScore() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let log = [
            turnCard("same", at: t0.addingTimeInterval(15)),
            gateCard("same", at: t0.addingTimeInterval(10), conf: 0.9),
            turnCard("same", at: t0.addingTimeInterval(5)),
            gateCard("same", at: t0, conf: 0.7),
        ]
        let folded = CognitionTrace.foldingChatGatePairs(log)
        XCTAssertEqual(folded.count, 2)
        XCTAssertEqual(folded.map(\.confidence), [0.9, 0.7])
    }

    // The Decision trace header.
    func test_theTraceHeaderCountsWhatItListsAndSaysWhatItDoesNot() {
        let cap = CognitionMapView.logCap
        XCTAssertEqual(CognitionMapView.traceListing(total: 0).listed, 0)
        XCTAssertNil(CognitionMapView.traceListing(total: 0).note)
        XCTAssertEqual(CognitionMapView.traceListing(total: cap - 1).listed, cap - 1)
        XCTAssertNil(CognitionMapView.traceListing(total: cap - 1).note)
        XCTAssertEqual(CognitionMapView.traceListing(total: cap).listed, cap)
        XCTAssertNil(CognitionMapView.traceListing(total: cap).note)
        XCTAssertEqual(CognitionMapView.traceListing(total: cap + 1).listed, cap)
        XCTAssertEqual(CognitionMapView.traceListing(total: cap + 1).note, "The newest \(cap) of \(cap + 1).")
        XCTAssertEqual(CognitionMapView.traceListing(total: 500).note, "The newest \(cap) of 500.")
    }

    private static func source(_ rel: String) -> String {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            url.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url.appendingPathComponent(rel).path
            }
        }
        return rel
    }

    // Wave 36: since a confident gate is no longer its own card, the turn's
    // card must be recorded with memory off too, or the turn vanishes.
    func test_aConfidentTurnWithMemoryOffIsStillOneCardWithTheGateScore() {
        let q = "w36 memory off \(UUID().uuidString)"
        let v = verdict(0.8)
        CognitionTrace.shared.noteGate(v, trigger: q, mode: "simulate")
        var asked = false
        ChatService.recordTurnTrace(userText: q, gate: v, memoryEnabled: false,
                                    outcome: "reply", retrieve: { _ in asked = true; return ["m"] })
        let cards = events(q)
        XCTAssertEqual(cards.count, 1, "one question, one card, memory on or off")
        XCTAssertEqual(cards.first?.confidence, 0.8)
        XCTAssertEqual(cards.first?.memoriesRetrieved, [], "memory off retrieves nothing")
        XCTAssertFalse(asked, "memory off must not search memory")
    }

    func test_aConfidentTurnWithMemoryOnCarriesWhatWasRetrieved() {
        let q = "w36 memory on \(UUID().uuidString)"
        let v = verdict(0.9)
        ChatService.recordTurnTrace(userText: q, gate: v, memoryEnabled: true,
                                    outcome: "reply", retrieve: { _ in ["m1", "m2"] })
        XCTAssertEqual(events(q).count, 1)
        XCTAssertEqual(events(q).first?.memoriesRetrieved, ["m1", "m2"])
        XCTAssertEqual(events(q).first?.confidence, 0.9)
    }

    // The send path records the card at the reply's own depth (not inside the
    // memory block), and the failure path records it when a gate let the turn
    // go ahead; the only noteTurn call in ChatService is the helper's.
    func test_chatServiceRecordsTheTurnCardOutsideTheMemorySwitchAndOnFailure() throws {
        let src = try String(contentsOfFile: Self.source("Sources/Grux/ChatService.swift"), encoding: .utf8)
        XCTAssertEqual(src.components(separatedBy: "CognitionTrace.shared.noteTurn(").count - 1, 1,
                       "one noteTurn call, inside recordTurnTrace")
        let reply = try XCTUnwrap(src.range(of: "WakeLog.shared.log(\"reply received ("))
        let call = try XCTUnwrap(src.range(of: "Self.recordTurnTrace(", range: reply.upperBound..<src.endIndex))
        let between = src[reply.upperBound..<call.lowerBound]
        let depth = between.filter { $0 == "{" }.count - between.filter { $0 == "}" }.count
        XCTAssertEqual(depth, 0, "the turn's card is recorded at the reply's depth, not inside `if memoryEnabled`")
        let failed = try XCTUnwrap(src.range(of: "WakeLog.shared.log(\"reply FAILED:"))
        let catchStart = try XCTUnwrap(src.range(of: "} catch {", options: .backwards, range: src.startIndex..<failed.lowerBound))
        XCTAssertTrue(src[catchStart.upperBound..<failed.lowerBound].contains("Self.recordTurnTrace("),
                      "a failed turn the gate let go ahead keeps its one card")
    }
}
