import XCTest
@testable import GruxAgentCore

final class FactoryWaveTests: XCTestCase {

    private func endpoints() -> DaytonaEndpoints { .documented }

    private func wave(spend: Double = 2, parallel: Int = 4, exits: [Int32]) -> (FactoryWave, WaveFake) {
        let fake = WaveFake(exits: exits)
        let factory = DaytonaFactory(transport: fake, endpoints: endpoints())
        let runner = FactoryWave(maxParallel: parallel, spendUSD: spend)
        return (runner, fake)
    }

    func testOneExitZeroWins() async {
        let (runner, fake) = wave(exits: [1, 0, 2])
        let result = await runner.run([
            WaveCandidate(name: "a", diff: "a\n"),
            WaveCandidate(name: "b", diff: "b\n"),
            WaveCandidate(name: "c", diff: "c\n"),
        ], factory: DaytonaFactory(transport: fake, endpoints: endpoints()))
        XCTAssertEqual(result.winner, "b")
        XCTAssertEqual(result.scores["a"], 1)
        XCTAssertEqual(result.scores["b"], 0)
        XCTAssertEqual(result.scores["c"], 2)
        XCTAssertEqual(fake.creates, 3)
    }

    func testFifthIsRefusedForCap() async {
        let (runner, fake) = wave(exits: [1, 1, 1, 1, 0])
        let names = ["a", "b", "c", "d", "e"]
        let result = await runner.run(names.map { WaveCandidate(name: $0, diff: "\($0)\n") }, factory: DaytonaFactory(transport: fake, endpoints: endpoints()))
        XCTAssertEqual(fake.creates, 4)
        XCTAssertTrue(result.refused.contains { $0.contains("e") && $0.contains("cap") })
        XCTAssertNil(result.scores["e"])
    }

    func testOrgCapClampsAHugeRequest() {
        let runner = FactoryWave(maxParallel: 10_000, spendUSD: 1)
        XCTAssertEqual(FactoryLimits.maxParallel, 250)
        XCTAssertEqual(runner.maxParallel, 250)
        XCTAssertEqual(FactoryWave().maxParallel, 250)
        XCTAssertEqual(FactoryWave().spendUSD, 10_000)
    }

    func testPastTheOrgCapIsRefused() async {
        let fake = WaveFake(exits: Array(repeating: Int32(1), count: 251))
        let runner = FactoryWave()
        let names = (1...251).map { "c\($0)" }
        let result = await runner.run(
            names.map { WaveCandidate(name: $0, diff: "\($0)\n") },
            factory: DaytonaFactory(transport: fake, endpoints: endpoints())
        )
        XCTAssertEqual(fake.creates, 250)
        XCTAssertTrue(result.refused.contains { $0 == "c251 cap" })
        XCTAssertNil(result.scores["c251"])
        XCTAssertEqual(result.scores.count, 250)
    }

    func testKeyShapeIsNotScored() async {
        let fake = WaveFake(exits: [0, 0])
        let runner = FactoryWave(maxParallel: 4, spendUSD: 2)
        let result = await runner.run([
            WaveCandidate(name: "ok", diff: "ok\n"),
            WaveCandidate(name: "secret", diff: "sk-live\n"),
        ], factory: DaytonaFactory(transport: fake, endpoints: endpoints()))
        XCTAssertEqual(fake.creates, 1)
        XCTAssertTrue(result.refused.contains { $0.contains("secret") && $0.contains("key-shape") })
        XCTAssertNil(result.scores["secret"])
    }

    func testFirstExitZeroWinsATie() async {
        let fake = WaveFake(exits: [0, 0])
        let runner = FactoryWave(maxParallel: 4, spendUSD: 2)
        let result = await runner.run([
            WaveCandidate(name: "first", diff: "one\n"),
            WaveCandidate(name: "second", diff: "two\n"),
        ], factory: DaytonaFactory(transport: fake, endpoints: endpoints()))
        XCTAssertEqual(result.winner, "first")
        XCTAssertEqual(result.scores["first"], 0)
        XCTAssertEqual(result.scores["second"], 0)
    }

    func testZeroSpendScoresNothing() async {
        let fake = WaveFake(exits: [0, 0, 0])
        let runner = FactoryWave(maxParallel: 4, spendUSD: 0)
        let result = await runner.run([
            WaveCandidate(name: "a", diff: "a\n"),
            WaveCandidate(name: "b", diff: "b\n"),
        ], factory: DaytonaFactory(transport: fake, endpoints: endpoints()))
        XCTAssertEqual(fake.creates, 0)
        XCTAssertNil(result.winner)
        XCTAssertTrue(result.scores.isEmpty)
        XCTAssertTrue(result.refused.allSatisfy { $0.contains("spend-stop") })
        XCTAssertEqual(result.refused.count, 2)
    }
}

final class WaveFake: DaytonaTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var exits: [Int32]
    private(set) var creates = 0

    init(exits: [Int32]) { self.exits = exits }

    func send(_ request: URLRequest) async throws -> (Int, Data) {
        let method = request.httpMethod ?? "GET"
        let url = request.url?.absoluteString ?? ""
        if method == "POST" && url.contains("/process/execute") {
            lock.lock()
            let code = exits.isEmpty ? 1 : exits.removeFirst()
            lock.unlock()
            return (200, Data("{\"exitCode\":\(code),\"result\":\"\"}".utf8))
        }
        if method == "POST" && url.contains("/api/sandbox") {
            lock.lock()
            creates += 1
            lock.unlock()
            return (200, Data(#"{"id":"sb-wave"}"#.utf8))
        }
        if method == "GET" {
            return (200, Data(#"{"sandboxes":[]}"#.utf8))
        }
        return (200, Data())
    }
}
