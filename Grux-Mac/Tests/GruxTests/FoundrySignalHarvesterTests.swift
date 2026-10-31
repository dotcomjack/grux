import XCTest
import GruxAgentCore
@testable import Grux

// Foundry Stage 1 (Sense) tests. Every test runs against canned fixtures in
// temp dirs: no network, no app launch, no real Application Support reads.
final class FoundrySignalHarvesterTests: XCTestCase {

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grux-foundry-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - TranscriptSignalSource

    private func thread(messages: [(ChatRole, String)], title: String = "Fixture thread") -> ChatThread {
        ChatThread(
            title: title,
            messages: messages.map { ChatMessage(role: $0.0, content: $0.1) }
        )
    }

    func testTranscriptCorrectionDetectedWithinTwoTurns() {
        let t = thread(messages: [
            (.user, "What's the bar soap price?"),
            (.assistant, "The bar soap is $15."),
            (.user, "no, the bar soap two-pack is $13"),
            (.assistant, "Right, $13 for the 2-pack."),
            (.user, "you forgot the subscription discount again")
        ])
        let signal = TranscriptSignalSource.correctionSignal(in: t)
        XCTAssertNotNil(signal)
        XCTAssertEqual(signal?.source, "transcript")
        XCTAssertEqual(signal?.suggestedLane, .capability)
        XCTAssertEqual(signal?.suggestedDomain, "chat")
        XCTAssertTrue(signal!.summary.contains("2 user correction(s)"))
        XCTAssertTrue(signal!.evidence.contains("you forgot the subscription discount"))
    }

    func testTranscriptCorrectionIgnoredWhenNoAssistantNearby() {
        // "no" as the very first message has no assistant turn to correct.
        let t = thread(messages: [
            (.user, "no I changed my mind about the plan"),
            (.user, "let's do the other thing")
        ])
        XCTAssertNil(TranscriptSignalSource.correctionSignal(in: t))
    }

    func testTranscriptCorrectionDoesNotMatchMidSentenceNo() {
        // "Notes about..." starts with "no" as a substring, not a correction.
        let t = thread(messages: [
            (.assistant, "Done."),
            (.user, "Notes about the launch look good")
        ])
        XCTAssertNil(TranscriptSignalSource.correctionSignal(in: t))
    }

    func testTranscriptRepeatedAsksDetected() {
        let t = thread(messages: [
            (.user, "Summarize my unread email"),
            (.assistant, "Here's a summary..."),
            (.user, "summarize my unread email!"),
            (.assistant, "Here's a summary again..."),
            (.user, "Summarize my unread email")
        ])
        let signal = TranscriptSignalSource.repeatSignal(in: t)
        XCTAssertNotNil(signal)
        XCTAssertEqual(signal?.severity, .high, "3+ near-identical asks rank high")
        XCTAssertEqual(signal?.suggestedDomain, "chat")
    }

    func testTranscriptHarvestScansThreadFilesOnDisk() async throws {
        let dir = tempDir()
        let noisy = thread(messages: [
            (.assistant, "Scheduled it."),
            (.user, "wrong day, I meant Friday")
        ])
        Persistence.save(noisy, to: dir.appendingPathComponent("\(noisy.id.uuidString).json"))
        // index.json must be skipped, not decoded as a thread.
        Persistence.save([ChatThreadIndexEntry](), to: dir.appendingPathComponent("index.json"))

        let source = TranscriptSignalSource(threadsDir: dir)
        let signals = try await source.harvest()
        XCTAssertEqual(signals.count, 1)
        XCTAssertTrue(signals[0].summary.contains("1 user correction(s)"))
    }

    func testTranscriptNormalizeForRepeat() {
        XCTAssertEqual(
            TranscriptSignalSource.normalizeForRepeat("  Summarize   my UNREAD email!! "),
            TranscriptSignalSource.normalizeForRepeat("summarize my unread email")
        )
    }

    // MARK: - SwarmSignalSource

    func testSwarmFailedJobBecomesHighSeveritySignal() {
        let job = AgentJob(
            title: "Ship the thing",
            goal: "Build feature X end to end",
            status: .failed,
            rootDir: "/tmp",
            errorMessage: "worker 2 exited 1"
        )
        let steps = [AgentStep(kind: .error, text: "claude CLI crashed: exit 1")]
        let signals = SwarmSignalSource.signals(for: job, steps: steps)
        XCTAssertEqual(signals.count, 1)
        XCTAssertEqual(signals[0].severity, .high)
        XCTAssertEqual(signals[0].suggestedLane, .reliability)
        XCTAssertEqual(signals[0].suggestedDomain, "swarm")
        XCTAssertTrue(signals[0].evidence.contains("worker 2 exited 1"))
    }

