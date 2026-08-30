import XCTest
@testable import Grux

/// SIX PROMPTS, ONE GPU, A HUNDRED AND TWO SECONDS OF WAITING.
///
/// Measured on the owner's machine with qwen3:8b loaded: `lsof` showed six
/// established connections from Grux to Ollama at once, and a trivial probe
/// sent alongside them reported `load=1ms prompt_eval=115ms eval=265ms` against
/// `total=102,913ms`. Under four tenths of a second of work inside a hundred and
/// two seconds of queueing. That is the "Grux is thinking" hang.
///
/// `OpenAICompatBackend` is an actor, which is why this was surprising, but
/// actors are RE-ENTRANT: the backend suspends at the `await` on the network
/// call and another request walks in. Actor isolation prevents data races, not
/// concurrent requests.
final class LocalModelGateTests: XCTestCase {

    /// The second caller must wait, not proceed.
    func testASecondCallerWaitsForTheFirst() async {
        let gate = LocalModelGate.shared
        await gate.acquire()
        let waiting = expectation(description: "second caller resumed")
        Task {
            await gate.acquire()
            waiting.fulfill()
            await gate.release()
        }
        // Give the second caller a real chance to wrongly proceed.
        try? await Task.sleep(nanoseconds: 200_000_000)
        let queued = await gate.waitingCount
        XCTAssertEqual(queued, 1, "the second caller did not queue, so calls still overlap")
        await gate.release()
        await fulfillment(of: [waiting], timeout: 2.0)
    }

    /// THE DEADLOCK GUARD. A throwing call must still free the slot, or one
    /// failure wedges every later local call forever. This is why the release
    /// sits in a `defer` at the call site.
    func testAThrownErrorStillFreesTheSlot() async {
        let gate = LocalModelGate.shared
        func failing() async throws {
            await gate.acquire()
            defer { Task { await gate.release() } }
            throw ClaudeError.http(500, "boom")
        }
        do { try await failing() } catch { /* expected */ }
        // Let the deferred release land.
        try? await Task.sleep(nanoseconds: 200_000_000)
        await gate.acquire()
        let queued = await gate.waitingCount
        XCTAssertEqual(queued, 0, "a failed call left the gate held, so local calls are wedged")
        await gate.release()
    }

    /// Serial, not lossy: every queued caller eventually runs exactly once.
    func testEveryQueuedCallerEventuallyRuns() async {
        let gate = LocalModelGate.shared
        let counter = Counter()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    await gate.acquire()
                    await counter.bump()
                    await gate.release()
                }
            }
        }
        let n = await counter.value
        XCTAssertEqual(n, 5, "a queued caller was dropped")
        let busy = await gate.isBusy
        XCTAssertFalse(busy, "the gate stayed held after everyone finished")
    }
}

private actor Counter {
    private(set) var value = 0
    func bump() { value += 1 }
}
