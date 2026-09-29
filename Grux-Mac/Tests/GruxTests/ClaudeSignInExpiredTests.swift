import XCTest
@testable import Grux
@testable import GruxAgentCore

// Operator ruling 0k (ledger A16c): an agent run that fails on an expired
// Claude sign-in shows a Now row and a line on the failed job, "Claude sign-in
// expired", with one button that starts the existing AccountSwitcher sign-in.
// Measured live 2026-09-27: the run only "had trouble" with the CLI's words,
// and nothing told the person to sign in again.
@MainActor
final class ClaudeSignInExpiredTests: XCTestCase {

    private static let expiredText = "Failed to authenticate: OAuth session expired and could not be refreshed"

    private static func lines(result: String, isError: Bool) -> [String] {
        [
            #"{"type":"system","subtype":"init","session_id":"s-auth","model":"claude-sonnet-4-6"}"#,
            #"{"type":"assistant","message":{"model":"<synthetic>","role":"assistant","content":[{"type":"text","text":"\#(result)"}]}}"#,
            #"{"type":"result","subtype":"success","is_error":\#(isError),"duration_ms":12,"result":"\#(result)","total_cost_usd":0}"#
        ]
    }

    private var savedReport: (@Sendable (Bool) -> Void)!

    override func setUp() async throws {
        savedReport = SignInExpiry.report
        let box = ReportBox()
        reportBox = box
        SignInExpiry.report = { box.append($0) }
    }

    override func tearDown() async throws {
        SignInExpiry.report = savedReport
    }

    private var reportBox = ReportBox()

