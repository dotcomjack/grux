import XCTest
import GruxAgentCore
@testable import Grux

/// D208 item 2: a job's detail drew the job id "5D6C3AAB" beside its cost and a worker
/// card reading "solo" over "generic" (the plan's internal label and role), so a stranger
/// read code words where the pane should say who did the work. The card and the log say
/// it in plain words, and the id stays out of sight (it is still in the job's copy-out).
final class AgentsWorkerWordsTests: XCTestCase {
    private func worker(_ role: SwarmWorkerSpec.Role, _ label: String) -> SwarmWorkerSpec {
        SwarmWorkerSpec(role: role, label: label, goal: "g", cwd: "/tmp")
    }

    func test_aOneWorkerJobNamesItsAgentNotSolo() {
        let w = worker(.generic, "solo")
        XCTAssertEqual(JobDetailView.workerName(w), "Agent")
        XCTAssertNil(JobDetailView.workerRoleLine(w.role), "generic adds nothing a person can use")
    }

    func test_everyTemplateWorkerReadsInPlainWords() {
        for template in [SwarmTemplate.singleWorker, .architectImplement, .parallelTrio, .critiqueLoop, .iosAppFull] {
            for w in SwarmPlanFactory.expand(template: template, goal: "Make a thing", rootDir: "/tmp/x") {
                let name = JobDetailView.workerName(w)
                XCTAssertFalse(name.contains("-") || name.contains("_"), "\(template) \(w.label) draws \(name)")
                XCTAssertEqual(name.first.map { String($0) }, name.first.map { String($0).uppercased() },
                               "\(template) \(w.label) draws \(name)")
                XCTAssertNotEqual(name.lowercased(), "solo")
                if let line = JobDetailView.workerRoleLine(w.role) {
                    XCTAssertFalse(line.lowercased().contains(w.role.rawValue.lowercased()),
                                   "\(w.role) caption repeats the code word: \(line)")
                }
            }
        }
    }

    func test_labelsReadAsWords() {
        XCTAssertEqual(JobDetailView.workerName(worker(.implementor, "worker-2")), "Worker 2")
        XCTAssertEqual(JobDetailView.workerName(worker(.buildLoop, "build-loop")), "Build loop")
        XCTAssertEqual(JobDetailView.workerName(worker(.qa, "qa")), "Tester")
        XCTAssertEqual(JobDetailView.workerName(worker(.implementor, "feature_chat")), "Feature chat")
        XCTAssertEqual(JobDetailView.workerName(worker(.architect, "architect")), "Architect")
        // An empty label still names someone.
        XCTAssertEqual(JobDetailView.workerName(worker(.generic, "  ")), "Agent")
    }

    func test_everyRoleButGenericSaysWhatItDoes() {
        let roles: [SwarmWorkerSpec.Role] = [.architect, .implementor, .integrator, .buildLoop, .qa, .brand]
        for role in roles {
            let line = JobDetailView.workerRoleLine(role)
            XCTAssertNotNil(line, "\(role)")
            XCTAssertNotEqual(line, role.rawValue)
        }
    }

    /// The detail pane draws the helpers, not the raw label, role or id.
    func test_theDetailPaneDrawsThePlainWords() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/AgentsView.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        let detail = try XCTUnwrap(src.range(of: "struct JobDetailView"))
        let body = String(src[detail.lowerBound...])
        XCTAssertFalse(body.contains("Text(job.id"), "the job id is drawn in the detail header")
        XCTAssertFalse(body.contains("Text(w.label)"), "a worker's raw label is drawn")
        XCTAssertFalse(body.contains("Text(w.role.rawValue)"), "a worker's raw role is drawn")
    }
}
