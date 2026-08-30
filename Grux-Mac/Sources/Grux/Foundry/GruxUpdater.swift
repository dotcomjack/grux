import Foundation
import AppKit

// Landing machinery for the Foundry (blueprint section 04, Phase C).
//
// GruxUpdater is the rollback keeper behind hard rail three: "Previous build
// kept; auto-rollback on crash or error rate regression." It
//   1. archives the current /Applications/Grux.app before any self-install
//      (versioned, keep the last 2),
//   2. drives the worktree's build.sh through a detached script so the
//      install survives build.sh quitting the running app,
//   3. verifies the codesign team identity did not change (a drifted
//      identity means the build came from somewhere it should not have,
//      so the script restores the archive instead of landing it),
//   4. watches the new build for 24h: a crash loop (2 crashes inside
//      10 minutes, detected via heartbeat + clean-shutdown markers) or an
//      error rate regression triggers auto-revert, marks the proposal
//      rolledBack, and demotes the (lane, domain) trust pair.
//
// NEVER auto-installs a protected proposal (wire protocol, Keychain,
// Security): selfInstall throws .protectedZone, at any trust tier. Those are
// landed by running build.sh by hand.
//
// Every root is injectable so tests stage archives and heartbeats in temp
// dirs and never touch the real /Applications path.

// MARK: - Errors

enum GruxUpdaterError: Error, Equatable {
    case protectedZone
    case appMissing(String)
    case archiveMissing
    case buildScriptMissing(String)
    // A previous install's 24h watch is still open: installing now would
    // drop that watch and archive the unproven build as the rollback
    // target. Carries the watched proposal's id.
    case watchInProgress(UUID)
    // The worktree did not build green at install time (swift build
    // exited non-zero). Refuse before archiving or transitioning, so a
    // red tree never overwrites the live app. Carries a short reason.
    case buildNotGreen(String)
    // Auto-land is paused after a crash loop tripped the breaker. A
    // human must clear it before any further self-install.
    case autoLandPaused
}

// MARK: - Error rate regression seam

// Error-rate delta vs the pre-install baseline: 0.0 means flat, 0.5 means
// errors up 50 percent. nil means no data yet. The stub keeps the
// auto-revert seam compiling and testable until a local probe reads the
// on-disk error counts.
protocol FoundryRegressionProbe: Sendable {
    func errorRateDelta(since installedAt: Date) async -> Double?
}

struct StubFoundryRegressionProbe: FoundryRegressionProbe {
    func errorRateDelta(since installedAt: Date) async -> Double? { nil }
}

// MARK: - GruxUpdater

@MainActor
final class GruxUpdater: ObservableObject {
    static let shared = GruxUpdater()

    // MARK: Tunables

    static let keepArchives = 2
    static let crashLoopCount = 2
    static let crashLoopWindow: TimeInterval = 600          // 10 minutes
    static let defaultWatchWindow: TimeInterval = 86_400    // 24 hours
    static let heartbeatInterval: TimeInterval = 30
    // Error rate up more than 25 percent vs baseline triggers revert.
    static let regressionThreshold = 0.25
    // Crash-loop circuit breaker: after this many consecutive crash-at-launch
    // events that are not cleared by a clean run, trip the breaker (auto-land
    // pauses until a human clears it). Distinct from crashLoopCount, which
    // governs the per-watch auto-revert window.
    static let breakerCrashThreshold = 2

    // MARK: Pending watch record (survives relaunch)

    struct PendingWatch: Codable, Equatable {
        var proposalId: UUID
        var installedAt: Date
        var windowSeconds: TimeInterval = GruxUpdater.defaultWatchWindow
    }

    // MARK: Roots (injectable; tests NEVER touch /Applications)

    let appURL: URL
    let archiveRoot: URL
    let stateDir: URL

    private var heartbeatURL: URL { stateDir.appendingPathComponent("heartbeat.json") }
    private var cleanShutdownURL: URL { stateDir.appendingPathComponent("clean-shutdown.json") }
    private var crashLogURL: URL { stateDir.appendingPathComponent("crashes.json") }
    private var pendingWatchURL: URL { stateDir.appendingPathComponent("pending-watch.json") }
    private var installScriptURL: URL { stateDir.appendingPathComponent("self-install.sh") }
    private var autoLandPausedURL: URL { stateDir.appendingPathComponent("auto-land-paused.json") }

