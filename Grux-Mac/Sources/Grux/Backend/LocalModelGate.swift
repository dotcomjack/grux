import Foundation

/// Serialises calls to a local model server.
///
/// WHY THIS IS NEEDED EVEN THOUGH THE BACKEND IS AN ACTOR. Actors are
/// re-entrant: `OpenAICompatBackend` suspends at the `await` on the network
/// call, and while it is suspended another call enters the same actor. Actor
/// isolation prevents data races, not concurrent requests, and this is the
/// difference between those two guarantees showing up as a real bug.
///
/// MEASURED 2026-08-23 on the owner's machine, with the shipped default local
/// model qwen3:8b loaded in 9.8GB of VRAM. `lsof` showed SIX established
/// connections from Grux to port 11434 at once, and Ollama's own log showed a
/// single prompt still at `progress = 0.47` after 7,680 tokens, so roughly a
/// 16,000 token prompt. A trivial probe sent alongside them reported
/// `load=1ms prompt_eval=115ms eval=265ms` and `total=102,913ms`: under four
/// tenths of a second of work inside a hundred and two seconds of waiting.
///
/// That is the whole "Grux is thinking" hang and the heat with it. One 8B model
/// on one GPU cannot serve six prompts in parallel, so queueing them inside the
/// app rather than inside the server changes nothing about throughput and
/// everything about whether the machine stays responsive.
///
/// One at a time is the honest default here. There is exactly one GPU.
actor LocalModelGate {

    static let shared = LocalModelGate()

    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private init() {}

    func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            waiters.append(c)
        }
    }

    /// Hands the slot straight to the next waiter rather than clearing `busy`,
    /// so a third caller arriving in between cannot jump the queue.
    func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    /// Depth of the queue, for tests and diagnostics.
    var waitingCount: Int { waiters.count }

    var isBusy: Bool { busy }
}
