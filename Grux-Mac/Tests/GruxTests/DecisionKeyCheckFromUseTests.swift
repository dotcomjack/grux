import XCTest
@testable import Grux

/// D166 item 3: Integrations, Decisions read "Key saved, not checked yet" on a
/// day Jev had answered Grux's decisions with that very key. A real decision
/// is a check: one that answers says the key works, one TypeSafe refuses (401,
/// 403) says it does not, and any other failure says nothing about the key.
@MainActor
final class DecisionKeyCheckFromUseTests: XCTestCase {

    private let key = "apikey_0123456789abcd"
    private let q: [String: DecisionQuestion] = ["intent": .choice(instructions: "?", criteria: ["close_all": "x"])]

    private struct Answering: DecisionProvider {
        let kind: DecisionProviderKind = .jev
        func decide(state: String, questions: [String: DecisionQuestion]) async throws -> DecisionResult {
            DecisionResult(answers: ["intent": .choice("close_all", confidence: 0.9, probabilities: [:])],
                           latencyMs: 300, inputTokens: 100, outputTokens: 5, provider: .jev)
        }
    }

    private struct Throwing: DecisionProvider {
        let kind: DecisionProviderKind = .jev
        let error: Error
        func decide(state: String, questions: [String: DecisionQuestion]) async throws -> DecisionResult {
            throw error
        }
    }

    private func engine(_ provider: DecisionProvider,
                        into checks: @escaping (DecisionsSection.KeyCheckRecord) -> Void) -> DecisionEngine {
        DecisionEngine(keyLookup: { [key] in key }, ledger: DecisionLedger(storeURL: nil),
                       remote: { _ in provider }, keyChecked: checks)
    }

    func test_aDecisionJevAnsweredMarksThisKeyConnected() async {
        var seen: [DecisionsSection.KeyCheckRecord] = []
        _ = await engine(Answering()) { seen.append($0) }.decide(surface: "s", state: "close everything", questions: q)
        XCTAssertEqual(seen.map(\.result), [.worked])
        XCTAssertEqual(seen.first?.keyTail, "abcd")
        XCTAssertEqual(DecisionsSection.headline(key: key, record: seen.first), "Connected")
    }

    func test_aBatchedEventJevAnsweredMarksThisKeyConnected() async {
        var seen: [DecisionsSection.KeyCheckRecord] = []
        let e = engine(Answering()) { seen.append($0) }
        let origin = "keycheck-\(UUID().uuidString.prefix(8))"
        let event = e.open(origin: origin, state: "Heard: open my calendar", covering: [origin])
        event.ask(origin, ["intent": .choice(instructions: "i", criteria: ["tab:calendar": "open my calendar"])])
        await e.resolve(event)
        e.close(event)
        XCTAssertEqual(seen.map(\.result), [.worked])
    }

    func test_aKeyTypeSafeRefusesInUseReadsRefused() async {
        for code in [401, 403] {
            var seen: [DecisionsSection.KeyCheckRecord] = []
            _ = await engine(Throwing(error: JevDecisionProvider.Failure.http(code))) { seen.append($0) }
                .decide(surface: "s", state: "close everything", questions: q)
            XCTAssertEqual(seen.map(\.result), [.refused], "HTTP \(code)")
            XCTAssertEqual(DecisionsSection.headline(key: key, record: seen.first), "Key saved, TypeSafe refused it")
        }
    }

    /// Out of credit, rate limited, a server error, a timeout, offline, an
    /// unreadable answer: none of them is about the key, so none overwrites
    /// what the last check found.
    func test_aFailureThatSaysNothingAboutTheKeyRecordsNothing() async {
        let errors: [Error] = [JevDecisionProvider.Failure.http(402), JevDecisionProvider.Failure.http(400),
                               JevDecisionProvider.Failure.http(404), JevDecisionProvider.Failure.http(429),
                               JevDecisionProvider.Failure.http(500), JevDecisionProvider.Failure.malformed,
                               URLError(.timedOut), URLError(.notConnectedToInternet)]
        for error in errors {
            var seen: [DecisionsSection.KeyCheckRecord] = []
            _ = await engine(Throwing(error: error)) { seen.append($0) }
                .decide(surface: "s", state: "close everything", questions: q)
            XCTAssertTrue(seen.isEmpty, "\(error)")
        }
    }

    /// W54-P3 item 1: a call that carried an old key lands after the person
    /// saved a new one (Save & Test, Disconnect). Its verdict is about the old
    /// key, so it must not overwrite the new key's record.
    func test_aCallWhoseKeyWasReplacedMeanwhileRecordsNothing() async {
        final class Saved: @unchecked Sendable { var key = "apikey_0123456789abcd" }
        let saved = Saved()
        struct Replacing: DecisionProvider {
            let kind: DecisionProviderKind = .jev
            let saved: Saved
            let error: Error?
            func decide(state: String, questions: [String: DecisionQuestion]) async throws -> DecisionResult {
                saved.key = "apikey_9999999999wxyz"
                if let error { throw error }
                return DecisionResult(answers: [:], latencyMs: 300, inputTokens: 1, outputTokens: 1, provider: .jev)
            }
        }
        for error in [nil, JevDecisionProvider.Failure.http(401) as Error?] {
            saved.key = "apikey_0123456789abcd"
            var seen: [DecisionsSection.KeyCheckRecord] = []
            let e = DecisionEngine(keyLookup: { saved.key }, ledger: DecisionLedger(storeURL: nil),
                                   remote: { _ in Replacing(saved: saved, error: error) }, keyChecked: { seen.append($0) })
            _ = await e.decide(surface: "s", state: "close everything", questions: q)
            XCTAssertTrue(seen.isEmpty, "\(String(describing: error))")
        }
    }

    /// No key, no call, no check.
    func test_noKeyRecordsNothing() async {
        var seen: [DecisionsSection.KeyCheckRecord] = []
        let e = DecisionEngine(keyLookup: { "" }, ledger: DecisionLedger(storeURL: nil),
                               remote: { _ in Answering() }, keyChecked: { seen.append($0) })
        _ = await e.decide(surface: "s", state: "close everything", questions: q)
        XCTAssertTrue(seen.isEmpty)
    }

    /// The shared engine writes what it finds where the Decisions card reads
    /// it, and never from the suite.
    func test_theSharedEngineWritesNothingUnderTest() {
        XCTAssertTrue(DecisionEngine.isUnderTest)
        XCTAssertNil(DecisionEngine.keyCheckFromUse(error: nil, key: ""))
        XCTAssertEqual(DecisionEngine.keyCheckFromUse(error: nil, key: key)?.result, .worked)
    }
}
