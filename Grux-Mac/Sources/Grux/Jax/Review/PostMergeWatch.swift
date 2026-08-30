import Foundation

// PostMergeWatch: the safety net AFTER a feature reaches main. The in-app gate
// and the merge script's test+build gates vet a feature before it lands, but no
// pre-merge check is perfect, so a landed feature is watched for a window. If
// the app crash-loops while a fresh feature is live, that feature is the prime
// suspect: PostMergeWatch writes a rollback intent + notifies, and (best effort)
// invokes the GUARDED tools/rollback-feature.sh, which git-reverts the commit
// behind a build-green gate. As everywhere else, the app never runs git mutation
// logic itself; it only triggers the guarded script.
//
// Crash signal (deliberately simple + robust, not a second Foundry engine): a
// session-open flag file is written on launch and removed on clean terminate. If
// it is still present at the next launch, the previous session did not exit
// cleanly (a hard crash / SIGKILL; a normal Cmd-Q fires willTerminate and clears
// it, so it does not false-positive). Two such crashes inside the crash window
// while a feature is in-watch trip the rollback, mirroring Foundry's 2-in-10min
// breaker. A single non-clean exit (one OS kill, one power loss) never reverts.
//
// Watches are armed by tools/implement-feature.sh appending to the watch file on
// a successful land, so arming survives the app being closed during the merge.

@MainActor
final class PostMergeWatch: ObservableObject {
    static let shared = PostMergeWatch()

    struct Watch: Codable, Identifiable {
        var id: String { sha }
        let sha: String
        let title: String
        let mergedAt: Date
        var windowHours: Double
        var crashes: [Date]
        var settled: Bool          // window passed cleanly, or rollback concluded
        var rolledBack: Bool       // reconciled from git: the commit is gone from main
        var rollbackRequested: Bool? // we invoked the guarded revert; awaiting git reconcile
    }

    @Published private(set) var watches: [Watch] = []

