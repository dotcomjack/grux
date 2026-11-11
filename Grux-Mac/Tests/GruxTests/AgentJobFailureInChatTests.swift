import XCTest
import GruxAgentCore
@testable import Grux

/// A job a person started that failed is told in chat by Grux itself, in
/// plain words. It used to be handed to the model as the person's own turn:
/// a YOU bubble "UNPROCESSED FAILED SWARM - HANDLE THIS FIRST ... workers
/// failed: solo (Failed to authenticate: OAuth ...)", which the model turned
/// into "The swarm failed because the solo worker's OAuth session expired"
/// with no word about signing in (sense pass 5, job 40F07319, D71).
final class AgentJobFailureInChatTests: XCTestCase {

    private func failed(_ error: String?) -> AgentJob {
        AgentJob(title: "Reply with the single word hi", goal: "g", status: .failed,
                 rootDir: "/tmp", errorMessage: error)
    }

    private let jargon = ["UNPROCESSED", "swarm", "Swarm", "OAuth", "worker", "solo", "status=", "REQUIRED ACTION", "\u{2014}", "\u{2013}"]

    private func line(_ job: AgentJob, file: StaticString = #filePath, line: UInt = #line) -> String? {
        guard case .assistantLine(let text) = AgentService.failureReport(for: job) else {
            XCTFail("a failed job went to the model as the person's turn", file: file, line: line)
            return nil
        }
        return text
    }

    func test_anExpiredSignInSaysSignInAgainInPlainWords() throws {
        let job = failed("workers failed: solo (Failed to authenticate: OAuth session expired and could not be refreshed)")
        let text = try XCTUnwrap(line(job))
        XCTAssertTrue(text.contains("Reply with the single word hi"), text)
        XCTAssertTrue(text.contains("Claude's sign-in on this Mac has expired"), text)
        XCTAssertTrue(text.contains("Sign in (Claude sign-in, at the top of Now)"), text)
        for word in jargon { XCTAssertFalse(text.contains(word), "\(word) in: \(text)") }
    }

    /// Wave 17 review: the job's message is the swarm's summary ("workers
    /// failed: architect (...)", cut per worker), so a sign-in failure worded
    /// "Failed to authenticate. API Error: 401 ..." never matched the summary,
    /// while the worker's own verdict, which drives Agents and Now, said
    /// sign-in. Chat reads that same verdict.
    func test_aWorkerThatStoppedOnTheSignInSaysSignInAgainWhateverTheSummarySays() throws {
        var worker = SwarmWorkerSpec(role: .generic, label: "architect", goal: "g", cwd: "/tmp",
                                     model: "m", budgetUSD: 1)
        worker.status = .failed
        worker.interruption = WorkerInterruption(kind: .signInExpired)
        let job = AgentJob(title: "Reply with the single word hi", goal: "g", status: .failed,
                           workers: [worker], rootDir: "/tmp",
                           errorMessage: "workers failed: architect (Failed to authenticate. API Error: 401 {\"type\":\"error\",\"error\":{\"type\":\"authentication_error\",\"message\":\"Invalid bearer token\"}})")
        XCTAssertTrue(job.failedOnSignIn)
        let text = try XCTUnwrap(line(job))
        XCTAssertTrue(text.contains("Claude's sign-in on this Mac has expired"), text)
        XCTAssertTrue(text.contains("Sign in (Claude sign-in, at the top of Now)"), text)
    }

    func test_anyOtherFailureNamesTheJobAndTheWayOn() throws {
        for error in ["workers failed: solo (exit 1)", "", nil] as [String?] {
            let text = try XCTUnwrap(line(failed(error)))
            XCTAssertTrue(text.contains("Reply with the single word hi"), text)
            XCTAssertTrue(text.contains("Agents"), "no way to see why: \(text)")
            XCTAssertFalse(text.contains("sign-in"), "a failure that is not the sign-in blamed it: \(text)")
            for word in jargon { XCTAssertFalse(text.contains(word), "\(word) in: \(text)") }
        }
    }
}