    final class ReportBox: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Bool] = []
        func append(_ v: Bool) { lock.lock(); values.append(v); lock.unlock() }
        var all: [Bool] { lock.lock(); defer { lock.unlock() }; return values }
    }

    // MARK: Detection

    func test_detect_theCLIsExpiredSignInWords() {
        XCTAssertTrue(SignInExpiry.detect(Self.expiredText))
        XCTAssertTrue(SignInExpiry.detect("OAuth token has expired. Please obtain a new token or refresh your existing token."))
        XCTAssertTrue(SignInExpiry.detect("Invalid API key · Please run /login"))
        XCTAssertTrue(SignInExpiry.detect("Not logged in · Please run /login"))
    }

    func test_detect_isNotTheMonthlyLimitOrAnyOtherFailure() {
        XCTAssertFalse(SignInExpiry.detect("You've hit your org's monthly usage limit"))
        XCTAssertFalse(SignInExpiry.detect("exit 1"))
        XCTAssertFalse(SignInExpiry.detect("The build failed: xcodebuild exited 65"))
        XCTAssertFalse(SignInExpiry.detect(""))
    }

    // MARK: The worker

    private func runFakeWorker(result: String, isError: Bool, exitCode: Int32) async throws -> SwarmWorkerResult {
        let dir = try makeFakeClaude(result: result, isError: isError, exitCode: exitCode)
        defer { try? FileManager.default.removeItem(at: dir) }
        let previous = ProcessInfo.processInfo.environment["CLAUDE_BIN"]
        setenv("CLAUDE_BIN", dir.appendingPathComponent("claude").path, 1)
        defer {
            if let previous { setenv("CLAUDE_BIN", previous, 1) } else { unsetenv("CLAUDE_BIN") }
        }
        let spec = SwarmWorkerSpec(role: .generic, label: "sign-in", goal: "say hi",
                                   cwd: dir.path, model: "claude-sonnet-4-6", budgetUSD: 1.0)
        return await SwarmWorker(spec: spec, observer: nil).run(scaffold: "", ttlSeconds: 60)
    }

    private func makeFakeClaude(result: String, isError: Bool, exitCode: Int32) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sign-in-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fake = dir.appendingPathComponent("claude")
        let body = Self.lines(result: result, isError: isError)
            .map { "printf '%s\\n' '\($0)'" }.joined(separator: "\n")
        try "#!/bin/sh\ncat >/dev/null\n\(body)\nexit \(exitCode)\n"
            .write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        return dir
    }

    func test_worker_expiredSignIn_failsWithItsOwnKindAndReportsIt() async throws {
        let r = try await runFakeWorker(result: Self.expiredText, isError: true, exitCode: 1)
        XCTAssertFalse(r.success)
        XCTAssertEqual(r.interruption?.kind, .signInExpired)
        XCTAssertEqual(r.errorMessage, Self.expiredText, "the CLI's own words stay on the worker")
        XCTAssertEqual(reportBox.all, [true])
    }

    func test_worker_successReportsTheSignInWorks() async throws {
        let r = try await runFakeWorker(result: "hi", isError: false, exitCode: 0)
        XCTAssertTrue(r.success)
        XCTAssertNil(r.interruption)
        XCTAssertEqual(reportBox.all, [false])
    }

    func test_worker_otherFailure_isNotASignIn() async throws {
        let r = try await runFakeWorker(result: "The build failed: xcodebuild exited 65", isError: true, exitCode: 1)
        XCTAssertFalse(r.success)
        XCTAssertNil(r.interruption)
        XCTAssertEqual(reportBox.all, [], "a failure that says nothing about the sign-in reports nothing")
    }

    func test_bridgeRunner_expiredSignInReportsIt() async throws {
        let dir = try makeFakeClaude(result: Self.expiredText, isError: true, exitCode: 1)
        defer { try? FileManager.default.removeItem(at: dir) }
        let invocation = AdapterInvocation(executablePath: dir.appendingPathComponent("claude").path,
                                           args: [], env: ["PATH": "/usr/bin:/bin"],
                                           stdinPayload: "say hi\n", cwd: dir.path)
        let r = await AgentBridgeRunner(adapter: ClaudeCodeAdapter(), invocation: invocation, observer: nil)
            .run(ttlSeconds: 60)
        XCTAssertFalse(r.success)
        XCTAssertEqual(reportBox.all, [true])
    }

    // MARK: The failed job

    func test_orchestrator_failedJobKnowsItWasTheSignIn() async throws {
        let dir = try makeFakeClaude(result: Self.expiredText, isError: true, exitCode: 1)
        defer { try? FileManager.default.removeItem(at: dir) }
        let previous = ProcessInfo.processInfo.environment["CLAUDE_BIN"]
        setenv("CLAUDE_BIN", dir.appendingPathComponent("claude").path, 1)
        defer {
            if let previous { setenv("CLAUDE_BIN", previous, 1) } else { unsetenv("CLAUDE_BIN") }
        }
        let spec = SwarmWorkerSpec(role: .generic, label: "w1", goal: "say hi",
                                   cwd: dir.path, model: "claude-sonnet-4-6", budgetUSD: 1.0)
        let job = AgentJob(title: "Sign-in job", goal: "say hi", workers: [spec], rootDir: dir.path)
        let store = AgentStore(rootDir: dir.appendingPathComponent("store", isDirectory: true))
        let orch = SwarmOrchestrator(job: job, store: store)
        await orch.run()
        let after = await orch.job
        XCTAssertEqual(after.status, .failed)
        XCTAssertNotEqual(after.pausedReason, .authLimitHit, "never the monthly-limit pause")
        XCTAssertEqual(after.workers.first?.interruption?.kind, .signInExpired)
        XCTAssertTrue(after.failedOnSignIn)
    }

    func test_failedOnSignIn_onlyForAFailedJob() {
        var w = SwarmWorkerSpec(role: .generic, label: "w", goal: "g", cwd: "/tmp",
                                model: "m", budgetUSD: 1)
        w.status = .failed
        w.interruption = WorkerInterruption(kind: .signInExpired)
        var job = AgentJob(title: "t", goal: "g", status: .failed, workers: [w], rootDir: "/tmp")
        XCTAssertTrue(job.failedOnSignIn)
        job.status = .running
        XCTAssertFalse(job.failedOnSignIn)
        job.status = .failed
        job.workers[0].interruption = nil
        XCTAssertFalse(job.failedOnSignIn)
    }

    // MARK: The app state and Now

    func test_state_followsTheLastVerdict() {
        let s = ClaudeSignInState()
        s.record(expired: true)
        XCTAssertTrue(s.expired)
        s.record(expired: false)
        XCTAssertFalse(s.expired)
    }

    func test_startSignIn_runsTheExistingFlowAndClearsOnSuccess() async {
        let s = ClaudeSignInState()
        s.record(expired: true)
        let done = expectation(description: "sign-in flow ran")
        s.startSignIn(using: { done.fulfill(); return true })
        await fulfillment(of: [done], timeout: 2)
        for _ in 0..<50 where s.expired { await Task.yield() }
        XCTAssertFalse(s.expired, "a sign-in that landed clears the row")
    }

    // MARK: Clearing it needs a call that works (RV16)

    /// A fake CLI whose `auth status` says logged in, as the stale credentials
    /// of an expired sign-in do, and whose real call answers `callResult`.
    private func withFakeCLI(callResult: String, callExit: Int32, _ body: () async throws -> Void) async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sign-in-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appendingPathComponent("claude")
        let status = #"{"loggedIn":true,"authMethod":"claude.ai","email":"a@example.com","subscriptionType":"max"}"#
        try """
        #!/bin/sh
        if [ "$1" = "auth" ]; then printf '%s\\n' '\(status)'; exit 0; fi
        printf '%s\\n' '\(callResult)'
        exit \(callExit)

        """.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let previous = ProcessInfo.processInfo.environment["CLAUDE_BIN"]
        setenv("CLAUDE_BIN", fake.path, 1)
        defer {
            if let previous { setenv("CLAUDE_BIN", previous, 1) } else { unsetenv("CLAUDE_BIN") }
        }
        try await body()
    }

    private static let expiredResult =
        #"{"type":"result","subtype":"success","is_error":true,"result":"\#(expiredText)"}"#
    private static let workingResult =
        #"{"type":"result","subtype":"success","is_error":false,"result":"OK"}"#

    /// Status says logged in, the real call fails on the sign-in: the row stays.
    func test_signIn_loggedInStatusWithAFailingCall_doesNotClear() async throws {
        try await withFakeCLI(callResult: Self.expiredResult, callExit: 1) {
            let works = await AccountSwitcher.authenticatedCallGoesThrough()
            XCTAssertFalse(works, "an expired sign-in's call counted as working")
            let s = ClaudeSignInState()
            s.record(expired: true)
            let done = expectation(description: "sign-in wait ended")
            s.startSignIn(using: {
                let ok = await AccountSwitcher.waitForWorkingSignIn(
                    timeoutSec: 0.3, pollSeconds: 0.05, probeEvery: 0,
                    loggedIn: { true },
                    callGoesThrough: { await AccountSwitcher.authenticatedCallGoesThrough() })
                done.fulfill()
                return ok
            })
            await fulfillment(of: [done], timeout: 10)
            for _ in 0..<50 { await Task.yield() }
            XCTAssertTrue(s.expired, "a logged-in status alone cleared 'Claude sign-in expired'")
        }
    }

    /// Exit 0 is not enough either: the CLI can exit clean with an error result.
    func test_signIn_anErrorResultWithACleanExit_doesNotCount() async throws {
        try await withFakeCLI(callResult: Self.expiredResult, callExit: 0) {
            let works = await AccountSwitcher.authenticatedCallGoesThrough()
            XCTAssertFalse(works)
        }
    }

    /// A call that works clears it.
    func test_signIn_aWorkingCall_clears() async throws {
        try await withFakeCLI(callResult: Self.workingResult, callExit: 0) {
            let works = await AccountSwitcher.authenticatedCallGoesThrough()
            XCTAssertTrue(works, "control: a working call did not count")
            let s = ClaudeSignInState()
            s.record(expired: true)
            let done = expectation(description: "sign-in wait ended")
            s.startSignIn(using: {
                let ok = await AccountSwitcher.waitForWorkingSignIn(
                    timeoutSec: 5, pollSeconds: 0.05, probeEvery: 0,
                    loggedIn: { true },
                    callGoesThrough: { await AccountSwitcher.authenticatedCallGoesThrough() })
                done.fulfill()
                return ok
            })
            await fulfillment(of: [done], timeout: 10)
            for _ in 0..<50 where s.expired { await Task.yield() }
            XCTAssertFalse(s.expired)
        }
    }

    /// Nothing is called while the CLI still says signed out.
    func test_signIn_noCallWhileSignedOut() async {
        var calls = 0
        let ok = await AccountSwitcher.waitForWorkingSignIn(
            timeoutSec: 0.2, pollSeconds: 0.05, probeEvery: 0,
            loggedIn: { false }, callGoesThrough: { calls += 1; return true })
        XCTAssertFalse(ok)
        XCTAssertEqual(calls, 0)
    }

    func test_now_showsOneNeedsYouRowThatSignsIn() {
        var s = RelevanceState()
        s.jobsRunning = [RunningJob(id: "j1", title: "Job")]
        XCTAssertFalse(Relevance.now(s).contains { $0.action == .claudeSignIn })
        s.claudeSignInExpired = true
        let rows = Relevance.now(s).filter { $0.action == .claudeSignIn }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.title, "Claude sign-in expired")
        XCTAssertEqual(rows.first?.cls, .needsYou)
        XCTAssertEqual(Relevance.now(s).first?.action, .claudeSignIn, "it outranks the running job")
    }

    func test_liveState_readsTheSignInState() {
        ClaudeSignInState.shared.record(expired: true)
        defer { ClaudeSignInState.shared.record(expired: false) }
        XCTAssertTrue(RelevanceState.live(now: Date(), slow: .init()).claudeSignInExpired)
    }

    func test_panelAction_startsTheSignIn() {
        var calls = 0
        let m = PanelModel(stateProvider: { RelevanceState() }, signIn: { calls += 1 })
        m.perform(.claudeSignIn)
        XCTAssertEqual(calls, 1)
    }

    // MARK: The scheduled agent's notice

    func test_scheduleNotice_namesTheExpiredSignIn() {
        var r = CommandV2AgentBridge.AgentResult(text: Self.expiredText, success: false, costUSD: 0,
                                                 durationSec: 1, workerCount: 1, pausedForAuth: false)
        r.signInExpired = true
        let n = UserCronScheduler.agentNotice(title: "Nightly", result: r)
        XCTAssertEqual(n.title, "Schedule had trouble: Nightly")
        XCTAssertEqual(n.body, "Claude sign-in expired. Open Grux to sign in again.")
    }

    func test_scheduleNotice_otherwiseUnchanged() {
        let r = CommandV2AgentBridge.AgentResult(text: "all good", success: true, costUSD: 0,
                                                 durationSec: 1, workerCount: 1, pausedForAuth: false)
        let n = UserCronScheduler.agentNotice(title: "Nightly", result: r)
        XCTAssertEqual(n.title, "Schedule done: Nightly")
        XCTAssertEqual(n.body, "all good")
    }
}