    // MARK: Collaborators (injectable for tests)

    private let proposalStore: ProposalStore
    private let trustLedger: TrustLedger
    private let timeline: FoundryTimelineStore
    private let probe: FoundryRegressionProbe
    // Spawns the detached install script with its positional argv (paths are
    // never interpolated into the script body). Default launches /bin/bash
    // and does not wait: the script outlives the app when build.sh quits it.
    var installRunner: ((URL, [String]) throws -> Void)?
    // Relaunches after an in-process revert. Default opens the restored
    // bundle and terminates this (bad) build. Tests inject a no-op.
    var relauncher: ((URL) -> Void)?
    // Fires when a 24h watch settles, kept (true) or rolled back (false).
    // The engine hooks this to clean up the upgrade worktree: until the
    // watch settles the worktree must stay on disk (the detached install
    // script builds from it, and a revert wants forensics).
    var onWatchSettled: ((UUID, Bool) -> Void)?

    private var heartbeatTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?
    private var terminationObserver: NSObjectProtocol?

    init(
        appURL: URL = URL(fileURLWithPath: "/Applications/Grux.app"),
        archiveRoot: URL = FoundryPaths.dir.appendingPathComponent("previous-build", isDirectory: true),
        stateDir: URL = FoundryPaths.dir.appendingPathComponent("updater", isDirectory: true),
        proposalStore: ProposalStore? = nil,
        trustLedger: TrustLedger? = nil,
        timeline: FoundryTimelineStore? = nil,
        probe: FoundryRegressionProbe = StubFoundryRegressionProbe()
    ) {
        self.appURL = appURL
        self.archiveRoot = archiveRoot
        self.stateDir = stateDir
        self.proposalStore = proposalStore ?? .shared
        self.trustLedger = trustLedger ?? .shared
        self.timeline = timeline ?? .shared
        self.probe = probe
        try? FileManager.default.createDirectory(at: archiveRoot, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    }

    // MARK: - Activation (call once at app launch)

    // Detects a crash from the previous run, starts the heartbeat, and
    // resumes any in-flight 24h watch window across the relaunch.
    func activate(now: Date = Date()) {
        if detectCrashAtLaunch(now: now) {
            WakeLog.shared.log("foundry-updater: crash detected at launch")
            // Crash-loop breaker: once breakerCrashThreshold consecutive
            // crash-at-launch events land inside the crash-loop window, trip
            // the persisted pause AND restore the last-good build, then stop
            // re-attempting. This catches the case the per-watch auto-revert
            // misses: the RESTORED build itself crash-looping, or crashes that
            // accumulate after a watch already settled.
            if !isAutoLandPaused(),
               Self.isCrashLoop(
                   crashes: loadCrashes(),
                   since: now.addingTimeInterval(-Self.crashLoopWindow),
                   window: Self.crashLoopWindow,
                   count: Self.breakerCrashThreshold
               ) {
                let restored = (try? restorePreviousBuild()) != nil
                tripAutoLandPause(
                    reason: "\(Self.breakerCrashThreshold) crashes at launch inside \(Int(Self.crashLoopWindow / 60)) minutes; restored=\(restored).",
                    now: now
                )
                // Any open watch is moot once the breaker tripped: clear it so
                // the watch loop does not also fire a competing revert.
                clearPendingWatch()
                // The running process IS the bad build; relaunch into the
                // restored last-good bundle. Guarded against a relaunch storm:
                // the breaker only trips once (the next launch sees
                // isAutoLandPaused() true and skips this whole block).
                if restored {
                    let relaunch = relauncher ?? { url in
                        NSWorkspace.shared.open(url)
                        NSApplication.shared.terminate(nil)
                    }
                    relaunch(appURL)
                }
            }
        }
        startHeartbeat()
        resumeWatchIfPending(now: now)
    }

    // MARK: - Self-install

    // Archives the current build, then hands off to a detached script that
    // runs the worktree's build.sh (which builds, signs, installs to
    // /Applications, and relaunches), verifies the codesign team identity
    // is unchanged, and restores the archive on any failure. The 24h watch
    // resumes in the relaunched app via the pending-watch record.
    func selfInstall(
        fromWorktree worktree: URL,
        proposal: UpgradeProposal,
        alreadyVerifiedGreen: Bool = false
    ) throws {
        // Hard rail one: protected zones never auto-install, at any tier.
        guard proposal.riskClass != .protected else {
            timeline.append(FoundryTimelineEntry(
                kind: .rejected,
                title: "Auto-install refused: \(proposal.title)",
                detail: "Protected zone (wire protocol / Keychain / Security). Manual build.sh only.",
                lane: proposal.lane.displayName,
                domain: proposal.domain.displayName
            ))
            throw GruxUpdaterError.protectedZone
        }
        // Hard rail three guard: never stack a second install inside an
        // open watch window. Archiving here would snapshot the still
        // UNPROVEN current build as the rollback target, and overwriting
        // pending-watch.json would silently drop the prior build's watch
        // so it is never judged for crash loops or regressions.
        if let pending = loadPendingWatch(), pending.proposalId != proposal.id {
            timeline.append(FoundryTimelineEntry(
                kind: .rejected,
                title: "Install deferred: \(proposal.title)",
                detail: "A 24h watch is still open for a prior install. This install retries after that watch settles.",
                lane: proposal.lane.displayName,
                domain: proposal.domain.displayName
            ))
            throw GruxUpdaterError.watchInProgress(pending.proposalId)
        }
        // Breaker rail: a tripped crash-loop breaker pauses ALL self-installs
        // until a human clears it. Refuse before touching anything on disk.
        if isAutoLandPaused() {
            timeline.append(FoundryTimelineEntry(
                kind: .rejected,
                title: "Install refused: \(proposal.title)",
                detail: "Auto-land is paused after a crash loop. Clear the pause before Grux can self-install again.",
                lane: proposal.lane.displayName,
                domain: proposal.domain.displayName
            ))
            throw GruxUpdaterError.autoLandPaused
        }

        let buildScript = worktree.appendingPathComponent("build.sh")
        guard FileManager.default.fileExists(atPath: buildScript.path) else {
            throw GruxUpdaterError.buildScriptMissing(buildScript.path)
        }

        // Green-land gate: re-prove the worktree builds green RIGHT NOW,
        // before archiving, transitioning to .landed, or spawning the
        // detached installer. RDVerifier proved green at verify time, but the
        // tree can drift between verify and install (a relaunch, a sibling
        // edit), and selfInstall is reachable from the approval-after-relaunch
        // path with no fresh verify. A red tree here would overwrite the live
        // /Applications build and crash-loop, so we refuse and leave the
        // worktree untouched (the detached script never runs). The caller
        // (FoundryEngine.install) runs this off the main thread and passes
        // alreadyVerifiedGreen so the UI never freezes on the build; this
        // synchronous path stays as a fail-safe backstop for any other caller.
        if !alreadyVerifiedGreen {
            let green = verifyBuildsGreen(worktree: worktree)
            guard green.ok else {
                timeline.append(FoundryTimelineEntry(
                    kind: .rejected,
                    title: "Install refused: \(proposal.title)",
                    detail: "Worktree did not build green at install time: \(green.reason) Nothing was changed; re-propose to rebuild.",
                    lane: proposal.lane.displayName,
                    domain: proposal.domain.displayName
                ))
                throw GruxUpdaterError.buildNotGreen(green.reason)
            }
        }

        let expectedTeam = signingIdentity(of: appURL) ?? ""
        let archivedApp = try archiveCurrentBuild()

        // Persist the watch BEFORE spawning: build.sh quits this process,
        // and the relaunched build picks the watch up in activate().
        savePendingWatch(PendingWatch(proposalId: proposal.id, installedAt: Date()))

        let scriptArgs = Self.installScriptArguments(
            worktree: worktree,
            appPath: appURL.path,
            archivedAppPath: archivedApp.path,
            expectedTeamIdentifier: expectedTeam
        )
        try Self.installScriptTemplate.data(using: .utf8)?.write(to: installScriptURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: installScriptURL.path
        )

        proposalStore.transition(id: proposal.id, to: .landed)
        FoundryViewBridge.mirror(
            action: .landed,
            proposal: proposalStore.proposal(id: proposal.id) ?? proposal,
            detail: "Self-install kicked off from \(worktree.lastPathComponent). Previous build archived. 24h watch armed.",
            timeline: timeline
        )

        let runner = installRunner ?? Self.detachedScriptRunner
        try runner(installScriptURL, scriptArgs)
    }

    // The detached install script: build.sh does the build/sign/install/
    // relaunch; this wrapper adds identity verification and the revert
    // path. STATIC template: paths arrive as positional argv ($1..$4) and are
    // never interpolated into the script body, so worktree slugs derived from
    // harvested signal content cannot inject shell (security review 2026-06-10).
    nonisolated static let installScriptTemplate = """
    #!/bin/bash
    # Generated by GruxUpdater. Runs detached so it survives build.sh
    # quitting the Grux that spawned it.
    # argv: $1 worktree, $2 app path, $3 archived app path, $4 expected team id
    set -u
    WORKTREE="$1"; APP="$2"; ARCHIVE="$3"; EXPECTED="$4"
    revert() {
        rm -rf "$APP"
        cp -R "$ARCHIVE" "$APP"
        xattr -cr "$APP" 2>/dev/null
        open "$APP"
        exit 1
    }
    cd "$WORKTREE" || revert
    ./build.sh || revert
    ACTUAL=$(codesign -dvv "$APP" 2>&1 | awk -F= '/^TeamIdentifier=/{print $2}')
    if [ -n "$EXPECTED" ] && [ "$ACTUAL" != "$EXPECTED" ]; then
        revert
    fi
    exit 0
    """

    nonisolated static func installScriptArguments(
        worktree: URL,
        appPath: String,
        archivedAppPath: String,
        expectedTeamIdentifier: String
    ) -> [String] {
        [worktree.path, appPath, archivedAppPath, expectedTeamIdentifier]
    }

    nonisolated private static let detachedScriptRunner: (URL, [String]) throws -> Void = { script, args in
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path] + args
        // No waitUntilExit: the child is reparented when build.sh quits us.
        try p.run()
    }