    /// Self-Upgrade's own build jobs are not problems a person hit: a build
    /// that failed (an expired sign-in, a red suite) became proposal 427D17A0
    /// "Swarm job failed: 'foundry: fs-audit: ...'", which builds and fails
    /// again (sense pass 5, D67). Every state, error steps included.
    func testSwarmSkipsSelfUpgradesOwnJobsInEveryState() {
        let errors = (0..<9).map { AgentStep(kind: .error, text: "e\($0)") }
        for status in [AgentJob.Status.failed, .cancelled, .waiting, .paused, .running, .queued, .done] {
            var job = AgentJob(title: RDWorker.escalationTitlePrefix + "fs-audit: 36 gated outcomes", goal: "g",
                               status: status, rootDir: "/tmp", errorMessage: "workers failed: architect")
            job.startedBy = .selfUpgrade
            job.pausedReason = .authLimitHit
            job.lastHeartbeatAt = Date(timeIntervalSinceNow: -3600)
            XCTAssertEqual(SwarmSignalSource.signals(for: job, steps: errors), [], "\(status) self-upgrade job filed a signal")
        }
    }

    /// One stored before `startedBy` existed is known by its title, the same
    /// rule chat uses (`AgentService.reportsEndToChat`); a person's job whose
    /// title happens to start the same way, made after, still counts.
    func testSwarmSkipsAnOlderSelfUpgradeJobByTitleOnly() {
        let before = AgentService.startedByIntroduced.addingTimeInterval(-1)
        let older = AgentJob(title: RDWorker.escalationTitlePrefix + "x", goal: "g", status: .failed,
                             createdAt: before, rootDir: "/tmp", errorMessage: "boom")
        XCTAssertEqual(SwarmSignalSource.signals(for: older, steps: []), [])
        let persons = AgentJob(title: RDWorker.escalationTitlePrefix + "x", goal: "g", status: .failed,
                               createdAt: AgentService.startedByIntroduced, rootDir: "/tmp", errorMessage: "boom")
        XCTAssertEqual(SwarmSignalSource.signals(for: persons, steps: []).count, 1)
        let olderPersons = AgentJob(title: "Ship the thing", goal: "g", status: .failed,
                                    createdAt: before, rootDir: "/tmp", errorMessage: "boom")
        XCTAssertEqual(SwarmSignalSource.signals(for: olderPersons, steps: []).count, 1)
    }

    /// A job that failed because Claude's sign-in expired is fixed by signing
    /// in, which Now and Agents already say. Filed here it became proposal
    /// 37A54595 "Swarm job failed: 'Reply with the single word hi...' (and 8
    /// more like it)", 90 of 100, about $3 of building (sense pass 6, D76).
    /// Known by the worker's verdict, or by the job's own words for a job
    /// stored before workers carried one; error steps included.
    func testSwarmSkipsAJobThatFailedOnTheSignIn() {
        let errors = (0..<9).map { AgentStep(kind: .error, text: "Failed to authenticate \($0)") }
        var worker = SwarmWorkerSpec(role: .generic, label: "solo", goal: "g", cwd: "/tmp", model: "m", budgetUSD: 1)
        worker.status = .failed
        worker.interruption = WorkerInterruption(kind: .signInExpired)
        let byVerdict = AgentJob(title: "Reply with the single word hi", goal: "g", status: .failed,
                                 workers: [worker], rootDir: "/tmp", errorMessage: "workers failed: solo")
        XCTAssertEqual(SwarmSignalSource.signals(for: byVerdict, steps: errors), [], "verdict")
        for words in ["workers failed: solo (Failed to authenticate: OAuth session expired and could not be refreshed)",
                      "Failed to authenticate. API Error: 401",
                      "OAuth token has expired. Please run /login"] {
            let byWords = AgentJob(title: "Reply with the single word hi", goal: "g", status: .failed,
                                   rootDir: "/tmp", errorMessage: words)
            XCTAssertEqual(SwarmSignalSource.signals(for: byWords, steps: errors), [], words)
        }
        // Any other failure still files, and so does a worker that was
        // interrupted by the sign-in, signed in again, and then failed for
        // its own reasons.
        var retried = worker
        retried.interruption = WorkerInterruption(kind: .signInExpired)
        retried.status = .done
        var other = worker
        other.interruption = nil
        let otherFailure = AgentJob(title: "Ship the thing", goal: "g", status: .failed,
                                    workers: [retried, other], rootDir: "/tmp", errorMessage: "workers failed: solo (exit 1)")
        XCTAssertEqual(SwarmSignalSource.signals(for: otherFailure, steps: []).count, 1)
    }

