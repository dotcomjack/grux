import ArgumentParser
import Foundation
import GruxSetupCore
import GruxShellCore

// MARK: - grux undo

/// Put a folder back the way it was before Grux touched it.
///
/// The one command here that can destroy work, and the only one that can undo a mistake Grux
/// made on somebody's machine. Both halves of that matter, so it is deliberately asymmetric:
/// LISTING is free and works with Grux closed, RESTORING needs the app, needs a snapshot
/// named explicitly, and needs a yes.
///
/// It never touches the real repository. The snapshots live in a parallel git directory with
/// the folder as its work tree, so a restore rewrites files and leaves the user's own `.git`,
/// their branch, their reflog and any half-finished rebase exactly where they were.
struct Undo: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "undo",
        abstract: "Put a folder back to a snapshot Grux took before it changed something.",
        discussion: """
            Run with no arguments to see what can be undone. Nothing is restored until you \
            name a snapshot, and naming one still asks first.

            This discards every change made after that snapshot, including anything you did \
            by hand in the same folder. Your own git repository is never touched.
            """)

    @Argument(help: "A snapshot id from the list. Leave it out to see the list.")
    var snapshot: String?

    @Flag(name: .long, help: "Show the list and do nothing else.")
    var list = false

    @Flag(name: .long, help: "Do not ask. For a script that has already asked.")
    var yes = false

    @Flag(name: .long, help: "Machine readable.")
    var json = false

    /// Accepted by every command, and it means one thing on all of
    /// them. See InputPolicy.
    @OptionGroup var input: InputPolicy

    func run() throws {
        let frame = Frame()
        let r = frame.renderer

        // Reading is done straight off disk, so it works with Grux closed. That is the whole
        // reason a shadow repository records its own work tree: without it the snapshots on
        // disk are just commits nothing can place.
        let sessions = runBlocking { await ShellSnapshotIndex.sessions() }

        if json {
            let out = sessions.map { s -> [String: Any] in
                ["session_id": s.sessionId, "root_dir": s.rootDir ?? "",
                 "restorable": s.isRestorable,
                 "snapshots": s.snapshots.map { ["id": $0.snapshotId, "label": $0.label,
                                                 "trigger": $0.trigger] }]
            }
            if let d = try? JSONSerialization.data(withJSONObject: out,
                                                   options: [.prettyPrinted, .sortedKeys]),
               let t = String(data: d, encoding: .utf8) { print(t) }
            leave(.done)
        }

        guard let wanted = snapshot, !list else {
            show(sessions, frame: frame)
            leave(.done)
        }

        guard let hit = sessions.lazy
            .compactMap({ s in s.snapshots.first { $0.snapshotId == wanted }.map { (s, $0) } })
            .first else {
            frame.open(.look)
            print(r.prose("No snapshot called \(wanted)."))
            print("")
            print(r.style.ink(.dim, r.prose("Run grux undo to see what there is.", indent: 2)))
            leave(.failed)
        }
        let (session, record) = hit

        guard let root = session.rootDir else {
            frame.open(.look)
            print(r.prose("That snapshot's repository does not record which folder it "
                          + "belongs to, so there is nothing safe to restore."))
            leave(.failed)
        }
        guard FileManager.default.fileExists(atPath: root) else {
            frame.open(.look)
            print(r.prose("The folder that snapshot belongs to is gone."))
            print("")
            print(r.row(state: .needed, label: "Missing", detail: root, labelWidth: 10))
            leave(.waitingOnYou)
        }

        // ---- what this will do, before asking -------------------------------------------
        frame.open(.cost, "This is what would change, and it cannot be undone again.")
        print(r.row(state: .satisfied, label: "Folder", detail: root, labelWidth: 12))
        print(r.row(state: .satisfied, label: "Back to", detail: record.snapshotId,
                    labelWidth: 12))
        print(r.row(state: .satisfied, label: "Taken", detail: stamp(record.createdAt),
                    labelWidth: 12))
        print("")
        print(r.prose(record.label, indent: 4))
        print("")
        print(r.style.ink(.attention, r.prose(
            "Every change made in that folder since then is discarded, including anything "
            + "you did by hand. Your own git repository, your branch and your reflog are not "
            + "touched.", indent: 2)))

        if !yes {
            guard input.canAsk else {
                print("")
                print(r.prose("Nothing is attached to this terminal, so there is nobody to "
                              + "ask. Pass --yes if you are sure."))
                leave(.failed)
            }
            // TYPED, not a keystroke. `y` is muscle memory; typing the id is a decision, and
            // this is the one command that throws work away.
            //
            // THROUGH `input.ask`, so the question reaches the person and not a redirect.
            let typed = InputPolicy.ask([
                "",
                "  Type the snapshot id to confirm, or anything else to stop.",
                "  " + r.style.ink(.accent, record.snapshotId),
                "",
            ])
            guard typed == record.snapshotId else {
                print("")
                print(r.prose("Left everything alone."))
                leave(.done)
            }
        }

        // ---- the write, through the app --------------------------------------------------
        let client = ControlClient()
        guard client.isAvailable else {
            print("")
            print(r.prose("Grux is not running, and restoring goes through the app so a live "
                          + "session cannot be rolled back behind its own back. Open Grux and "
                          + "run this again."))
            leave(.waitingOnYou)
        }

        frame.open(.prove)
        switch client.call(tool: "grux_shell_undo", arguments: ["snapshot_id": wanted]) {
        case .failure(let e):
            // A REFUSAL ARRIVES HERE, NOT ON THE SUCCESS PATH. The app returns "Could not
            // undo" and "No snapshot called" through MCPWire.textFailure, which the client
            // surfaces as .toolFailed. The success branch below used to test for those two
            // strings and could never see them: it was dead code sitting under a message
            // that blamed the connection for the app's answer.
            print(r.prose(frame.explain(e)))
            leave(.failed)
        case .success(let text):
            let changed = (try? JSONSerialization.jsonObject(with: Data(text.utf8)))
                .flatMap { ($0 as? [String: Any])?["changed"] as? [String] } ?? []
            print(r.row(state: .satisfied, label: "Restored", detail: record.snapshotId,
                        labelWidth: 12))
            print("")
            if changed.isEmpty {
                // A REAL ANSWER, not an empty list. Nothing had changed since the snapshot,
                // so the undo was a no-op, and saying "0 files" invites somebody to run it
                // again thinking it failed.
                print(r.prose("Nothing had changed since then, so nothing needed putting "
                              + "back."))
            } else {
                // "CHANGED", NOT "PUT BACK". The list contains two different things: files
                // restored to their snapshot contents, and files created after the snapshot
                // which the restore DELETED. Calling a deletion "put back" is the same
                // false reassurance that made this list under-report in the first place.
                print(r.prose("\(changed.count) file\(changed.count == 1 ? "" : "s") "
                              + "changed. Anything created after that snapshot is gone:"))
                print("")
                for f in changed.prefix(20) {
                    print(r.row(state: .satisfied, label: f, labelWidth: 0, indent: 4))
                }
                if changed.count > 20 {
                    print("    " + r.style.ink(.dim, "and \(changed.count - 20) more"))
                }
            }
            leave(.done)
        }
    }

    // MARK: - The list

    private func show(_ sessions: [ShellSnapshotIndex.Session], frame: Frame) {
        let r = frame.renderer
        frame.open(.look, "Snapshots Grux took before it changed a folder. Nothing here has "
                          + "been restored.")

        guard !sessions.isEmpty else {
            // THE EMPTY STATE, and it is the normal one. Most people never run a shell
            // session, so "there is nothing here" must not read like a failure.
            print(r.prose("Nothing to undo. Grux takes a snapshot before it runs anything "
                          + "that could write in one of your folders, and it has not done "
                          + "that on this Mac."))
            return
        }

        // The folder column is sized from the terminal, not guessed. A fixed 40 plus a 25
        // character session id ran to 71 columns on a 60 column terminal, which is the same
        // fixed-gutter mistake the cost screen already made once.
        let idWidth = sessions.map(\.sessionId.count).max() ?? 24
        let folderWidth = max(16, r.style.width - idWidth - 8)

        for session in sessions {
            let state: RowState = session.isRestorable ? .satisfied : .skipped
            let folder = session.rootDir ?? "folder not recorded"
            // A path is clipped from the LEFT. The end of a path is the part that identifies
            // it; the beginning is almost always /Users/somebody/Code repeated.
            let shown = folder.count > folderWidth
                ? "\u{2026}" + String(folder.suffix(folderWidth - 1))
                : folder
            print(r.row(state: state, label: shown,
                        detail: session.sessionId, labelWidth: folderWidth))
            if !session.isRestorable {
                print("      " + r.style.ink(.dim, session.rootDir == nil
                    ? "this snapshot folder does not record where it belongs"
                    : (session.snapshots.isEmpty ? "no snapshots"
                                                 : "that folder is no longer there")))
            }
            for s in session.snapshots.reversed() {
                // CLIP THE LABEL TO WHAT IS LEFT. A snapshot label is a shell command, and
                // one of the real ones on this machine is 96 characters of `mkdir -p ... &&
                // cat > ...`, which ran straight off the edge and was cut mid-token by the
                // terminal rather than by anything that had thought about it.
                let when = stamp(s.createdAt)
                let used = 6 + s.snapshotId.count + 2 + 2 + when.count
                let room = max(12, r.style.width - used)
                let label = s.label.count > room
                    ? String(s.label.prefix(room - 1)).trimmingCharacters(in: .whitespaces) + "\u{2026}"
                    : s.label
                print("      " + r.style.ink(.accent, s.snapshotId)
                      + "  " + label
                      + "  " + r.style.ink(.dim, when))
            }
            print("")
        }

        let restorable = sessions.filter(\.isRestorable)
        let total = sessions.reduce(0) { $0 + $1.snapshots.count }
        print(r.prose("\(sessions.count) session\(sessions.count == 1 ? "" : "s"), "
                      + "\(restorable.count) you can still restore, \(total) snapshot"
                      + "\(total == 1 ? "" : "s") between them."))
        print("")
        print(r.style.ink(.dim, r.prose("grux undo <id> to put a folder back. It asks first.",
                                        indent: 2)))
    }

    private func stamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "d MMM, h:mm a"
        f.amSymbol = "AM"; f.pmSymbol = "PM"
        return f.string(from: d)
    }
}

/// Run one async call from a synchronous command and wait for it.
///
/// ArgumentParser's `run()` is synchronous here and these commands are one-shot processes, so
/// a semaphore is the honest tool: there is no run loop to starve and nothing else waiting.
func runBlocking<T: Sendable>(_ work: @escaping @Sendable () async -> T) -> T {
    let box = UnsafeMutablePointer<T?>.allocate(capacity: 1)
    box.initialize(to: nil)
    defer { box.deinitialize(count: 1); box.deallocate() }
    let done = DispatchSemaphore(value: 0)
    Task.detached(priority: .userInitiated) {
        box.pointee = await work()
        done.signal()
    }
    done.wait()
    return box.pointee!
}