    private let jaxDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".grux/jax", isDirectory: true)
    private var storeURL: URL { jaxDir.appendingPathComponent("post-merge-watch.json") }
    private var sessionFlagURL: URL { jaxDir.appendingPathComponent("post-merge-session.flag") }
    private var rollbackIntentURL: URL { jaxDir.appendingPathComponent("rollback-intent.json") }
    // The live build tree Grux is built and installed from, read from
    // ~/.grux/live-worktree.txt. The old comment here said "home-relative, so it
    // follows whoever is running Grux", which was true of the USER half and
    // missed the half that mattered: it still hardcoded one person's REPO
    // LAYOUT, and that string shipped inside a public binary. Empty when
    // unconfigured, which disarms the rollback path rather than pointing it at
    // a directory that does not exist.
    // nonisolated: the class is @MainActor, but commitIsOnMain() is nonisolated
    // and shells out to git with this path. A stored `let` inherited no
    // isolation, so turning it into a computed property quietly made it
    // MainActor-only and broke that call site at compile time.
    nonisolated private static var liveTreeRoot: String { Persistence.liveWorktreeRoot?.path ?? "" }
    nonisolated private var rollbackScript: String {
        let root = PostMergeWatch.liveTreeRoot
        return root.isEmpty ? "" : root + "/Grux-Mac/tools/rollback-feature.sh"
    }

    private let crashWindow: TimeInterval = 600     // 10 min
    private let crashThreshold = 2                  // 2 non-clean exits in the window

    private init() {}

    // Boot once from GruxApp.applicationDidFinishLaunching. Detects whether the
    // last session crashed, attributes it to the freshest in-watch feature, trips
    // a rollback on a crash-loop, then arms the session flag for this run.
    func activate() {
        try? FileManager.default.createDirectory(at: jaxDir, withIntermediateDirectories: true)
        watches = Persistence.load([Watch].self, from: storeURL, fallback: [])
        let crashed = FileManager.default.fileExists(atPath: sessionFlagURL.path)
        // Arm this session's flag (removed on clean terminate).
        FileManager.default.createFile(atPath: sessionFlagURL.path, contents: Data())

        reconcileRollbacks()
        pruneAndSettle()
        if crashed { handleCrash() }
        save()
    }

    // Make rolledBack reflect git REALITY, not optimism: for any watch where we
    // invoked the guarded revert, mark it rolledBack only once the commit is
    // actually gone from main. If the revert failed (conflict / red build), the
    // commit is still an ancestor, so rolledBack stays false and we re-surface it.
    private func reconcileRollbacks() {
        for i in watches.indices where (watches[i].rollbackRequested ?? false) && !watches[i].rolledBack {
            if !commitIsOnMain(watches[i].sha) {
                watches[i].rolledBack = true
                watches[i].settled = true
                WakeLog.shared.log("postMergeWatch: confirmed \(watches[i].sha.prefix(8)) was reverted off main.")
            } else {
                WakeLog.shared.log("postMergeWatch: rollback of \(watches[i].sha.prefix(8)) did not complete (still on main); manual attention may be needed.")
            }
        }
    }

    // Called from applicationWillTerminate: a clean exit clears the flag so the
    // next launch does not read it as a crash.
    func markCleanExit() {
        try? FileManager.default.removeItem(at: sessionFlagURL)
    }

    // Settle any watch whose window has elapsed without a rollback (kept), and
    // drop watches that are already settled + old so the list stays the live arc.
    private func pruneAndSettle() {
        let now = Date()
        for i in watches.indices where !watches[i].settled {
            if now.timeIntervalSince(watches[i].mergedAt) > watches[i].windowHours * 3600 {
                watches[i].settled = true
                WakeLog.shared.log("postMergeWatch: \(watches[i].sha.prefix(8)) survived its watch window, kept.")
            }
        }
        // keep the 20 most recent for visibility
        watches = Array(watches.sorted { $0.mergedAt > $1.mergedAt }.prefix(20))
    }

    // A non-clean exit happened. Attribute it to the NEWEST active (in-window,
    // not settled) watch (the likeliest culprit), and roll back if it crosses
    // the threshold. Attributing to one feature avoids reverting several at once.
    private func handleCrash() {
        let now = Date()
        guard let idx = watches.firstIndex(where: { !$0.settled && now.timeIntervalSince($0.mergedAt) <= $0.windowHours * 3600 }) else {
            WakeLog.shared.log("postMergeWatch: non-clean exit detected, but no feature is in-watch. No action.")
            return
        }
        // CAUSAL CONFIRMATION: the session flag alone fires for ANY non-clean
        // exit (power loss, force-quit, OS/OOM kill, an unrelated subsystem
        // crash). Auto-reverting a good feature off that blind signal is exactly
        // the kind of mess we must not make. So only count this as a
        // feature-implicating crash if a real Grux crash report actually landed
        // recently. Power loss / force-quit produce NO Grux crash report, so they
        // never accumulate toward a revert.
        guard hasRecentGruxCrashReport(within: 3600) else {
            WakeLog.shared.log("postMergeWatch: non-clean exit with no corroborating Grux crash report; treating as non-causal (power loss / force-quit / OS kill). Not attributing to any feature.")
            return
        }
        watches[idx].crashes.append(now)
        let recent = watches[idx].crashes.filter { now.timeIntervalSince($0) <= crashWindow }
        let w = watches[idx]
        WakeLog.shared.log("postMergeWatch: confirmed Grux crash attributed to \(w.sha.prefix(8)) \"\(w.title)\" (\(recent.count)/\(crashThreshold) in window).")
        if recent.count >= crashThreshold {
            tripRollback(at: idx)
        } else {
            NotificationManager.shared.route(.system, actionRequired: false, TriageEnvelope(
                identifier: "grux.postmerge.crash.\(w.sha.prefix(8))",
                title: "Grux: crash after a fresh merge",
                body: "\(w.title) is in its post-merge watch. One more confirmed crash will roll it back."))
        }
    }

    // True if a Grux crash report (.ips / .crash) landed in DiagnosticReports
    // within the window. This is the causal evidence that Grux itself crashed,
    // as opposed to a power loss or a force-quit that leaves no report.
    private func hasRecentGruxCrashReport(within seconds: TimeInterval) -> Bool {
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return false }
        let cutoff = Date().addingTimeInterval(-seconds)
        for url in items {
            let name = url.lastPathComponent
            let ext = url.pathExtension.lowercased()
            guard name.hasPrefix("Grux"), ext == "ips" || ext == "crash" else { continue }
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let mtime, mtime >= cutoff { return true }
        }
        return false
    }

    nonisolated private func commitIsOnMain(_ sha: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", Self.liveTreeRoot, "merge-base", "--is-ancestor", sha, "HEAD"]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        do { try p.run() } catch { return true }  // unknown -> assume still present (do not falsely claim reverted)
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    private func tripRollback(at idx: Int) {
        var w = watches[idx]
        w.settled = true
        w.rollbackRequested = true   // rolledBack is set later, only once git confirms the revert
        watches[idx] = w
        let intent: [String: Any] = [
            "sha": w.sha, "title": w.title,
            "reason": "crash loop within post-merge watch (\(crashThreshold) non-clean exits in \(Int(crashWindow/60)) min)",
            "trippedAt": ISO8601DateFormatter().string(from: Date())]
        if let data = try? JSONSerialization.data(withJSONObject: intent, options: [.prettyPrinted]) {
            try? Persistence.write(data, to: rollbackIntentURL)
        }
        WakeLog.shared.log("postMergeWatch: TRIPPED rollback for \(w.sha.prefix(8)). Wrote rollback-intent; invoking guarded rollback-feature.sh.")
        NotificationManager.shared.route(.system, actionRequired: true, TriageEnvelope(
            identifier: "grux.postmerge.rollback.\(w.sha.prefix(8))",
            title: "Grux: rolling back a crashing feature",
            body: "\(w.title) crash-looped after merge. Reverting it off main behind a build gate. Run build.sh to reinstall the reverted build."))
        invokeGuardedRollback(sha: w.sha)
    }

    // Run the GUARDED rollback script out-of-process. The script itself reverts
    // behind a build-green gate and aborts on any failure, so even an automatic
    // invocation cannot leave main broken. Best-effort: a failure to launch is
    // logged; the intent file remains for a manual run.
    private func invokeGuardedRollback(sha: String) {
        guard FileManager.default.isExecutableFile(atPath: rollbackScript) else {
            WakeLog.shared.log("postMergeWatch: rollback script not executable at \(rollbackScript); leaving intent for manual run.")
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [rollbackScript, sha]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        do { try p.run() } catch {
            WakeLog.shared.log("postMergeWatch: failed to launch rollback script: \(error.localizedDescription)")
        }
    }

    private func save() { Persistence.save(watches, to: storeURL) }
}