    /// W19-P3 item 5: one worker failing on the sign-in hid a sibling that
    /// failed for its own reasons, by the verdict and by the job's words alike.
    /// Signing in fixes only the first; the second still files.
    func testASiblingsOwnFailureFilesBesideASignInFailure() {
        var signedOut = SwarmWorkerSpec(role: .generic, label: "a", goal: "g", cwd: "/tmp", model: "m", budgetUSD: 1)
        signedOut.status = .failed
        signedOut.interruption = WorkerInterruption(kind: .signInExpired)
        var broken = SwarmWorkerSpec(role: .generic, label: "b", goal: "g", cwd: "/tmp", model: "m", budgetUSD: 1)
        broken.status = .failed
        for words in ["workers failed: a (Failed to authenticate: OAuth session expired), b (exit 1)",
                      "workers failed: a, b"] {
            for order in [[signedOut, broken], [broken, signedOut]] {
                let job = AgentJob(title: "Ship the thing", goal: "g", status: .failed,
                                   workers: order, rootDir: "/tmp", errorMessage: words)
                let filed = SwarmSignalSource.signals(for: job, steps: [])
                XCTAssertEqual(filed.count, 1, "\(words) \(order.map(\.label))")
                XCTAssertTrue(filed.first?.summary.contains("Swarm job failed") == true, words)
            }
        }
        // Every failed worker failed on the sign-in: still nothing to build,
        // whatever the others did.
        var finished = broken
        finished.status = .done
        let onlySignIn = AgentJob(title: "Ship the thing", goal: "g", status: .failed,
                                  workers: [signedOut, finished, signedOut], rootDir: "/tmp",
                                  errorMessage: "workers failed: a, a")
        XCTAssertEqual(SwarmSignalSource.signals(for: onlySignIn, steps: []), [])
        // Wave 20 round 1: no worker carries a verdict, so the job's own words
        // judge it, as before (D76).
        let noVerdict = AgentJob(title: "Ship the thing", goal: "g", status: .failed, workers: [broken],
                                 rootDir: "/tmp",
                                 errorMessage: "workers failed: b (Failed to authenticate: OAuth session expired and could not be refreshed)")
        XCTAssertEqual(SwarmSignalSource.signals(for: noVerdict, steps: []), [])
    }

    func testSwarmAuthLimitInterruptionBecomesCostSignal() {
        var job = AgentJob(title: "Long refactor", goal: "g", status: .waiting, rootDir: "/tmp")
        job.pausedReason = .authLimitHit
        let signals = SwarmSignalSource.signals(for: job, steps: [])
        XCTAssertEqual(signals.count, 1)
        XCTAssertEqual(signals[0].suggestedLane, .cost)
        XCTAssertTrue(signals[0].summary.contains("auth/session limit"))
    }

    func testSwarmStaleHeartbeatOnRunningJobIsTimeoutShaped() {
        var job = AgentJob(title: "Zombie", goal: "g", status: .running, rootDir: "/tmp")
        job.lastHeartbeatAt = Date(timeIntervalSinceNow: -3600)
        let signals = SwarmSignalSource.signals(for: job, steps: [], staleHeartbeat: 600)
        XCTAssertEqual(signals.count, 1)
        XCTAssertTrue(signals[0].summary.contains("stalled"))
        XCTAssertEqual(signals[0].severity, .high)
    }

    func testSwarmHealthyDoneJobEmitsNothing() {
        let job = AgentJob(title: "Clean run", goal: "g", status: .done, rootDir: "/tmp")
        let steps = [AgentStep(kind: .workerEnd, text: "done")]
        XCTAssertTrue(SwarmSignalSource.signals(for: job, steps: steps).isEmpty)
    }

