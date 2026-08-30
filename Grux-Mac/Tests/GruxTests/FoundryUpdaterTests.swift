import XCTest
@testable import Grux

// Phase C landing machinery: archive/restore staging, crash-loop math,
// crash detection markers, protected-zone refusal, and the auto-revert /
// kept transitions. Every root is a temp dir; the real /Applications path
// is NEVER touched.
@MainActor
final class FoundryUpdaterTests: XCTestCase {

    private var root: URL!
    private var appURL: URL!
    private var archiveRoot: URL!
    private var stateDir: URL!
    private var proposalStore: ProposalStore!
    private var trustLedger: TrustLedger!
    private var timeline: FoundryTimelineStore!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("foundry-updater-tests-\(UUID().uuidString)", isDirectory: true)
        appURL = root.appendingPathComponent("Applications/Grux.app", isDirectory: true)
        archiveRoot = root.appendingPathComponent("previous-build", isDirectory: true)
        stateDir = root.appendingPathComponent("updater-state", isDirectory: true)
        try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
        proposalStore = ProposalStore(storageURL: root.appendingPathComponent("proposals.json"))
        trustLedger = TrustLedger(storageURL: root.appendingPathComponent("ledger.json"))
        timeline = FoundryTimelineStore(storageURL: root.appendingPathComponent("timeline.json"))
        try writeAppPayload("build-1")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Helpers

    private func writeAppPayload(_ marker: String) throws {
        try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
        try marker.data(using: .utf8)!
            .write(to: appURL.appendingPathComponent("payload.txt"))
    }

