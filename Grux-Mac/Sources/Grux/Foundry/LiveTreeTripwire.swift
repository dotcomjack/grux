import Foundation
import AppKit

// LiveTreeTripwire: catches the autonomous-drop signature (UNTRACKED files
// appearing under the LIVE build worktree's Sources/) and quarantines them.
//
// Background: swarm workers run `claude ... --permission-mode bypassPermissions`
// with full user FS access (SwarmWorker.swift). Confinement (sandbox-exec) is
// the primary defense; this tripwire is the backstop that catches a slip past
// it automatically, before Foundry can relaunch onto a broken tree.
//
// DETECTOR ONLY. It logs and notifies; it moves nothing and deletes nothing.
// This header used to say it MOVES strays to a quarantine folder, which the
// implementation has not done for some time (see the comment in sweep(), which
// explains that auto-quarantining once ate this very file mid-commit). A stale
// comment claiming a destructive behaviour is worse than no comment, because
// the next reader budgets risk against a thing that does not happen.
//
// The live worktree path is READ FROM CONFIG and has no default, so on a
// machine that has not opted in this whole subsystem is inert.
@MainActor
final class LiveTreeTripwire {
    static let shared = LiveTreeTripwire()

    // The LIVE build/install worktree (the running app is built from here).
    // A stray UNTRACKED file under its Sources/ is the drop signature.
    // nil when ~/.grux/live-worktree.txt is absent, which is every machine
    // except the one whose author uses the Foundry upgrade loop.
    private var liveWorktree: URL? { Persistence.liveWorktreeRoot }
    private var quarantineRoot: URL { Persistence.quarantineDir }

    private var timer: Task<Void, Never>?
    private let sweepInterval: TimeInterval = 300  // 5 minutes

    // Notification dedupe (per launch). The sweep runs every 5 minutes, but an
    // untracked file a human is legitimately editing sits there for hours; the
    // original code re-notified the IDENTICAL set every tick forever (the
    // SocialView.swift warning that repeated in the logs). We remember the last
    // set we alerted on and only route a fresh notification when the SET
    // CHANGES; an unchanged set demotes to at most one quiet log line per hour.
    private var lastNotifiedSet: Set<String> = []
    private var lastUnchangedLogAt: Date = .distantPast
    private let unchangedLogInterval: TimeInterval = 3600  // 1 hour

    private static let stampFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    // Boot once from GruxApp.applicationDidFinishLaunching. Sweeps now, then
    // on a timer. Idempotent.
    func activate() {
        sweep()
        timer?.cancel()
        timer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64((self?.sweepInterval ?? 300) * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                self.sweep()
            }
        }
    }

    // One sweep: list untracked files under Sources/ of the live worktree and
    // quarantine each one.
    func sweep() {
        guard let liveWorktree, FileManager.default.fileExists(atPath: liveWorktree.path) else { return }
        let strays = untrackedSourcesFiles()

        // Healthy state: nothing under the live Sources tree. Forget the last
        // alerted set so a LATER reappearance of the same files reads as a fresh
        // drop worth notifying, not a silenced repeat.
        guard !strays.isEmpty else {
            lastNotifiedSet = []
            return
        }

        // Dedupe against the last set we alerted on. An unchanged set is almost
        // always a human's ongoing WIP; re-notifying every 5 minutes is noise.
        // Log it at most once an hour and route no notification until the set
        // actually changes.
        let straySet = Set(strays)
        if straySet == lastNotifiedSet {
            let now = Date()
            if now.timeIntervalSince(lastUnchangedLogAt) >= unchangedLogInterval {
                lastUnchangedLogAt = now
                WakeLog.shared.log("LIVE-TREE TRIPWIRE: \(strays.count) untracked file(s) unchanged since last alert. Staying quiet until the set changes.")
            }
            return
        }
        lastNotifiedSet = straySet
        lastUnchangedLogAt = .distantPast

        // ALERT ONLY. We deliberately do NOT auto-move strays. Untracked files
        // under Sources/ are usually a developer's legitimate work in progress,
        // and auto-quarantining those destroys real work (it once ate this very
        // file mid-commit). The actual prevention is the sandbox confinement on
        // swarm workers (an agent physically cannot write into this tree); this
        // tripwire is only a DETECTOR. It logs + notifies so a human decides
        // whether the strays are an autonomous drop worth quarantining.
        let stamp = Self.stampFmt.string(from: Date())
        let listed = strays.prefix(20).joined(separator: ", ")
        let more = strays.count > 20 ? " (+\(strays.count - 20) more)" : ""
        WakeLog.shared.log("LIVE-TREE TRIPWIRE: \(strays.count) untracked file(s) under the live Grux Sources tree. If an agent dropped these (not your own WIP), move them to \(quarantineRoot.path). Files: \(listed)\(more)")
        NotificationManager.shared.route(.system, actionRequired: false, TriageEnvelope(
            identifier: "grux.tripwire.\(stamp)",
            title: "Grux: untracked files in live Sources",
            body: "\(strays.count) untracked file(s) under Sources/. Review whether an agent dropped them."
        ))
    }

    // The Swift package does NOT sit at the worktree root: the package lives at
    // <root>/Grux-Mac/, so every source file's path relative to the worktree
    // root begins with "Grux-Mac/Sources/". Matching a bare "Sources/" prefix
    // (the original bug) never fired because no <root>/Sources directory
    // exists. This is the prefix the drop signature actually uses.
    nonisolated static let sourcesPrefix = "Grux-Mac/Sources/"

    // Pure predicate: does this worktree-root-relative path sit under the
    // package source tree? Extracted so it is unit-testable without invoking
    // git against the real live worktree. nonisolated: it touches no actor
    // state, so the test suite (and any nonisolated caller) can run it without
    // hopping to the main actor.
    nonisolated static func isSourceDrop(_ rel: String) -> Bool {
        rel == sourcesPrefix || rel.hasPrefix(sourcesPrefix)
    }

    // `git status --porcelain` over the live worktree, return relative paths of
    // UNTRACKED ("??") entries under Grux-Mac/Sources/. Untracked is the
    // autonomous-drop signature: an agent that wrote NEW files into the tree.
    private func untrackedSourcesFiles() -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        guard let liveWorktree else { return [] }
        p.arguments = ["-C", liveWorktree.path, "status", "--porcelain", "--untracked-files=all"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else { return [] }
        var result: [String] = []
        for line in text.split(separator: "\n") {
            // Porcelain v1: "XY <path>". Untracked is "?? <path>".
            guard line.hasPrefix("?? ") else { continue }
            let rel = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            // git quotes paths with odd chars; skip quoted (rare) to stay safe.
            guard !rel.hasPrefix("\"") else { continue }
            if Self.isSourceDrop(rel) {
                result.append(rel)
            }
        }
        return result
    }
}