    func testSwarmErrorStepClusterFlaggedEvenWhenJobDone() {
        let job = AgentJob(title: "Rough run", goal: "g", status: .done, rootDir: "/tmp")
        let steps = (0..<4).map { AgentStep(kind: .error, text: "transient failure \($0)") }
        let signals = SwarmSignalSource.signals(for: job, steps: steps)
        XCTAssertEqual(signals.count, 1)
        XCTAssertTrue(signals[0].summary.contains("4 error steps"))
    }

    func testSwarmHarvestReadsAgentStoreLayoutOnDisk() async throws {
        let dir = tempDir()
        let store = AgentStore(rootDir: dir)
        let job = AgentJob(
            title: "Disk fixture",
            goal: "fail on purpose",
            status: .failed,
            rootDir: "/tmp",
            errorMessage: "boom"
        )
        try await store.saveJob(job)
        await store.appendStep(jobId: job.id, step: AgentStep(kind: .error, text: "boom detail"))

        let source = SwarmSignalSource(agentsDir: dir)
        let signals = try await source.harvest()
        XCTAssertEqual(signals.count, 1)
        XCTAssertTrue(signals[0].evidence.contains("boom"))
    }

    // MARK: - FlakeSignalSource

    private let flakeLog = """
    Test Suite 'GruxTests' started.
    Test Case '-[GruxTests.FooTests testStable]' passed (0.001 seconds).
    Test Case '-[GruxTests.FooTests testFlaky]' failed (0.120 seconds).
    /tmp/FooTests.swift:42: error: XCTAssertEqual failed: ("1") is not equal to ("2")
    Test Case '-[GruxTests.FooTests testFlaky]' passed (0.118 seconds).
    Test Case '-[GruxTests.BarTests testBroken]' failed (0.030 seconds).
    Test Suite 'GruxTests' failed.
    """

    func testFlakeParserSeparatesFlakesFromHardFailures() {
        let signals = FlakeSignalSource.signals(fromTestLog: flakeLog)
        XCTAssertEqual(signals.count, 2)

        let broken = signals.first { $0.summary.contains("testBroken") }
        XCTAssertNotNil(broken)
        XCTAssertEqual(broken?.severity, .high)
        XCTAssertTrue(broken!.summary.hasPrefix("Failing test:"))

        let flaky = signals.first { $0.summary.contains("testFlaky") }
        XCTAssertNotNil(flaky)
        XCTAssertEqual(flaky?.severity, .medium)
        XCTAssertTrue(flaky!.summary.contains("passed 1x, failed 1x"))
        XCTAssertEqual(flaky?.suggestedLane, .codeHealth)
        XCTAssertEqual(flaky?.suggestedDomain, "tests")
    }

    func testFlakeParserIgnoresAllPassingLog() {
        let log = "Test Case '-[GruxTests.FooTests testGood]' passed (0.001 seconds)."
        XCTAssertTrue(FlakeSignalSource.signals(fromTestLog: log).isEmpty)
    }

    func testFlakeHarvestUsesSeamPathAndMissingFileIsQuiet() async throws {
        let dir = tempDir()
        let missing = FlakeSignalSource(logURL: dir.appendingPathComponent("nope.log"))
        let none = try await missing.harvest()
        XCTAssertTrue(none.isEmpty)

        let logURL = dir.appendingPathComponent("test-output.log")
        try flakeLog.write(to: logURL, atomically: true, encoding: .utf8)
        let source = FlakeSignalSource(logURL: logURL)
        let signals = try await source.harvest()
        XCTAssertEqual(signals.count, 2)
    }

    func testFlakeTestCaseNameExtraction() {
        XCTAssertEqual(
            FlakeSignalSource.testCaseName(in: "Test Case '-[GruxTests.FooTests testBar]' passed (0.1 seconds)."),
            "GruxTests.FooTests testBar"
        )
        XCTAssertNil(FlakeSignalSource.testCaseName(in: "random build output"))
    }

    // MARK: - CompareSignalSource

