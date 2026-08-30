import XCTest
@testable import GruxAgentCore

final class ResumeFlowTests: XCTestCase {

    // MARK: - State model round-trip

    func testAgentJobCodableRoundTripWithPausedReason() throws {
        let workers = SwarmPlanFactory.expand(template: .architectImplement, goal: "build it", rootDir: "/tmp")
        var job = AgentJob(
            title: "round-trip",
            goal: "g",
            workers: workers,
            rootDir: "/tmp"
        )
        job.status = .waiting
        job.pausedReason = .authLimitHit
        job.workers[0].status = .pausedForAuth
        job.workers[0].interruption = WorkerInterruption(
            kind: .authLimitHit,
            detectedAt: Date(timeIntervalSince1970: 1_777_142_000),
            claudeAccountId: "org-abc-123",
            resumePromptCheckpoint: "we were drafting the plan when..."
        )

        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(job)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let decoded = try dec.decode(AgentJob.self, from: data)

        XCTAssertEqual(decoded.status, .waiting)
        XCTAssertEqual(decoded.pausedReason, .authLimitHit)
        XCTAssertEqual(decoded.workers[0].status, .pausedForAuth)
        XCTAssertEqual(decoded.workers[0].interruption?.kind, .authLimitHit)
        XCTAssertEqual(decoded.workers[0].interruption?.claudeAccountId, "org-abc-123")
        XCTAssertEqual(decoded.workers[0].interruption?.resumePromptCheckpoint,
                       "we were drafting the plan when...")
    }

    // MARK: - Worker classification when result.interruption is set

    func testSwarmWorkerResultInterruptionPropagates() {
        let interruption = WorkerInterruption(kind: .authLimitHit, detectedAt: Date())
        let result = SwarmWorkerResult(
            workerId: "w1",
            success: false,
            finalText: "You've hit your org's monthly usage limit",
            costUSD: 5.6,
            durationSec: 600,
            exitCode: 1,
            errorMessage: "paused: hit Anthropic monthly usage limit",
            interruption: interruption
        )
        XCTAssertEqual(result.interruption?.kind, .authLimitHit)
        XCTAssertFalse(result.success)
    }

    // MARK: - Pause + resume against the orchestrator
    //
    // Drives applyResumeMutations() directly, that's the half of resumeJob
    // that mutates state without triggering run()'s subprocess spawn. The
    // run-loop side is e2e-tested by the SwarmDemo harness against a real
    // claude binary; here we just verify the state machine.

    func testApplyResumeMutationsMovesPausedWorkersBackToQueued() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("resume-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = AgentStore(rootDir: tmp)

        let archWorker = SwarmWorkerSpec(
            id: "arch-1",
            role: .architect,
            label: "architect",
            goal: "draft the plan",
            cwd: NSTemporaryDirectory(),
            model: "claude-sonnet-4-6",
            budgetUSD: 0.5,
            status: .pausedForAuth,
            interruption: WorkerInterruption(kind: .authLimitHit, detectedAt: Date())
        )
        let writerWorker = SwarmWorkerSpec(
            id: "writer-1",
            role: .implementor,
            label: "writer",
            goal: "write it",
            cwd: NSTemporaryDirectory(),
            dependsOn: ["arch-1"],
            model: "claude-sonnet-4-6",
            budgetUSD: 0.5,
            status: .queued
        )
        var job = AgentJob(
            title: "resume-test",
            goal: "test",
            status: .waiting,
            workers: [archWorker, writerWorker],
            rootDir: NSTemporaryDirectory(),
            pausedReason: .authLimitHit
        )
        job.workers[0].errorMessage = "paused: hit Anthropic monthly usage limit"

        try await store.saveJob(job)

        let orch = SwarmOrchestrator(job: job, store: store, observer: nil)
        let mutated = await orch.applyResumeMutations()
        XCTAssertTrue(mutated, "applyResumeMutations should return true when paused workers exist")

        // After resume, the persisted state should show:
        //   - paused worker → queued (interruption cleared)
        //   - pausedReason → nil
        let after = await store.loadJob(job.id)
        XCTAssertNotNil(after)
        XCTAssertNil(after?.pausedReason, "pausedReason should be cleared on resume")
        let archAfter = after?.workers.first(where: { $0.id == "arch-1" })
        XCTAssertEqual(archAfter?.status, .queued, "paused worker should be back in queued")
        XCTAssertNil(archAfter?.interruption, "interruption should be cleared")
        XCTAssertNil(archAfter?.errorMessage, "stale error message should be cleared")
        // The writer worker (queued, never paused) should be untouched.
        let writerAfter = after?.workers.first(where: { $0.id == "writer-1" })
        XCTAssertEqual(writerAfter?.status, .queued)
    }

    func testApplyResumeMutationsNoOpWhenNoPausedWorkers() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("noop-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = AgentStore(rootDir: tmp)

        let workers = SwarmPlanFactory.expand(template: .singleWorker, goal: "g", rootDir: NSTemporaryDirectory())
        let job = AgentJob(
            title: "noop",
            goal: "g",
            workers: workers,
            rootDir: NSTemporaryDirectory()
        )
        try await store.saveJob(job)

        let orch = SwarmOrchestrator(job: job, store: store, observer: nil)
        let mutated = await orch.applyResumeMutations()
        XCTAssertFalse(mutated,
                       "applyResumeMutations should return false when no workers are pausedForAuth")
    }