    // MARK: - Green-land gate (build the worktree, do not install yet)

    // Runs `swift build -c release` in the worktree's Grux-Mac package and
    // returns whether it exited zero. Synchronous and bounded. A non-zero
    // exit, a spawn failure, or a missing package all read as not-green so a
    // half-baked tree can never land. nonisolated so FoundryEngine.install can
    // call it off the main thread (a multi-minute build must never run on
    // @MainActor or it freezes the UI).
    nonisolated func verifyBuildsGreen(
        worktree: URL,
        timeoutSeconds: TimeInterval = 1200
    ) -> (ok: Bool, reason: String) {
        let packageDir = worktree.appendingPathComponent("Grux-Mac", isDirectory: true)
        guard FileManager.default.fileExists(atPath: packageDir.appendingPathComponent("Package.swift").path) else {
            return (false, "no Package.swift under \(packageDir.lastPathComponent).")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["swift", "build", "-c", "release"]
        p.currentDirectoryURL = packageDir
        // Same OAuth-safe posture as the verifier: never let a build subprocess
        // pick up API billing env.
        var env = ProcessInfo.processInfo.environment
        for k in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN"] {
            env.removeValue(forKey: k)
        }
        p.environment = env
        let errPipe = Pipe()
        p.standardError = errPipe
        p.standardOutput = Pipe()
        do { try p.run() } catch {
            return (false, "could not start swift build: \(error.localizedDescription)")
        }
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while p.isRunning {
            if Date() > deadline {
                p.terminate()
                return (false, "swift build timed out after \(Int(timeoutSeconds))s.")
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        p.waitUntilExit()
        if p.terminationStatus == 0 { return (true, "swift build -c release succeeded.") }
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let tail = String(data: errData, encoding: .utf8).map { String($0.suffix(300)) } ?? ""
        return (false, "swift build exited \(p.terminationStatus). \(tail)")
    }

    // MARK: - Archive / restore (previous-build keeper)

    nonisolated private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    // Copies the current app into archiveRoot/<stamp>/Grux.app and prunes
    // to the newest keepArchives. Returns the archived bundle URL.
    @discardableResult
    func archiveCurrentBuild(now: Date = Date()) throws -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: appURL.path) else {
            throw GruxUpdaterError.appMissing(appURL.path)
        }
        let stamp = Self.stampFormatter.string(from: now)
        let slot = archiveRoot.appendingPathComponent(stamp, isDirectory: true)
        let dest = slot.appendingPathComponent(appURL.lastPathComponent)
        try? fm.removeItem(at: slot)
        try fm.createDirectory(at: slot, withIntermediateDirectories: true)
        try fm.copyItem(at: appURL, to: dest)
        pruneArchives()
        return dest
    }