    private func comparisonFixture() -> [ComparisonRecord] {
        // "loser" appears in 5 voted matchups and never wins; "champ" wins all.
        var records: [ComparisonRecord] = []
        for i in 0..<5 {
            let champ = ComparisonOutput(backendName: "champ", modelId: "m1", text: "good", latencySeconds: 1)
            let loser = ComparisonOutput(backendName: "loser", modelId: "m2", text: "meh", latencySeconds: 2)
            records.append(ComparisonRecord(
                prompt: "prompt \(i)",
                outputs: [champ, loser],
                labelSeed: UInt64(i),
                votedOutputId: champ.id
            ))
        }
        // Errors for a third backend.
        for i in 0..<2 {
            records.append(ComparisonRecord(
                prompt: "err prompt \(i)",
                outputs: [ComparisonOutput(
                    backendName: "flaky-backend", modelId: "m3", text: "",
                    latencySeconds: 0, errorText: "HTTP 529 overloaded"
                )],
                labelSeed: 99
            ))
        }
        return records
    }

    func testCompareLopsidedLoserAndErrorBackendDetected() {
        let signals = CompareSignalSource.signals(from: comparisonFixture())

        let loser = signals.first { $0.summary.contains("'loser'") }
        XCTAssertNotNil(loser)
        XCTAssertTrue(loser!.summary.contains("wins 0/5"))
        XCTAssertEqual(loser?.suggestedLane, .capability)
        XCTAssertEqual(loser?.suggestedDomain, "compare")

        let errs = signals.first { $0.summary.contains("'flaky-backend'") }
        XCTAssertNotNil(errs)
        XCTAssertEqual(errs?.suggestedLane, .reliability)
        XCTAssertTrue(errs!.evidence.contains("HTTP 529"))

        XCTAssertNil(signals.first { $0.summary.contains("'champ'") }, "winners are not flagged")
    }

    func testCompareUnvotedBacklogFlaggedAsUXSignal() {
        var records: [ComparisonRecord] = []
        for i in 0..<10 {
            records.append(ComparisonRecord(
                prompt: "p\(i)",
                outputs: [ComparisonOutput(backendName: "a", modelId: "m", text: "t", latencySeconds: 1)],
                labelSeed: 1
            ))
        }
        let signals = CompareSignalSource.signals(from: records)
        let backlog = signals.first { $0.suggestedDomain == "ui:compare" }
        XCTAssertNotNil(backlog)
        XCTAssertEqual(backlog?.suggestedLane, .uxPolish)
        XCTAssertTrue(backlog!.summary.contains("0/10"))
    }

    func testCompareEmptyHistoryEmitsNothing() {
        XCTAssertTrue(CompareSignalSource.signals(from: []).isEmpty)
    }

    func testCompareHarvestReadsHistoryFile() async throws {
        let dir = tempDir()
        let url = dir.appendingPathComponent("comparisons.json")
        Persistence.save(comparisonFixture(), to: url)
        let source = CompareSignalSource(historyURL: url)
        let signals = try await source.harvest()
        XCTAssertFalse(signals.isEmpty)
    }

    // MARK: - TelemetrySignalSource

    func testTelemetryFSAuditDenialsParsed() {
        let now = Date()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let ts = iso.string(from: now)
        let raw = """
        {"bytes":120,"outcome":"ok","path":"/tmp/a.txt","reason":"","resolved":"/tmp/a.txt","tool":"fs_read","ts":"\(ts)"}
        {"bytes":0,"outcome":"denied","path":"/etc/passwd","reason":"outside sandbox","resolved":"/etc/passwd","tool":"fs_read","ts":"\(ts)"}
        {"bytes":0,"outcome":"denied","path":"/etc/hosts","reason":"outside sandbox","resolved":"/etc/hosts","tool":"fs_read","ts":"\(ts)"}
        {"bytes":0,"outcome":"denied","path":"/etc/sudoers","reason":"outside sandbox","resolved":"/etc/sudoers","tool":"fs_list","ts":"\(ts)"}
        not json at all
        """
        let signals = TelemetrySignalSource.signalsFromFSAudit(raw, since: now.addingTimeInterval(-60))
        XCTAssertEqual(signals.count, 1)
        XCTAssertEqual(signals[0].severity, .medium, "3 denials rank medium")
        XCTAssertTrue(signals[0].summary.contains("3 'denied'"))
        XCTAssertEqual(signals[0].suggestedDomain, "filesystem-tool")
        XCTAssertTrue(signals[0].evidence.contains("/etc/passwd"))
    }