    func testPrepareForResumeStampsInterruptedMarker() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("prepresume-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = AgentStore(rootDir: tmp)

        let arch = SwarmWorkerSpec(
            id: "arch-2",
            role: .architect,
            label: "architect",
            goal: "g",
            cwd: NSTemporaryDirectory(),
            status: .pausedForAuth
        )
        let job = AgentJob(
            title: "prep-test",
            goal: "g",
            status: .waiting,
            workers: [arch],
            rootDir: NSTemporaryDirectory(),
            pausedReason: .authLimitHit
        )
        try await store.saveJob(job)

        let orch = SwarmOrchestrator(job: job, store: store, observer: nil)
        await orch.prepareForResume(workerId: "arch-2")

        let interruptedDir = await store.jobDir(job.id)
            .appendingPathComponent("workers", isDirectory: true)
            .appendingPathComponent("arch-2", isDirectory: true)
            .appendingPathComponent(".interrupted", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: interruptedDir.path),
                      ".interrupted/ marker dir should exist after prepareForResume")
    }

    // MARK: - Resume-on-this-account transition (no account switch)
    //
    // The "Resume on this account" menu action drives
    // AgentService.resumeOnCurrentAccount, which calls orch.resumeJob() with NO
    // logout/OAuth swap. The state half of that path is applyResumeMutations:
    // it must leave the job in a run-eligible (.queued) status so run()'s entry
    // can flip it straight to .running. This is the transition the missing
    // button now wires up: paused -> running, same account.

    func testResumeInPlaceLeavesJobRunEligibleWithoutAccountSwitch() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("resume-here-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = AgentStore(rootDir: tmp)

        let worker = SwarmWorkerSpec(
            id: "solo-1",
            role: .architect,
            label: "solo",
            goal: "do the thing",
            cwd: NSTemporaryDirectory(),
            model: "claude-sonnet-4-6",
            budgetUSD: 0.5,
            status: .pausedForAuth,
            interruption: WorkerInterruption(kind: .authLimitHit, detectedAt: Date())
        )
        var job = AgentJob(
            title: "resume-here",
            goal: "g",
            status: .waiting,
            workers: [worker],
            rootDir: NSTemporaryDirectory(),
            pausedReason: .authLimitHit
        )
        job.workers[0].errorMessage = "paused: hit Anthropic monthly usage limit"
        try await store.saveJob(job)

        let orch = SwarmOrchestrator(job: job, store: store, observer: nil)
        let mutated = await orch.applyResumeMutations()
        XCTAssertTrue(mutated)

        // In-memory job (the instance run() will drive) is now run-eligible on
        // the SAME account: status .queued, paused worker re-queued, paused
        // reason cleared. No AccountSwitcher.switchToAccount was involved.
        let after = await orch.job
        XCTAssertEqual(after.status, .queued,
                       "resume-in-place should leave the job run-eligible (.queued) so run() flips it to .running")
        XCTAssertNil(after.pausedReason)
        XCTAssertEqual(after.workers[0].status, .queued)
        XCTAssertNil(after.workers[0].interruption)
        XCTAssertNil(after.workers[0].errorMessage)
    }

    // The menu action's failure branch: resumeOnCurrentAccount returns false
    // (and the sheet keeps the menu open with a "nothing to resume" message)
    // when the job has no paused workers. applyResumeMutations is the gate
    // that decision rides on, it must report false so the action is a no-op.

    func testResumeInPlaceIsNoOpWhenJobHasNoPausedWorkers() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("resume-here-noop-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = AgentStore(rootDir: tmp)

        let workers = SwarmPlanFactory.expand(template: .singleWorker, goal: "g", rootDir: NSTemporaryDirectory())
        var job = AgentJob(title: "noop-here", goal: "g", workers: workers, rootDir: NSTemporaryDirectory())
        // Mark the job done so a spurious re-entry would be observable as a
        // status regression. applyResumeMutations must NOT touch it.
        job.status = .done
        try await store.saveJob(job)

        let orch = SwarmOrchestrator(job: job, store: store, observer: nil)
        let mutated = await orch.applyResumeMutations()
        XCTAssertFalse(mutated,
                       "resume-in-place must be a no-op (false) when nothing is pausedForAuth, so the menu reports 'nothing to resume'")
        // resumeJob() guards on the same predicate, so it cannot spuriously
        // re-queue a terminal job and re-enter the run loop.
        let after = await orch.job
        XCTAssertEqual(after.status, .done,
                       "a job with no paused workers must be left untouched by resume-in-place")
    }

    // MARK: - Worker isTerminal honors pausedForAuth

    func testPausedForAuthIsNotTerminal() {
        var spec = SwarmPlanFactory.expand(template: .singleWorker, goal: "g", rootDir: "/tmp")[0]
        spec.status = .pausedForAuth
        XCTAssertFalse(spec.isTerminal,
                       "pausedForAuth must be non-terminal so the orchestrator's run loop blocks on it instead of failing")
    }
}