    private func appPayload(at url: URL? = nil) -> String? {
        let bundle = url ?? appURL!
        guard let data = try? Data(contentsOf: bundle.appendingPathComponent("payload.txt")) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func makeUpdater(probe: FoundryRegressionProbe = StubFoundryRegressionProbe()) -> GruxUpdater {
        GruxUpdater(
            appURL: appURL,
            archiveRoot: archiveRoot,
            stateDir: stateDir,
            proposalStore: proposalStore,
            trustLedger: trustLedger,
            timeline: timeline,
            probe: probe
        )
    }

    private func makeProposal(risk: RiskClass = .low, status: ProposalStatus = .proposed) -> UpgradeProposal {
        var p = UpgradeProposal(
            title: "Test upgrade",
            lane: .performance,
            domain: .mac,
            expectedGain: 0.5,
            riskClass: risk,
            estCostLabel: "$2 estimated",
            tierRequired: .autoBuild,
            readyPrompt: "do the thing"
        )
        p.status = status
        return p
    }

    // Walk a filed proposal to .verifying through legal transitions.
    private func fileVerifyingProposal(risk: RiskClass = .low) -> UpgradeProposal {
        let filed = proposalStore.file(makeProposal(risk: risk))
        proposalStore.transition(id: filed.id, to: .accepted)
        proposalStore.transition(id: filed.id, to: .building)
        proposalStore.transition(id: filed.id, to: .verifying)
        return proposalStore.proposal(id: filed.id)!
    }

    // MARK: - Archive / restore

    func testArchiveCreatesVersionedSlotAndKeepsLastTwo() throws {
        let updater = makeUpdater()
        let base = Date(timeIntervalSince1970: 1_750_000_000)
        try updater.archiveCurrentBuild(now: base)
        try writeAppPayload("build-2")
        try updater.archiveCurrentBuild(now: base.addingTimeInterval(60))
        try writeAppPayload("build-3")
        try updater.archiveCurrentBuild(now: base.addingTimeInterval(120))

        let slots = updater.archiveSlots()
        XCTAssertEqual(slots.count, GruxUpdater.keepArchives, "prune keeps the last 2 only")

        // Newest archive holds build-3; the oldest (build-1) was pruned.
        let newest = updater.latestArchivedApp()
        XCTAssertNotNil(newest)
        XCTAssertEqual(appPayload(at: newest), "build-3")
    }

    func testArchiveThrowsWhenAppMissing() {
        try? FileManager.default.removeItem(at: appURL)
        let updater = makeUpdater()
        XCTAssertThrowsError(try updater.archiveCurrentBuild()) { error in
            guard case GruxUpdaterError.appMissing = error else {
                return XCTFail("expected appMissing, got \(error)")
            }
        }
    }

    func testRestorePreviousBuildSwapsTheBundleBack() throws {
        let updater = makeUpdater()
        try updater.archiveCurrentBuild()
        try writeAppPayload("bad-new-build")
        XCTAssertEqual(appPayload(), "bad-new-build")

        try updater.restorePreviousBuild()
        XCTAssertEqual(appPayload(), "build-1", "archived build restored over the bad one")
    }

    func testRestoreThrowsWithNoArchive() {
        let updater = makeUpdater()
        XCTAssertThrowsError(try updater.restorePreviousBuild()) { error in
            XCTAssertEqual(error as? GruxUpdaterError, .archiveMissing)
        }
    }

    // MARK: - Codesign identity parsing

    func testParseTeamIdentifier() {
        let out = """
        Executable=/Applications/Grux.app/Contents/MacOS/Grux
        Identifier=com.gruxai.grux
        TeamIdentifier=ABCDE12345
        """
        XCTAssertEqual(GruxUpdater.parseTeamIdentifier(fromCodesignOutput: out), "ABCDE12345")
        XCTAssertNil(GruxUpdater.parseTeamIdentifier(fromCodesignOutput: "TeamIdentifier=not set"))
        XCTAssertNil(GruxUpdater.parseTeamIdentifier(fromCodesignOutput: "code object is not signed at all"))
    }

    func testInstallScriptCarriesVerifyAndRevert() {
        let script = GruxUpdater.installScriptTemplate
        XCTAssertTrue(script.contains("./build.sh || revert"))
        XCTAssertTrue(script.contains("TeamIdentifier="))
        XCTAssertTrue(script.contains("cp -R \"$ARCHIVE\" \"$APP\""))
        XCTAssertTrue(script.contains("open \"$APP\""))
        // Injection rail: the template must be fully static. Paths only ever
        // arrive as positional argv, never interpolated into the body.
        XCTAssertFalse(script.contains("\\("), "no interpolation in the template")
        let args = GruxUpdater.installScriptArguments(
            worktree: URL(fileURLWithPath: "/tmp/wt; rm -rf $HOME"),
            appPath: "/tmp/Applications/Grux.app",
            archivedAppPath: "/tmp/prev/Grux.app",
            expectedTeamIdentifier: "ABCDE12345"
        )
        XCTAssertEqual(args, ["/tmp/wt; rm -rf $HOME", "/tmp/Applications/Grux.app", "/tmp/prev/Grux.app", "ABCDE12345"],
                       "hostile path stays an inert argv element, never shell code")
    }

    // MARK: - selfInstall

    func testSelfInstallRefusesProtectedAtAnyTier() throws {
        let updater = makeUpdater()
        let proposal = fileVerifyingProposal(risk: .protected)
        var ran = false
        updater.installRunner = { _, _ in ran = true }

        XCTAssertThrowsError(
            try updater.selfInstall(fromWorktree: root, proposal: proposal)
        ) { error in
            XCTAssertEqual(error as? GruxUpdaterError, .protectedZone)
        }
        XCTAssertFalse(ran, "protected proposals must never reach the runner")
        XCTAssertNil(updater.loadPendingWatch())
        XCTAssertTrue(timeline.entries.contains { $0.title.contains("Auto-install refused") })
    }

    func testSelfInstallArchivesArmsWatchAndSpawnsRunner() throws {
        let updater = makeUpdater()
        let proposal = fileVerifyingProposal()
        // Stage a build.sh in the fake worktree.
        let worktree = root.appendingPathComponent("worktree", isDirectory: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try "#!/bin/bash\nexit 0\n".data(using: .utf8)!
            .write(to: worktree.appendingPathComponent("build.sh"))

        var spawned: URL?
        var spawnedArgs: [String]?
        updater.installRunner = { url, args in spawned = url; spawnedArgs = args }

        // alreadyVerifiedGreen: this test exercises archive + watch + spawn, not
        // the green-land backstop (which runs swift build and has its own path);
        // the fake worktree has only build.sh, no Grux-Mac package to build.
        try updater.selfInstall(fromWorktree: worktree, proposal: proposal, alreadyVerifiedGreen: true)

        XCTAssertNotNil(spawned, "detached install script spawned")
        XCTAssertEqual(spawnedArgs?.count, 4, "worktree, app, archive, team id as argv")
        XCTAssertEqual(spawnedArgs?.first, worktree.path)
        XCTAssertNotNil(updater.latestArchivedApp(), "previous build archived first")
        XCTAssertEqual(updater.loadPendingWatch()?.proposalId, proposal.id, "24h watch armed")
        XCTAssertEqual(proposalStore.proposal(id: proposal.id)?.status, .landed)
        if let script = spawned, let text = try? String(contentsOf: script, encoding: .utf8) {
            XCTAssertTrue(text.contains("./build.sh || revert"))
            XCTAssertFalse(text.contains(worktree.path), "no path baked into the script body")
        } else {
            XCTFail("install script not written")
        }
    }

    func testSelfInstallRefusesSecondInstallDuringOpenWatch() throws {
        let updater = makeUpdater()
        let worktree = root.appendingPathComponent("worktree", isDirectory: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try "#!/bin/bash\nexit 0\n".data(using: .utf8)!
            .write(to: worktree.appendingPathComponent("build.sh"))
        updater.installRunner = { _, _ in }

        let a = fileVerifyingProposal()
        try updater.selfInstall(fromWorktree: worktree, proposal: a, alreadyVerifiedGreen: true)
        XCTAssertEqual(updater.loadPendingWatch()?.proposalId, a.id)
        let archivesAfterA = updater.archiveSlots().count

        // Proposal B lands before A's 24h watch settles: refused, watch A
        // intact, no second archive of the unproven build.
        let b = fileVerifyingProposal()
        XCTAssertThrowsError(
            try updater.selfInstall(fromWorktree: worktree, proposal: b)
        ) { error in
            guard case GruxUpdaterError.watchInProgress(let watched) = error else {
                return XCTFail("expected watchInProgress, got \(error)")
            }
            XCTAssertEqual(watched, a.id)
        }
        XCTAssertEqual(updater.loadPendingWatch()?.proposalId, a.id,
                       "A's watch record survives the refused install")
        XCTAssertEqual(updater.archiveSlots().count, archivesAfterA,
                       "the unproven build was never archived as a rollback target")
        XCTAssertNotEqual(proposalStore.proposal(id: b.id)?.status, .landed)
    }

    func testSelfInstallThrowsWhenBuildScriptMissing() {
        let updater = makeUpdater()
        let proposal = fileVerifyingProposal()
        XCTAssertThrowsError(
            try updater.selfInstall(fromWorktree: root, proposal: proposal)
        ) { error in
            guard case GruxUpdaterError.buildScriptMissing = error else {
                return XCTFail("expected buildScriptMissing, got \(error)")
            }
        }
    }

    // MARK: - Crash-loop math (pure)

    func testIsCrashLoopTwoInsideTenMinutes() {
        let install = Date(timeIntervalSince1970: 1_750_000_000)
        let crashes = [install.addingTimeInterval(100), install.addingTimeInterval(500)]
        XCTAssertTrue(GruxUpdater.isCrashLoop(crashes: crashes, since: install))
    }

    func testIsCrashLoopIgnoresSpreadOutCrashes() {
        let install = Date(timeIntervalSince1970: 1_750_000_000)
        let crashes = [install.addingTimeInterval(100), install.addingTimeInterval(2_000)]
        XCTAssertFalse(GruxUpdater.isCrashLoop(crashes: crashes, since: install),
                       "two crashes 32 minutes apart are not a loop")
    }

    func testIsCrashLoopIgnoresCrashesBeforeInstall() {
        let install = Date(timeIntervalSince1970: 1_750_000_000)
        let crashes = [
            install.addingTimeInterval(-300), install.addingTimeInterval(-100),
            install.addingTimeInterval(50)
        ]
        XCTAssertFalse(GruxUpdater.isCrashLoop(crashes: crashes, since: install),
                       "pre-install crashes never count against the new build")
    }

    func testIsCrashLoopSingleCrashIsNotALoop() {
        let install = Date(timeIntervalSince1970: 1_750_000_000)
        XCTAssertFalse(GruxUpdater.isCrashLoop(crashes: [install.addingTimeInterval(10)], since: install))
        XCTAssertFalse(GruxUpdater.isCrashLoop(crashes: [], since: install))
    }

    // MARK: - Crash detection markers

    func testHeartbeatWithoutCleanShutdownIsACrash() {
        let updater = makeUpdater()
        updater.recordHeartbeat()
        XCTAssertTrue(updater.detectCrashAtLaunch(), "heartbeat with no clean marker = crash")
        XCTAssertEqual(updater.loadCrashes().count, 1)
        // Heartbeat consumed: a second launch sees no crash.
        XCTAssertFalse(updater.detectCrashAtLaunch())
    }

    func testCleanShutdownAfterHeartbeatIsNotACrash() async throws {
        let updater = makeUpdater()
        updater.recordHeartbeat()
        // Clean marker strictly after the heartbeat.
        try await Task.sleep(nanoseconds: 20_000_000)
        updater.markCleanShutdown()
        XCTAssertFalse(updater.detectCrashAtLaunch())
        XCTAssertTrue(updater.loadCrashes().isEmpty)
    }

    func testNoMarkersMeansNoCrash() {
        XCTAssertFalse(makeUpdater().detectCrashAtLaunch())
    }

    // MARK: - Auto-revert + kept transitions

    func testAutoRevertRestoresRollsBackAndDemotes() throws {
        let updater = makeUpdater()
        // Earn Tier 1 on (performance, mac) so the demotion is visible.
        for _ in 0..<5 {
            trustLedger.recordAcceptedAndKept(lane: .performance, domain: .mac)
        }
        XCTAssertEqual(trustLedger.tier(lane: .performance, domain: .mac), .autoBuild)

        let proposal = fileVerifyingProposal()
        proposalStore.transition(id: proposal.id, to: .landed)
        try updater.archiveCurrentBuild()
        try writeAppPayload("regressed-build")

        var relaunched: URL?
        updater.relauncher = { relaunched = $0 }

        updater.autoRevert(proposalId: proposal.id, reason: "crash loop: test")

        XCTAssertEqual(appPayload(), "build-1", "archived build restored")
        XCTAssertEqual(relaunched, appURL, "restored build relaunched")
        XCTAssertEqual(proposalStore.proposal(id: proposal.id)?.status, .rolledBack)
        XCTAssertEqual(trustLedger.tier(lane: .performance, domain: .mac), .propose,
                       "rollback demotes the pair one tier")
        XCTAssertNil(updater.loadPendingWatch())
        XCTAssertTrue(timeline.entries.contains { $0.kind == .demotion })
        XCTAssertTrue(timeline.entries.contains { $0.kind == .rollback })
    }

    func testWatchSettleHookFiresForKeptAndReverted() throws {
        let updater = makeUpdater()
        updater.relauncher = { _ in }
        var settled: [(UUID, Bool)] = []
        updater.onWatchSettled = { settled.append(($0, $1)) }

        let kept = fileVerifyingProposal()
        proposalStore.transition(id: kept.id, to: .landed)
        updater.markKept(proposalId: kept.id)
        XCTAssertEqual(settled.last?.0, kept.id)
        XCTAssertEqual(settled.last?.1, true)

        let bad = fileVerifyingProposal()
        proposalStore.transition(id: bad.id, to: .landed)
        try updater.archiveCurrentBuild()
        updater.autoRevert(proposalId: bad.id, reason: "test")
        XCTAssertEqual(settled.last?.0, bad.id)
        XCTAssertEqual(settled.last?.1, false)
        XCTAssertEqual(settled.count, 2)
    }

    func testMarkKeptRecordsAcceptedAndKept() {
        let updater = makeUpdater()
        let proposal = fileVerifyingProposal()
        proposalStore.transition(id: proposal.id, to: .landed)

        updater.markKept(proposalId: proposal.id)

        let entry = trustLedger.entry(lane: .performance, domain: .mac)
        XCTAssertEqual(entry.streak, 1)
        XCTAssertTrue(timeline.entries.contains { $0.title.hasPrefix("Kept:") })
    }

    // MARK: - Watch resume across relaunch

    func testResumeWatchSettlesAnExpiredWindowAsKept() throws {
        let updater = makeUpdater()
        let proposal = fileVerifyingProposal()
        proposalStore.transition(id: proposal.id, to: .landed)
        // Stage a pending watch armed 25h ago (written directly so no watch
        // task races the resume): the window already passed, settle as kept.
        let pending = GruxUpdater.PendingWatch(
            proposalId: proposal.id,
            installedAt: Date().addingTimeInterval(-25 * 3600)
        )
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        Persistence.save(pending, to: stateDir.appendingPathComponent("pending-watch.json"))
        XCTAssertNotNil(updater.loadPendingWatch())

        updater.resumeWatchIfPending(now: Date())
        XCTAssertNil(updater.loadPendingWatch())
        XCTAssertEqual(trustLedger.entry(lane: .performance, domain: .mac).streak, 1)
    }

    func testResumeWatchRevertsWhenCrashLoopHidInsideExpiredWindow() throws {
        let updater = makeUpdater()
        updater.relauncher = { _ in }
        let proposal = fileVerifyingProposal()
        proposalStore.transition(id: proposal.id, to: .landed)

        // Known-good build archived, then the unproven build installed.
        try updater.archiveCurrentBuild()
        try writeAppPayload("unproven-build")

        let installedAt = Date().addingTimeInterval(-25 * 3600)
        // Two crashes 2 minutes apart right after install (staged through
        // the real heartbeat -> detect path so the crash log is authentic).
        updater.recordHeartbeat()
        XCTAssertTrue(updater.detectCrashAtLaunch(now: installedAt.addingTimeInterval(120)))
        updater.recordHeartbeat()
        XCTAssertTrue(updater.detectCrashAtLaunch(now: installedAt.addingTimeInterval(240)))

        let pending = GruxUpdater.PendingWatch(proposalId: proposal.id, installedAt: installedAt)
        Persistence.save(pending, to: stateDir.appendingPathComponent("pending-watch.json"))

        // Window elapsed while the Mac was off: the resume path must consult
        // the crash history and revert, not credit the build as kept.
        updater.resumeWatchIfPending(now: Date())

        XCTAssertEqual(appPayload(), "build-1", "archived known-good build restored")
        XCTAssertEqual(proposalStore.proposal(id: proposal.id)?.status, .rolledBack)
        let entry = trustLedger.entry(lane: .performance, domain: .mac)
        XCTAssertEqual(entry.streak, 0, "no promotion credit for a crash-looping build")
        XCTAssertEqual(entry.history.last?.outcome, .rolledBack)
        XCTAssertNil(updater.loadPendingWatch())
    }
}