    func testTelemetryFSAuditRespectsLookbackWindow() {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let old = iso.string(from: Date(timeIntervalSinceNow: -90 * 24 * 3600))
        let raw = """
        {"bytes":0,"outcome":"denied","path":"/x","reason":"old","resolved":"/x","tool":"fs_read","ts":"\(old)"}
        """
        let signals = TelemetrySignalSource.signalsFromFSAudit(raw, since: Date(timeIntervalSinceNow: -3600))
        XCTAssertTrue(signals.isEmpty)
    }

    // D84: a quiet fs-audit log means nobody used the filesystem tools. That is
    // not a problem to build code for, so it files nothing (proposal 3B7902DA
    // was "fs-audit: log silent for 7d"). On, one second under and one second
    // over the freshness window.
    func testTelemetryFSAuditSilentLogFilesNothing() {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let asOf = Date(timeIntervalSince1970: 1_800_000_000)
        let window: TimeInterval = 7 * 24 * 3600
        func audit(ageSeconds: TimeInterval, outcome: String) -> String {
            let ts = iso.string(from: asOf.addingTimeInterval(-ageSeconds))
            return """
            {"bytes":0,"outcome":"\(outcome)","path":"/etc/hosts","reason":"outside sandbox","resolved":"/etc/hosts","tool":"fs_read","ts":"\(ts)"}
            """
        }
        func harvest(_ raw: String) -> [FoundrySignal] {
            TelemetrySignalSource.signalsFromFSAudit(raw, since: asOf.addingTimeInterval(-window), asOf: asOf, staleAfter: window)
        }
        for outcome in ["ok", "denied"] {
            XCTAssertEqual(harvest(audit(ageSeconds: window + 1, outcome: outcome)), [],
                           "a log silent one second past the window files nothing (\(outcome))")
            XCTAssertEqual(harvest(audit(ageSeconds: 30 * 24 * 3600, outcome: outcome)), [],
                           "a log silent for a month files nothing (\(outcome))")
            XCTAssertEqual(harvest(audit(ageSeconds: window + 1, outcome: outcome)
                                   + "\n" + audit(ageSeconds: 90 * 24 * 3600, outcome: "denied")), [],
                           "older denials behind a silent log stay unmined (\(outcome))")
        }
        XCTAssertEqual(harvest(audit(ageSeconds: window, outcome: "ok")), [], "one ok call exactly on the window files nothing")
        XCTAssertEqual(harvest(audit(ageSeconds: window - 1, outcome: "denied")).count, 1,
                       "a denial one second inside the window still files")
        XCTAssertEqual(harvest(audit(ageSeconds: window, outcome: "denied")).count, 1,
                       "a denial exactly on the window edge still files")
    }

    func testTelemetryErrorLogScan() {
        let contents = """
        2026-06-09 boot ok
        2026-06-09 ERROR speech engine failed to attach
        2026-06-09 info heartbeat
        2026-06-09 fatal: watchdog exception in mic controller
        """
        let signal = TelemetrySignalSource.signalFromErrorLog(named: "wake.log", contents: contents)
        XCTAssertNotNil(signal)
        XCTAssertTrue(signal!.summary.contains("wake.log: 2 error-shaped"))
        XCTAssertEqual(signal?.suggestedLane, .reliability)
        XCTAssertNil(TelemetrySignalSource.signalFromErrorLog(named: "clean.log", contents: "all good\n"))
    }

    func testTelemetryHarvestFromFixtureDir() async throws {
        let dir = tempDir()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let ts = iso.string(from: Date())
        let audit = """
        {"bytes":0,"outcome":"denied","path":"/etc/passwd","reason":"outside sandbox","resolved":"/etc/passwd","tool":"fs_read","ts":"\(ts)"}
        """
        try audit.write(to: dir.appendingPathComponent("fs-audit.log"), atomically: true, encoding: .utf8)
        try "ERROR one bad thing\n".write(to: dir.appendingPathComponent("wake.log"), atomically: true, encoding: .utf8)

        let source = TelemetrySignalSource(supportDir: dir)
        let signals = try await source.harvest()
        XCTAssertEqual(signals.count, 2)
        XCTAssertTrue(signals.allSatisfy { $0.source == "telemetry" })
    }

    // MARK: - UXAuditSource

