import XCTest
@testable import Grux

/// HOW MANY SESSIONS RUN AT ONCE, AND WHO DECIDES.
///
/// Measured 2026-08-23: nobody decided, and there was no ceiling at all.
/// `AgentTools` read the count straight off the tool-call arguments,
/// `let maxPar = (input["max_parallel"] as? Int) ?? 3`, with no clamp, and
/// passed it into the swarm. So the number of concurrent agent sessions was
/// chosen by the MODEL, per call, unbounded. A prompt asking for fifty workers
/// would have got fifty.
///
/// That matters more than it looks. Concurrency is the single behaviour most
/// likely to push a subscription into its rate limits, and onboarding now tells
/// users exactly that. Telling somebody to keep the count low while the count is
/// out of their hands is not advice, it is decoration.
///
/// The clamp lives on `AgentService.startSwarm` because that is the one choke
/// point every caller already goes through: RDWorker asks for 1,
/// GoalPursuitEngine for 3, CommandV2AgentBridge for up to 4, and AgentTools for
/// whatever the model said. Clamping at each call site would mean four places to
/// forget.
final class SessionConcurrencyTests: XCTestCase {

    private var original: Int?

    override func setUp() {
        super.setUp()
        original = UserDefaults.standard.object(forKey: SessionConcurrency.defaultsKey) as? Int
    }

    override func tearDown() {
        if let original {
            UserDefaults.standard.set(original, forKey: SessionConcurrency.defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: SessionConcurrency.defaultsKey)
        }
        super.tearDown()
    }

    /// The default has to be conservative. A user who never opens Settings is
    /// the one most likely to be surprised by a rate limit.
    func testTheDefaultCeilingIsLow() {
        UserDefaults.standard.removeObject(forKey: SessionConcurrency.defaultsKey)
        XCTAssertEqual(SessionConcurrency.ceiling, SessionConcurrency.fallback)
        XCTAssertLessThanOrEqual(SessionConcurrency.fallback, 3,
                                 "the out-of-box ceiling is not conservative")
        XCTAssertGreaterThanOrEqual(SessionConcurrency.fallback, 1,
                                    "a ceiling below one would disable sessions entirely")
    }

    /// THE ACTUAL BUG. An absurd model-supplied count must not survive.
    func testAnUnboundedRequestIsClamped() {
        UserDefaults.standard.set(2, forKey: SessionConcurrency.defaultsKey)
        XCTAssertEqual(SessionConcurrency.clamp(50), 2, "a request for fifty workers was honoured")
        XCTAssertEqual(SessionConcurrency.clamp(3), 2)
        XCTAssertEqual(SessionConcurrency.clamp(2), 2, "a request at the ceiling is allowed through")
        XCTAssertEqual(SessionConcurrency.clamp(1), 1, "a smaller request is left alone, not raised")
    }

    /// Nonsense must not disable the feature or divide by zero downstream.
    func testNonsenseRequestsFloorAtOne() {
        UserDefaults.standard.set(4, forKey: SessionConcurrency.defaultsKey)
        XCTAssertEqual(SessionConcurrency.clamp(0), 1)
        XCTAssertEqual(SessionConcurrency.clamp(-7), 1)
    }

    /// The user's own setting is itself bounded. A stored 999, whether typed,
    /// migrated or corrupted, must not reintroduce the unbounded case.
    func testTheStoredCeilingIsItselfBounded() {
        UserDefaults.standard.set(999, forKey: SessionConcurrency.defaultsKey)
        XCTAssertEqual(SessionConcurrency.ceiling, SessionConcurrency.hardCeiling)
        XCTAssertEqual(SessionConcurrency.clamp(999), SessionConcurrency.hardCeiling)

        UserDefaults.standard.set(0, forKey: SessionConcurrency.defaultsKey)
        XCTAssertEqual(SessionConcurrency.ceiling, 1, "a stored zero would switch sessions off silently")
    }

    /// And the choke point actually applies it. Asserting the helper alone would
    /// leave the real path free to ignore it, which is the shape of the original
    /// defect: a correct rule nothing called. `plannedJob` is the part of
    /// `startSwarm` that builds the job; calling `startSwarm` itself from a test
    /// started a real swarm in the operator's real store on every run (284 of
    /// them by 2026-09-20) and made the running app announce each failure aloud.
    func testStartSwarmAppliesTheClamp() {
        UserDefaults.standard.set(2, forKey: SessionConcurrency.defaultsKey)
        let dir = NSTemporaryDirectory() + "grux-concurrency-test"
        let job = AgentService.plannedJob(
            goal: "concurrency clamp probe, no worker is started by this call",
            rootDir: dir,
            maxParallelWorkers: 50)
        XCTAssertEqual(job.maxParallelWorkers, 2,
                       "startSwarm stored the unclamped request, so the ceiling is advisory only")
    }

    /// The suite must never start a swarm through the shared service: that is
    /// how the probe jobs and the spoken failures got in.
    func testNoTestStartsARealSwarm() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        var offenders: [String] = []
        for f in files {
            let src = try String(contentsOf: f, encoding: .utf8)
            // Split so this file does not match its own search string.
            if src.contains("AgentService.shared" + ".startSwarm(") { offenders.append(f.lastPathComponent) }
        }
        XCTAssertEqual(offenders, [], "these tests start a real swarm in the operator's store: \(offenders)")
    }
}