    // Newest-first archive slots; lexicographic sort works because the
    // stamp is yyyyMMdd-HHmmss.
    func archiveSlots() -> [URL] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: archiveRoot.path)) ?? []
        return names
            .filter { !$0.hasPrefix(".") }
            .sorted(by: >)
            .map { archiveRoot.appendingPathComponent($0, isDirectory: true) }
    }

    private func pruneArchives() {
        let slots = archiveSlots()
        guard slots.count > Self.keepArchives else { return }
        for stale in slots.dropFirst(Self.keepArchives) {
            try? FileManager.default.removeItem(at: stale)
        }
    }

    func latestArchivedApp() -> URL? {
        for slot in archiveSlots() {
            let app = slot.appendingPathComponent(appURL.lastPathComponent)
            if FileManager.default.fileExists(atPath: app.path) { return app }
        }
        return nil
    }

    // Restores the newest archived build over the current app.
    @discardableResult
    func restorePreviousBuild() throws -> URL {
        guard let archived = latestArchivedApp() else {
            throw GruxUpdaterError.archiveMissing
        }
        let fm = FileManager.default
        try? fm.removeItem(at: appURL)
        try fm.createDirectory(
            at: appURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try fm.copyItem(at: archived, to: appURL)
        return appURL
    }

    // MARK: - Codesign identity

    // TeamIdentifier from `codesign -dvv`. nil when unsigned or missing.
    nonisolated func signingIdentity(of app: URL) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        p.arguments = ["-dvv", app.path]
        let pipe = Pipe()
        p.standardError = pipe   // codesign prints details to stderr
        p.standardOutput = Pipe()
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let out = String(data: data, encoding: .utf8) else { return nil }
        return Self.parseTeamIdentifier(fromCodesignOutput: out)
    }

    nonisolated static func parseTeamIdentifier(fromCodesignOutput output: String) -> String? {
        for line in output.split(separator: "\n") {
            if line.hasPrefix("TeamIdentifier=") {
                let value = String(line.dropFirst("TeamIdentifier=".count))
                    .trimmingCharacters(in: .whitespaces)
                return (value.isEmpty || value == "not set") ? nil : value
            }
        }
        return nil
    }

    // MARK: - Crash detection (heartbeat + clean-shutdown markers)

    private struct Stamp: Codable { var at: Date }

    private func startHeartbeat() {
        // Clear the previous run's markers so this run starts clean.
        try? FileManager.default.removeItem(at: cleanShutdownURL)
        recordHeartbeat()
        heartbeatTask?.cancel()
        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.heartbeatInterval * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                self.recordHeartbeat()
            }
        }
        // NSApplication termination marker: a clean quit writes the marker,
        // so a heartbeat without one means the process died hard.
        if terminationObserver == nil {
            terminationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.writeStamp(to: self.cleanShutdownURL)
            }
        }
    }

    private func writeStamp(to url: URL) {
        if let data = try? JSONEncoder().encode(Stamp(at: Date())) {
            try? data.write(to: url, options: .atomic)
        }
    }

    // One heartbeat stamp. The loop above calls this every 30s; tests call
    // it directly to stage a crashed-previous-run scenario.
    func recordHeartbeat() {
        writeStamp(to: heartbeatURL)
    }

    // Marker for tests and for clean-quit paths that bypass NSApplication.
    func markCleanShutdown() {
        writeStamp(to: cleanShutdownURL)
    }

    // True when the previous run left a heartbeat with no clean-shutdown
    // marker after it: that is a crash. Appends to the crash log.
    @discardableResult
    func detectCrashAtLaunch(now: Date = Date()) -> Bool {
        let dec = JSONDecoder()
        guard let hbData = try? Data(contentsOf: heartbeatURL),
              let hb = try? dec.decode(Stamp.self, from: hbData) else { return false }
        if let cleanData = try? Data(contentsOf: cleanShutdownURL),
           let clean = try? dec.decode(Stamp.self, from: cleanData),
           clean.at >= hb.at {
            return false    // clean quit after the last heartbeat
        }
        var crashes = loadCrashes()
        crashes.append(now)
        saveCrashes(crashes)
        try? FileManager.default.removeItem(at: heartbeatURL)
        return true
    }

    func loadCrashes() -> [Date] {
        Persistence.load([Date].self, from: crashLogURL, fallback: [])
    }

    private func saveCrashes(_ crashes: [Date]) {
        Persistence.save(crashes.suffix(20), to: crashLogURL)
    }

    // Pure crash-loop math: true when `count` crashes land inside `window`
    // seconds of each other (default 2 inside 10 minutes), considering only
    // crashes at or after `since`.
    nonisolated static func isCrashLoop(
        crashes: [Date],
        since: Date,
        window: TimeInterval = GruxUpdater.crashLoopWindow,
        count: Int = GruxUpdater.crashLoopCount
    ) -> Bool {
        let relevant = crashes.filter { $0 >= since }.sorted()
        guard relevant.count >= count, count >= 2 else {
            return count <= 1 && !relevant.isEmpty
        }
        for i in 0...(relevant.count - count) {
            if relevant[i + count - 1].timeIntervalSince(relevant[i]) <= window {
                return true
            }
        }
        return false
    }

    // MARK: - 24h watch

    // Watches the freshly installed build. A crash loop or an error rate
    // regression auto-reverts; surviving the window records
    // acceptedAndKept on the trust ledger (which can promote the pair).
    func watch(
        for window: TimeInterval = GruxUpdater.defaultWatchWindow,
        proposalId: UUID,
        installedAt: Date = Date(),
        checkInterval: TimeInterval = 60
    ) {
        savePendingWatch(PendingWatch(
            proposalId: proposalId, installedAt: installedAt, windowSeconds: window
        ))
        watchTask?.cancel()
        watchTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if Date().timeIntervalSince(installedAt) >= window {
                    self.markKept(proposalId: proposalId)
                    return
                }
                if Self.isCrashLoop(crashes: self.loadCrashes(), since: installedAt) {
                    self.autoRevert(proposalId: proposalId, reason: "crash loop: \(Self.crashLoopCount) crashes inside \(Int(Self.crashLoopWindow / 60)) minutes")
                    return
                }
                if let delta = await self.probe.errorRateDelta(since: installedAt),
                   delta > Self.regressionThreshold {
                    self.autoRevert(proposalId: proposalId, reason: String(format: "error rate regression: up %.0f%%", delta * 100))
                    return
                }
                try? await Task.sleep(nanoseconds: UInt64(checkInterval * 1_000_000_000))
            }
        }
    }

    // Resumes (or settles) a watch that was armed before a relaunch.
    func resumeWatchIfPending(now: Date = Date()) {
        guard let pending = loadPendingWatch() else { return }
        let elapsed = now.timeIntervalSince(pending.installedAt)
        if elapsed >= pending.windowSeconds {
            // The live watch loop was down for some or all of the window
            // (Mac asleep or off). Run the same crash-loop gate the loop
            // runs before crediting kept: a build that crash-looped inside
            // the window must revert, never feed the promotion streak.
            if Self.isCrashLoop(crashes: loadCrashes(), since: pending.installedAt) {
                autoRevert(
                    proposalId: pending.proposalId,
                    reason: "crash loop during the watch window (settled at relaunch)"
                )
            } else {
                markKept(proposalId: pending.proposalId)
            }
        } else {
            watch(
                for: pending.windowSeconds,
                proposalId: pending.proposalId,
                installedAt: pending.installedAt
            )
        }
    }

    // MARK: - Watch outcomes

    // Survived the window: the change is kept. Ledger accepted-and-kept
    // (five in a row promotes the pair; the promotion audit rides
    // FoundryTrustTransitions).
    func markKept(proposalId: UUID) {
        clearPendingWatch()
        resetCrashRun()   // a kept build resets the consecutive-crash run
        watchTask?.cancel(); watchTask = nil
        defer { onWatchSettled?(proposalId, true) }
        guard let proposal = proposalStore.proposal(id: proposalId) else { return }
        FoundryTrustTransitions.recordKept(
            proposal: proposal, ledger: trustLedger, timeline: timeline
        )
        timeline.append(FoundryTimelineEntry(
            kind: .landed,
            title: "Kept: \(proposal.title)",
            detail: "Survived the 24h watch window. No crash loop, no error rate regression.",
            lane: proposal.lane.displayName,
            domain: proposal.domain.displayName
        ))
    }

    // Crash loop or error rate regression: restore the archived build,
    // relaunch it, mark the proposal rolledBack, demote the trust pair.
    func autoRevert(proposalId: UUID, reason: String) {
        clearPendingWatch()
        watchTask?.cancel(); watchTask = nil
        onWatchSettled?(proposalId, false)

        let restored = (try? restorePreviousBuild()) != nil
        WakeLog.shared.log("foundry-updater: auto-revert (\(reason)) restored=\(restored)")

        if let updated = proposalStore.transition(id: proposalId, to: .rolledBack) {
            FoundryTrustTransitions.recordRollback(
                proposal: updated, ledger: trustLedger, timeline: timeline
            )
            FoundryViewBridge.mirror(
                action: .rolledBack,
                proposal: updated,
                detail: "Auto-revert: \(reason). Previous build restored.",
                timeline: timeline
            )
        }

        guard restored else { return }
        let relaunch = relauncher ?? { url in
            NSWorkspace.shared.open(url)
            NSApplication.shared.terminate(nil)
        }
        relaunch(appURL)
    }

    // MARK: - Pending watch persistence

    private func savePendingWatch(_ pending: PendingWatch) {
        Persistence.save(pending, to: pendingWatchURL)
    }

    func loadPendingWatch() -> PendingWatch? {
        Persistence.load(PendingWatch?.self, from: pendingWatchURL, fallback: nil)
    }

    func clearPendingWatch() {
        try? FileManager.default.removeItem(at: pendingWatchURL)
    }

    // MARK: - Auto-land paused breaker (survives relaunch)

    private struct BreakerState: Codable, Equatable {
        var paused: Bool = false
        var trippedAt: Date?
        var reason: String = ""
    }

    // True when the crash-loop breaker has tripped. The governor checks this
    // before scheduling, and selfInstall refuses while it is set.
    func isAutoLandPaused() -> Bool {
        Persistence.load(BreakerState.self, from: autoLandPausedURL, fallback: BreakerState()).paused
    }

    // Trips the breaker: auto-land pauses until cleared. Idempotent.
    func tripAutoLandPause(reason: String, now: Date = Date()) {
        guard !isAutoLandPaused() else { return }
        Persistence.save(BreakerState(paused: true, trippedAt: now, reason: reason), to: autoLandPausedURL)
        WakeLog.shared.log("foundry-updater: auto-land PAUSED (\(reason))")
        timeline.append(FoundryTimelineEntry(
            kind: .rollback,
            title: "Auto-land paused (crash-loop breaker)",
            detail: "\(reason) Restored the last-good build. Self-install stays paused until a human clears it."
        ))
    }

    // Human clears the breaker (a Self-Upgrade tab control or CLI trigger
    // calls this). Self-install and the governor resume on the next tick.
    func clearAutoLandPause() {
        try? FileManager.default.removeItem(at: autoLandPausedURL)
        WakeLog.shared.log("foundry-updater: auto-land pause cleared")
    }

    // A kept build resets the consecutive-crash run so the breaker measures
    // crashes-since-last-good rather than lifetime crashes.
    private func resetCrashRun() {
        saveCrashes([])
    }
}