    func testUXAuditParsesPipeDelimitedCritique() async throws {
        let critique = """
        HIGH | Settings uses raw default-blue buttons | Save button bottom right is system blue, not violet accent
        MEDIUM | Empty state is a blank pane | Notes list shows nothing when empty, no CTA
        chatty preamble that should be ignored
        LOW | Padding too chunky on toolbar | 20px+ padding on top toolbar buttons
        """
        let source = UXAuditSource(
            tabs: ["settings"],
            driver: FixtureUXAppDriver(shots: [UXTabScreenshot(tab: "settings", jpeg: Data([0xFF]))]),
            critic: FixtureUXVisionCritic(critiques: ["settings": critique])
        )
        let signals = try await source.harvest()
        XCTAssertEqual(signals.count, 3)
        XCTAssertEqual(signals[0].severity, .high)
        XCTAssertEqual(signals[0].suggestedDomain, "ui:settings")
        XCTAssertEqual(signals[0].suggestedLane, .uxPolish)
        XCTAssertTrue(signals[0].summary.hasPrefix("[settings]"))
    }

    func testUXAuditCleanTabEmitsNothing() async throws {
        let source = UXAuditSource(
            tabs: ["chat"],
            driver: FixtureUXAppDriver(shots: [UXTabScreenshot(tab: "chat", jpeg: Data([0x01]))]),
            critic: FixtureUXVisionCritic(critiques: ["chat": ""])
        )
        let signals = try await source.harvest()
        XCTAssertTrue(signals.isEmpty)
    }

    func testUXAuditSeverityTokens() {
        XCTAssertEqual(UXAuditSource.severity(from: "high"), .high)
        XCTAssertEqual(UXAuditSource.severity(from: "MED"), .medium)
        XCTAssertEqual(UXAuditSource.severity(from: "Info"), .info)
        XCTAssertNil(UXAuditSource.severity(from: "CRITICALISH"))
    }

    // MARK: - SignalHarvester orchestration

    private struct BoomSource: FoundrySignalSource {
        let sourceName = "boom"
        func harvest() async throws -> [FoundrySignal] {
            throw NSError(domain: "test", code: 7, userInfo: [NSLocalizedDescriptionKey: "fixture explosion"])
        }
    }

    private struct CannedSource: FoundrySignalSource {
        let sourceName: String
        let canned: [FoundrySignal]
        func harvest() async throws -> [FoundrySignal] { canned }
    }

    func testHarvesterIsolatesPerSourceFailures() async {
        let good = CannedSource(sourceName: "good", canned: [
            FoundrySignal(source: "good", severity: .low, summary: "ok signal",
                          evidence: "e", suggestedLane: .codeHealth, suggestedDomain: "tests"),
            FoundrySignal(source: "good", severity: .high, summary: "urgent signal",
                          evidence: "e", suggestedLane: .reliability, suggestedDomain: "tests")
        ])
        let harvester = SignalHarvester(sources: [BoomSource(), good])
        let report = await harvester.harvest()

        XCTAssertEqual(report.signals.count, 2, "good source survives the boom source")
        XCTAssertEqual(report.sourceErrors.count, 1)
        XCTAssertTrue(report.sourceErrors["boom"]?.contains("fixture explosion") == true)
        XCTAssertEqual(report.signals.first?.severity, .high, "sorted high severity first")
        XCTAssertEqual(report.bySeverity[.high], 1)
        XCTAssertEqual(report.bySeverity[.low], 1)
        XCTAssertLessThanOrEqual(report.startedAt, report.finishedAt)
    }

    func testHarvesterStandardLineupRunsAgainstEmptyFixtures() async {
        // Point every store-reading source at empty temp dirs so the standard
        // shape is exercised without touching real Application Support.
        let dir = tempDir()
        let harvester = SignalHarvester(sources: [
            TelemetrySignalSource(supportDir: dir),
            TranscriptSignalSource(threadsDir: dir),
            SwarmSignalSource(agentsDir: dir),
            FlakeSignalSource(logURL: dir.appendingPathComponent("test-output.log")),
            CompareSignalSource(historyURL: dir.appendingPathComponent("comparisons.json"))
        ])
        let report = await harvester.harvest()
        XCTAssertTrue(report.signals.isEmpty)
        XCTAssertTrue(report.sourceErrors.isEmpty)
    }

    func testSeverityOrdering() {
        XCTAssertTrue(FoundrySignal.Severity.info < .low)
        XCTAssertTrue(FoundrySignal.Severity.low < .medium)
        XCTAssertTrue(FoundrySignal.Severity.medium < .high)
    }
}
