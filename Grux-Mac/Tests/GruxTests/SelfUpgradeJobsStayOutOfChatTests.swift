import XCTest
@testable import Grux
@testable import GruxAgentCore

// D53: a Self-Upgrade build that failed posted "UNPROCESSED FAILED SWARM -
// HANDLE THIS FIRST" into the person's chat as their own message, and Grux
// asked them whether to retry a job Foundry had already settled (thread
// 32DDC408, 6:51 PM Oct 29). Self-Upgrade's swarm jobs report on its pane only.
final class SelfUpgradeJobsStayOutOfChatTests: XCTestCase {

    func test_anEscalatedUpgradeIsMarkedAsSelfUpgrades() {
        let job = RDWorker.escalationJob(title: "t", prompt: "p", rootDir: "/tmp/wt")
        XCTAssertEqual(job.startedBy, .selfUpgrade)
    }

    func test_aSelfUpgradeJobNeverReportsToChat() {
        var job = RDWorker.escalationJob(title: "t", prompt: "p", rootDir: "/tmp/wt")
        for status in [AgentJob.Status.done, .failed, .cancelled] {
            job.status = status
            XCTAssertFalse(AgentService.reportsEndToChat(job), "\(status)")
        }
    }

    func test_aJobAPersonStartedStillReportsToChat() {
        let job = AgentService.plannedJob(title: "brief", goal: "g", template: .architectImplement, rootDir: "/tmp/x")
        XCTAssertNil(job.startedBy)
        XCTAssertTrue(AgentService.reportsEndToChat(job))
    }

    // A store written before the field existed decodes as a person's job, and
    // the mark survives a save and load.
    func test_theMarkIsStoredAndOldStoresDecode() throws {
        var job = AgentJob(title: "t", goal: "g", rootDir: "/tmp")
        let old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as! [String: Any]
        XCTAssertNil(old["startedBy"])
        XCTAssertNil(try JSONDecoder().decode(AgentJob.self, from: JSONSerialization.data(withJSONObject: old)).startedBy)
        job.startedBy = .selfUpgrade
        let back = try JSONDecoder().decode(AgentJob.self, from: JSONEncoder().encode(job))
        XCTAssertEqual(back.startedBy, .selfUpgrade)
    }
}
