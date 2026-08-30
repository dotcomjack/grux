import ArgumentParser
import Foundation
import GruxSetupCore
import GruxShellCore

// MARK: - grux shell

/// One shell command, through the trust ceiling, snapshotted first.
///
/// ## The allowlist is the product
///
/// Everything else here is packaging around one refusal: Grux runs a command in a folder
/// somebody named, or it runs it nowhere. The list starts EMPTY on a fresh install, so the
/// first thing most people see from this command is a no, and that screen gets more care
/// than the success one. It names the folders that are on the list, names the command that
/// adds another, and never offers to add one itself. A command that could widen the
/// allowlist in order to run is not gated by an allowlist.
///
/// ## Why it asks the app where it will run
///
/// `ShellAllowlist` reads `UserDefaults.standard`, which is the APP's defaults domain, not
/// reliably this binary's. Deciding here would mean this command's idea of the allowlist
/// drifting from the one that actually gates the shell, and the direction of that drift is
/// unpredictable: an empty local read would refuse work Grux would happily do, and a stale
/// one would promise work it will refuse. So the app is asked with an empty command, which
/// it answers with the folder, the roots and the ceiling, and runs nothing.
struct Shell: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "shell",
        abstract: "Run a shell command in a folder Grux may work in, snapshotted first.",
        discussion: """
            Everything after the command is the command. Quote it if it contains anything \
            your own shell would eat.

              grux shell "npm test"
              grux shell --timeout 300 "swift build"
              grux shell --yes "git status"

            Grux snapshots the folder before it runs anything that could destroy work, so \
            grux undo can put it back, and it refuses outright anything outside the folders \
            you added with grux add project.

            It exits with the command's own exit status, so a script can read it, \
            except for 2 and 3, which grux reserves for itself and which become 1. \
            The command's real status is always in the output.
            """)

    @Argument(parsing: .remaining, help: "The command. Everything after grux shell.")
    var words: [String] = []

    @Option(name: .long, help: "Seconds before Grux stops waiting. 1 to 900, default 60.")
    var timeout: Int = 60

    @Flag(name: .long, help: "Do not ask. For a script that has already asked.")
    var yes = false

    @Flag(name: .long, help: "Never ask. Names the flag that would have answered, and stops.")
    var noInput = false

    func run() throws {
        let frame = Frame()
        let r = frame.renderer

        let command = words.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else {
            frame.open(.look)
            // A designed empty state rather than a usage dump. Somebody who typed
            // `grux shell` and stopped knows what a shell is; they have not typed a command.
            print(r.prose("Nothing to run. Everything after the command is the command."))
            print("")
            print("    " + r.style.ink(.accent, "grux shell \"npm test\""))
            leave(.failed)
        }
        guard (1...900).contains(timeout) else {
            frame.open(.look)
            print(r.prose("Grux holds a command open for between 1 and 900 seconds, and "
                          + "\(timeout) is outside that. The default is 60."))
            leave(.failed)
        }

        // ---- LOOK: where this would run, answered by the app ------------------------------
        //
        // Twenty seconds rather than the default ten, for the reason `grux run` gives: the
        // ordinary cause of a slow first call is a cold launch, and twice the default rides
        // that out without leaving somebody staring at a cursor when Grux is genuinely
        // wedged.
        let planner = ControlClient(timeout: 20)
        var plan: [String: Any] = [:]
        switch planner.call(tool: "grux_shell", arguments: ["command": ""]) {
        case .failure(let why):
            frame.open(.look)
            print(r.prose(frame.explain(why)))
            if case .notRunning = why {
                print("")
                print(r.style.ink(.dim, r.prose("Reading is free with Grux closed, but "
                    + "running something is not: the app owns the shell, the snapshot and "
                    + "the folder list.", indent: 2)))
            }
            leave(.failed)
        case .success(let text):
            plan = (try? JSONSerialization.jsonObject(with: Data(text.utf8)))
                as? [String: Any] ?? [:]
        }

        let roots = (plan["roots"] as? [String] ?? []).sorted {
            // CASE INSENSITIVE. A plain `<` files ~/code after ~/Code, and this list is read
            // by somebody checking whether their folder is on it.
            $0.lowercased() < $1.lowercased()
        }
        let root = plan["root"] as? String ?? ""
        let mode = plan["mode"] as? String ?? "guarded"
        let sessionLive = plan["session_live"] as? Bool ?? false
        let asksTouchID = plan["asks_touch_id"] as? Bool ?? false
        let folder = (plan["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? root

        guard !root.isEmpty else { refuseNoFolder(roots: roots, frame: frame) }

        // ---- the refusal this ceiling has already decided on ------------------------------
        //
        // Worked out HERE, before anybody is asked to confirm, and it is worth the duplicated
        // check: `detectNetworkOrExternalEffect` is pure text over the command with no state
        // behind it, so this reaches the same verdict the app will. Asking somebody to type a
        // word to confirm a command that is going to be refused a tenth of a second later is
        // the rudest thing this command could do.
        let reach = ShellSafety.detectNetworkOrExternalEffect(command: command)
        if mode != "trust", let reach {
            frame.open(.look, "Grux will not run this one, and nothing about how you asked "
                              + "would change that.")
            printWhat(command: command, folder: folder, root: root, roots: roots,
                      mode: mode, frame: frame)
            print("")
            print(r.style.ink(.attention, r.prose(
                "That command reaches off this Mac, and a snapshot cannot pull it back. Your "
                + "trust ceiling is \(mode), which holds those until somebody says yes in "
                + "Grux itself.")))
            print("")
            print(r.style.ink(.dim, r.prose(reach, indent: 2)))
            print("")
            print(r.prose("Ask Grux to run it, where it can put the question to you, or "
                          + "raise the ceiling to trust under Security in Grux Settings.",
                          indent: 2))
            // NOBODY CAN FIX THIS BY TYPING A BETTER COMMAND. That is what waiting on you
            // means, and it is why this is not a 1.
            leave(.waitingOnYou)
        }

        // ---- the gate --yes CANNOT answer -------------------------------------------------
        //
        // Sibling of the refusal above and refused just as early, because the ceiling is not
        // the only thing that stops this dead. `--yes` answers THIS command's typed
        // confirmation; the Touch ID prompt belongs to the app, has no timeout, and waits for
        // a finger. Traced at HEAD: with the ceiling at trust and the Touch ID gate on,
        // `grux shell --yes --no-input "curl -X POST ..."` from launchd put a system sheet on
        // an unattended Mac, because `--no-input` was only ever consulted inside `if !yes`.
        // Ninety seconds later this side gave up and said the command might still be running
        // and that grux undo had the snapshot taken before it started. Neither was true: the
        // gate sits in FRONT of the run, and the run is what takes the snapshot, so nothing
        // ran and nothing was recorded.
        if noInput, asksTouchID, mode == "trust", let reach {
            frame.open(.look, "Grux would put a Touch ID prompt on this Mac, and --no-input "
                              + "says there is nobody here to answer it.")
            printWhat(command: command, folder: folder, root: root, roots: roots,
                      mode: mode, frame: frame)
            print("")
            print(r.style.ink(.attention, r.prose(
                "That command reaches off this Mac and you have the Touch ID gate switched "
                + "on, so Grux asks before it runs one. Nothing ran.")))
            print("")
            print(r.style.ink(.dim, r.prose(reach, indent: 2)))
            print("")
            print(r.prose("No flag gets past this one, and --yes is the wrong one: it "
                          + "answers grux's own question, not the system prompt. Turn the "
                          + "gate off under Security in Grux Settings, or run this where "
                          + "somebody can answer it.", indent: 2))
            // WAITING ON YOU rather than 1, for the reason above it: no better call exists,
            // and the one thing that would let this through is a person at this Mac.
            leave(.waitingOnYou)
        }

        // ---- COST: what it will do, before it does it -------------------------------------
        frame.open(.cost, "What runs, where it runs, and what Grux writes down first.")
        printWhat(command: command, folder: folder, root: root, roots: roots,
                  mode: mode, frame: frame)
        print("")
        print(r.prose("Grux snapshots that folder before it runs anything that could "
                      + "destroy work, and tells you the id afterwards, so grux undo can put "
                      + "it back. Your own git repository is never touched."))

        if !sessionLive {
            // The first command in a folder pays for the baseline commit over the whole
            // tree, which on a large project is seconds rather than milliseconds. A wait
            // nobody explained reads as a hang.
            print("")
            print(r.style.ink(.dim, r.prose("This is the first command in that folder, so "
                + "Grux records it before running. On a big project that takes a moment.",
                indent: 2)))
        }
        if asksTouchID, mode == "trust", reach != nil {
            print("")
            print(r.style.ink(.attention, r.prose("Grux will ask for Touch ID first: that "
                + "command reaches off this Mac and you have the gate switched on.",
                indent: 2)))
        }

        let here = ShellAllowlist.standardize(FileManager.default.currentDirectoryPath)
        if here != folder {
            print("")
            if Self.covering(here, in: roots) == nil {
                // NOT A REFUSAL, but the one thing most likely to surprise somebody: they
                // are standing somewhere Grux may not touch, and the command will run
                // somewhere else. Saying it here is cheaper than letting them read the
                // output of an `ls` and wonder whose files those are.
                print(r.style.ink(.attention, r.prose(
                    "You are in \(Self.shorten(here)), which is not a folder Grux may work "
                    + "in, so this runs in \(Self.shorten(folder)) instead. "
                    + "grux add project \(Self.shorten(here)) would add yours.", indent: 2)))
            } else {
                print(r.style.ink(.dim, r.prose(
                    "You are in \(Self.shorten(here)). This runs in "
                    + "\(Self.shorten(folder)).", indent: 2)))
            }
        }

        // ---- the yes ----------------------------------------------------------------------
        if !yes {
            guard !noInput else {
                print("")
                print(r.prose("--no-input means there is nobody to ask, and this runs a "
                              + "command. Pass --yes if you are sure. Nothing ran."))
                leave(.failed)
            }
            guard RawMode.isSupported else {
                print("")
                print(r.prose("Nothing is attached to this terminal, so there is nobody to "
                              + "ask. Pass --yes if you are sure. Nothing ran."))
                leave(.failed)
            }
            // TYPED, not a keystroke. `y` is muscle memory and this hands a shell command to
            // a folder full of somebody's work.
            let typed = InputPolicy.ask([
                "",
                "  Type run to confirm, or anything else to stop.",
                "  " + r.style.ink(.accent, "run"),
                "",
            ])
            guard typed == "run" else {
                print("")
                print(r.prose("Nothing ran."))
                leave(.done)
            }
        }

        // ---- the run ------------------------------------------------------------------------
        //
        // The client waits THIRTY SECONDS LONGER than the command is allowed to take. A
        // client deadline at or under the command's own would report a socket that never
        // answered, over a command that was running exactly as asked and was about to come
        // back with its output, and the snapshot line would be lost with it.
        let client = ControlClient(timeout: TimeInterval(timeout) + 30)
        var reply: [String: Any] = [:]
        switch client.call(tool: "grux_shell",
                           arguments: ["command": command, "timeout_sec": Double(timeout)]) {
        case .failure(let why):
            frame.open(.prove)
            print(r.prose(frame.explain(why)))
            if case .noAnswer = why {
                print("")
                // NOT "nothing happened". Grux took the call and the shell very probably
                // still has the command. What ran out is this side's patience.
                //
                // AND NO LONGER "the snapshot it took before it started", which this line
                // used to promise and could not keep. Grux snapshots a session's FIRST
                // command and anything destructive, so an ordinary command in an open
                // session has no snapshot of its own, and a command still behind the Touch
                // ID prompt never reached the point where one is taken. Sending somebody to
                // grux undo for an id that is not there is worse than sending them nowhere.
                print(r.style.ink(.dim, r.prose("The command may still be running inside "
                    + "Grux. grux undo lists every snapshot there is to put back.",
                    indent: 2)))
                if asksTouchID, mode == "trust", reach != nil {
                    print("")
                    // The cause this command PREDICTED before it called, so it is the one
                    // guess worth printing: the sheet has no timeout and this side's wait
                    // does, so the prompt outlives the command that asked for it.
                    print(r.style.ink(.attention, r.prose("It may also not have started: "
                        + "Grux asks for Touch ID before a command that reaches off this "
                        + "Mac, and that prompt waits for as long as it takes.", indent: 2)))
                }
            }
            leave(.failed)
        case .success(let text):
            guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8)))
                    as? [String: Any] else {
                frame.open(.prove)
                print(r.prose(text))
                leave(.failed)
            }
            reply = object
        }

        report(reply, frame: frame)
    }

    // MARK: - PROVE

    /// Every state the app can answer with, each one leaving on its own code.
    private func report(_ reply: [String: Any], frame: Frame) -> Never {
        let r = frame.renderer
        let folder = reply["cwd"] as? String ?? ""
        let snapshot = reply["snapshot_id"] as? String ?? ""
        let snapshotIsOwn = reply["snapshot_is_for_this_command"] as? Bool ?? false
        let snapshotLabel = reply["snapshot_label"] as? String ?? ""
        let reason = reply["reason"] as? String ?? ""

        frame.open(.prove)

        // REFUSED. The two kinds want opposite things from the reader, so they are never
        // printed as one: an allowlist refusal is settled until somebody changes a setting,
        // and a containment refusal is answered by a different command.
        if reply["blocked"] as? Bool == true {
            let allowlist = (reply["blocked_kind"] as? String) == "allowlist"
            if allowlist {
                print(r.prose("Grux would not run that. Your trust ceiling is strict, which "
                              + "only lets a short list of development tools run."))
                print("")
                print(r.style.ink(.dim, r.prose(reason, indent: 2)))
                print("")
                print(r.prose("Nothing ran and nothing changed. Raise the ceiling to guarded "
                              + "under Security in Grux Settings, or run something on the "
                              + "list.", indent: 2))
                leave(.waitingOnYou)
            }
            print(r.prose("Grux would not run that: it reaches outside the folder it is "
                          + "allowed to work in."))
            print("")
            print(r.style.ink(.dim, r.prose(reason, indent: 2)))
            print("")
            print(r.prose("Nothing ran and nothing changed. Keep it inside "
                          + "\(Self.shorten(reply["root"] as? String ?? folder)), or add the "
                          + "other folder with grux add project <path>.", indent: 2))
            leave(.failed)
        }

        // GATED. Caught before the confirmation in almost every case, so reaching here means
        // the ceiling moved between the two calls. It still gets a designed screen rather
        // than falling through to one that would claim the command ran.
        if reply["gated"] as? Bool == true {
            print(r.prose("Grux held that one back: it reaches off this Mac, and your trust "
                          + "ceiling wants a yes said inside Grux rather than here."))
            print("")
            print(r.style.ink(.dim, r.prose(reason, indent: 2)))
            print("")
            print(r.prose("Nothing ran. Ask Grux to run it, or raise the ceiling to trust "
                          + "under Security in Grux Settings.", indent: 2))
            leave(.waitingOnYou)
        }

        // CUT OFF.
        if reply["timed_out"] as? Bool == true {
            print(r.prose("\(timeout) seconds passed and it had not finished, so Grux "
                          + "stopped waiting for it."))
            print("")
            print(r.prose("Grux stopped WAITING, it did not stop the command: whatever it "
                          + "was doing in \(Self.shorten(folder)) it is probably still "
                          + "doing, and no output came back to show you.", indent: 2))
            printUndo(snapshot: snapshot, own: snapshotIsOwn, label: snapshotLabel,
                      folder: folder, frame: frame)
            print("")
            print(r.style.ink(.dim, r.prose("grux shell --timeout <seconds> waits longer. "
                                            + "The most it will wait is 900.", indent: 2)))
            leave(.failed)
        }

        let exitCode = reply["exit_code"] as? Int ?? -1

        // THE STATUS ITSELF WAS UNREADABLE, which is not the same as the command failing.
        if reply["status_unreadable"] as? Bool == true || exitCode < 0 {
            print(r.prose("The command ran and Grux lost track of how it ended: the line the "
                          + "shell prints back with the exit status never arrived."))
            print("")
            print(r.prose("Anything it printed is below, but the status is not Grux's to "
                          + "report, so this command does not pretend to pass one on. "
                          + "Running it again starts a fresh shell.", indent: 2))
            if !reason.isEmpty {
                print("")
                print(r.style.ink(.dim, r.prose(reason, indent: 2)))
            }
            print("")
            printStreams(reply, frame: frame)
            printUndo(snapshot: snapshot, own: snapshotIsOwn, label: snapshotLabel,
                      folder: folder, frame: frame)
            leave(.failed)
        }

        // RAN.
        let ms = reply["duration_ms"] as? Int ?? 0
        let took = ms < 1000 ? "\(ms)ms"
            : String(format: "%.1fs", Double(ms) / 1000)
        print(r.prose(exitCode == 0
            ? "It ran in \(Self.shorten(folder)) and finished cleanly, in \(took)."
            : "It ran in \(Self.shorten(folder)) and exited \(exitCode), in \(took)."))
        print("")
        printStreams(reply, frame: frame)
        printUndo(snapshot: snapshot, own: snapshotIsOwn, label: snapshotLabel,
                  folder: folder, frame: frame)

        if exitCode == 0 { leave(.done) }

        print("")
        // TWO OF THE COMMAND'S CODES ARE NOT THIS COMMAND'S TO RETURN. Passing the status
        // straight through is right for 7 or 127 and WRONG for 2 and 3, because this surface
        // has already published what those two mean: 2 is "no invocation can succeed until a
        // person acts on this Mac" and 3 is "run grux doctor". A `grep` that found nothing
        // exits 1; plenty of ordinary programs exit 2 on a usage error, and passing that
        // through counterfeits the one signal that exists to decide whether to wake somebody
        // up. Exit 2 stops being usable for that the moment anything else can produce it.
        //
        // So: passed through everywhere it does not collide, folded to 1 where it does, and
        // the real number is always in the sentence above and in --json.
        let reserved = [Exit.waitingOnYou.rawValue, Exit.selfRepairAvailable.rawValue]
            .map(Int.init)
        let collides = reserved.contains(exitCode)
        // Built outside the interpolation. A ternary whose arms are themselves multi line
        // concatenations does not survive being nested inside `\( )`.
        let reservedFor = exitCode == Int(Exit.waitingOnYou.rawValue)
            ? "work that is waiting on you"
            : "a problem grux doctor can fix"
        let tail = collides
            ? "\(exitCode) is the command's own exit status. This command exits 1 instead, "
            + "because grux reserves \(exitCode) for " + reservedFor + ". The number above "
            + "is the one the command returned."
            : "\(exitCode) is the command's own exit status, and it is this command's too, "
            + "so a script reads one number instead of two."
        print(r.style.ink(.dim, r.prose(tail, indent: 2)))
        if collides { leave(.failed) }
        // PASSED THROUGH RATHER THAN FLATTENED. `leave` only carries the four codes this CLI
        // defines for itself, and a command that exited 7 has to arrive at the caller as 7:
        // collapsing it to 1 makes `grux shell` unusable in front of anything that branches
        // on a status. A shell exit status is 0 to 255 by definition, and anything outside
        // that range never reaches here because a negative one is handled above.
        //
        // MODULE QUALIFIED, AND IT HAS TO BE. `ParsableArguments` carries a protocol
        // extension member `static func exit(withError:)`, and unqualified lookup inside a
        // command's own method finds that member and STOPS: it never reaches the C `exit`.
        // Measured: three errors off one line, the first of which is "static member 'exit'
        // cannot be used on instance of type 'Shell'", which reads like an access problem
        // rather than the shadowing it is.
        Foundation.exit(Int32(min(255, exitCode)))
    }

    /// stdout and stderr, SEPARATE and labelled, and printed verbatim.
    ///
    /// Not wrapped and not indented, which is the one place this command steps off the grid
    /// on purpose. This is the output of somebody else's program: a diff, a test report, a
    /// column of paths. Re-flowing it to the terminal width would corrupt the thing they
    /// asked for, and indenting it would break a copy and paste.
    private func printStreams(_ reply: [String: Any], frame: Frame) {
        let r = frame.renderer
        for (label, clip) in [("stdout", "stdout_clipped"), ("stderr", "stderr_clipped")] {
            let body = reply[label] as? String ?? ""
            print(r.style.ink(.dim, "  " + label))
            if body.isEmpty {
                // A DESIGNED EMPTY STATE, and both labels print even when one is empty.
                // Dropping the empty one would leave a reader unsure whether the two streams
                // had been merged into the one they can see.
                print(r.style.ink(.dim, r.prose("nothing", indent: 4)))
            } else {
                print(body)
            }
            if reply[clip] as? Bool == true {
                print(r.style.ink(.dim, r.prose("Grux cut this off. The command wrote more "
                                                + "than one reply can carry.", indent: 4)))
            }
            print("")
        }
    }

    /// The line that makes this command safe to offer at all.
    ///
    /// Never dimmed and never optional. When the snapshot predates this command it says so:
    /// `ShellSession` takes a baseline on a session's first command and one in front of
    /// anything destructive, so an ordinary command in an open session is covered by an
    /// earlier snapshot rather than its own, and undoing to it reaches back past this
    /// command. Printing that id without the caveat would be the false half of a true
    /// sentence.
    private func printUndo(snapshot: String, own: Bool, label: String, folder: String,
                           frame: Frame) {
        let r = frame.renderer
        guard !snapshot.isEmpty else {
            print(r.prose("Grux has no snapshot of that folder, so there is nothing for "
                          + "grux undo to put back."))
            return
        }
        print("  " + r.style.ink(.accent, "grux undo \(snapshot)"))
        if own {
            print(r.prose("puts \(Self.shorten(folder)) back to how it was before this "
                          + "command ran.", indent: 2))
        } else {
            let what = label.isEmpty ? "an earlier command" : label
            print(r.prose("puts \(Self.shorten(folder)) back to before \(what), which is "
                          + "further back than this command. Nothing was recorded for this "
                          + "one, because Grux only snapshots ahead of work it could "
                          + "destroy.", indent: 2))
        }
    }

    // MARK: - Screens

    /// The command, the folder, the root it falls under, and the ceiling over it.
    private func printWhat(command: String, folder: String, root: String, roots: [String],
                           mode: String, frame: Frame) {
        let r = frame.renderer
        var rows: [(String, String)] = [
            ("Command", command),
            ("Folder", Self.shorten(folder)),
        ]
        // The root only earns a row when it is NOT the folder, which happens once a command
        // in this session has cd'd deeper. Printing the same path twice under two labels is
        // a grid pretending to carry information.
        if folder != root {
            rows.append(("Allowed root", Self.shorten(root)))
        }
        rows.append(("Ceiling", mode))
        // SIZED FROM THE WIDEST LABEL PRESENT, never a fixed guess, so the detail column
        // lines up whether or not the root row is there.
        let width = (rows.map { $0.0.count }.max() ?? 8) + 2
        for (label, detail) in rows {
            // A NARROW TERMINAL DROPS THE DETAIL COLUMN, which for these rows would print
            // the word "Command" and not the command. Everything moves into the label there,
            // because a grid that hides the value has stopped being a grid.
            let narrow = r.style.isNarrow
            let room = r.style.width - (narrow ? label.count + 6 : width + 6)
            let shown = Self.fit(detail, into: room, clip: r.style.isTTY)
            if narrow {
                print(r.row(state: .satisfied, label: "\(label): \(shown)", labelWidth: 0))
            } else {
                print(r.row(state: .satisfied, label: label, detail: shown, labelWidth: width))
            }
        }
        if roots.count > 1 {
            print("")
            print(r.style.ink(.dim, r.prose("Grux may work in \(roots.count) folders and "
                + "runs in the first one it can reach.", indent: 2)))
        }
    }

    /// The refusal, which is the screen this command exists for.
    private func refuseNoFolder(roots: [String], frame: Frame) -> Never {
        let r = frame.renderer
        frame.open(.look, "Grux runs a command in a folder you named, or nowhere.")

        if roots.isEmpty {
            // THE FRESH INSTALL, and it is the normal state rather than a fault. The
            // allowlist ships empty because no install can guess where somebody keeps their
            // code, so this must not read like something broke.
            print(r.prose("You have not told Grux about a folder yet, so there is nowhere "
                          + "for it to run anything. Nothing ran."))
        } else {
            // Every root is listed as missing, and that is not a guess: the app answers with
            // no folder only when NONE of them resolves to a directory on this Mac.
            print(r.prose("Grux is allowed to work in \(roots.count) folder"
                          + "\(roots.count == 1 ? "" : "s") and cannot reach any of them "
                          + "right now. Nothing ran."))
            print("")
            let width = roots.map { Self.shorten($0).count }.max() ?? 20
            for path in roots {
                print(r.row(state: .needed, label: Self.shorten(path),
                            detail: "not a folder on this Mac", labelWidth: width))
            }
            print("")
            print(r.legend([.needed]))
        }
        print("")
        print("    " + r.style.ink(.accent, "grux add project <path>"))
        print(r.prose("adds a folder to that list. Grux will not add one on its own to get "
                      + "a command to run.", indent: 4))
        // A PERSON HAS TO DO SOMETHING ON THIS MAC. No better invocation of `grux shell`
        // gets past this, which is exactly what a 2 means.
        leave(.waitingOnYou)
    }

    // MARK: - Paths

    /// Which allowed root a path falls under, using the same normalisation the app used on
    /// the list it sent back.
    private static func covering(_ path: String, in roots: [String]) -> String? {
        roots.first { root in
            // Trailing separator so /foo/barbaz does not match the root /foo/bar.
            path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }
    }

    /// Clipped on a terminal, whole in a pipe, and only ever for DATA.
    ///
    /// The command is the person's own text and can be any length; a 200 character one run
    /// off the edge of the grid and was cut by the terminal rather than by anything that had
    /// thought about it. Anything reading this in a pipe gets the whole value, because there
    /// is no edge there to run off and a machine reading a truncated command is worse off
    /// than a person reading a wrapped one.
    private static func fit(_ value: String, into room: Int, clip: Bool) -> String {
        guard clip, room > 8, value.count > room else { return value }
        return String(value.prefix(room - 1)).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }

    private static func shorten(_ path: String) -> String {
        let home = NSHomeDirectory()
        guard path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }
}
