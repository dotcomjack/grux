import ArgumentParser
import Foundation
import GruxSetupCore

// MARK: - grux agent

/// Hand the agent a task, see what has been handed over, or read one back.
///
/// ## It does not wait, and that is the design rather than a limitation
///
/// A worker runs until it is done or until its half hour TTL, and the control socket gives up
/// in seconds rather than minutes. A command that waited would print a failure over work that
/// was running perfectly, and would leave nothing behind to find that work with. So this
/// starts the job, prints the id, and prints the command that reads it back.
///
/// ## The listing is not a convenience
///
/// An id that scrolled out of a terminal is a job nobody can find again. `grux agent` with
/// nothing is what makes the id worth printing, which is why it is the no argument form
/// rather than a flag somebody has to know about.
///
/// ## Why it asks
///
/// Starting one spends model time and writes files on this Mac under a Claude Code whose own
/// permission prompts are off. That is a decision, so it takes a typed word rather than a
/// keystroke, and in a pipe it refuses instead of hanging on a question nobody is there to
/// answer.
struct AgentCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agent",
        abstract: "Hand the agent a task. Prints a job id and does not wait.",
        discussion: """
            Everything after the command is the task. Quote it if it contains anything your \
            shell would eat.

              grux agent "port the settings screen to the new tokens"
              grux agent                    every job, newest first, with its state and age
              grux agent --job 3f2a1b9c     what one of them has done so far

            A job outlives this command, so nothing here blocks on one: you get an id back \
            and read it whenever you like. Starting one spends model time and writes files, \
            so it asks first unless you pass --yes. `grux approvals` says what the agent may \
            do without asking.
            """)

    @Argument(parsing: .remaining, help: "The task. Everything after the command.")
    var words: [String] = []

    @Option(name: .long, help: "A job id from the list, or the first few characters of one.")
    var job: String?

    @Flag(name: .long, help: "Start it without asking. For a script that has already asked.")
    var yes = false

    @Option(name: .long, help: "How many jobs to list. Default 10.")
    var limit: Int = 10

    @Flag(name: .long, help: "Machine readable.")
    var json = false

    /// Accepted by every command, and it means one thing on all of
    /// them. See InputPolicy.
    @OptionGroup var input: InputPolicy

    func run() throws {
        let frame = Frame()
        let task = words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let wanted = (job ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        // TWO QUESTIONS IN ONE CALL, ANSWERED WITH NEITHER. Reading a job back and starting
        // a new one are opposite intentions, and guessing either way is expensive: guess the
        // read and the task never runs, guess the start and somebody pays for a job they did
        // not ask for on top of the answer they wanted.
        guard task.isEmpty || wanted.isEmpty else {
            if !json { frame.open(.look) }
            print(frame.renderer.prose("--job reads a job back and a task starts a new one, "
                + "so this asks for two different things at once. Run it twice."))
            leave(.failed)
        }

        if !wanted.isEmpty { readBack(wanted, frame: frame) }
        if task.isEmpty { showList(frame: frame) }
        start(task, frame: frame)
    }

    // MARK: - Starting one

    private func start(_ task: String, frame: Frame) -> Never {
        let r = frame.renderer
        // Longer than the default ten seconds. Starting is not the swarm, it is writing the
        // job down and spawning the loop that runs it, but that lands behind whatever the
        // app is doing on its main actor when the call arrives.
        let client = ControlClient(timeout: 30)

        // ASKED BEFORE THE QUESTION, NOT AFTER IT. Without this the person reads the cost
        // screen, types the word, and only then learns Grux was never up to take the job.
        guard client.isAvailable else {
            if !json { frame.open(.look) }
            print(r.prose(frame.explain(
                ControlClient.Failure.notRunning(path: client.socketPath))))
            leave(.failed)
        }

        if !json {
            frame.open(.cost, "This is what you are about to hand over, and what it may do "
                              + "while it runs.")
            print(r.style.ink(.accent, r.prose(task, indent: 4)))
            print("")
            print("  " + r.heading("WHAT A JOB MAY DO"))
            print("")
            // PROSE, NOT A LABEL AND A DETAIL. The renderer drops the detail column below
            // sixty columns, which is the right call for a machine id sitting beside a name
            // and the wrong one for the only screen where somebody decides to spend money:
            // a narrow terminal would have shown four labels and no consequences.
            print(r.prose("Runs Claude Code on this Mac with its own permission prompts "
                          + "turned off, so it will not stop and ask you a second time.",
                          indent: 4))
            print(r.prose("Works in a new folder under Documents/Grux/swarms, and can read "
                          + "anything your account can read.", indent: 4))
            print(r.prose("Spends model time on your Claude subscription. Grux records what "
                          + "the run would have cost, and that figure is a record rather "
                          + "than a cap: nothing stops the job when it is reached.",
                          indent: 4))
            print(r.prose("Stops on its own after 30 minutes, or when you cancel it in the "
                          + "Agents tab.", indent: 4))
            print("")
            print(r.style.ink(.dim, r.prose("grux approvals says what the agent may already "
                + "do without asking. Nothing here changes that.", indent: 2)))
        }

        if !yes {
            // A PIPE AND A MACHINE READABLE RUN ARE THE SAME CASE. Neither has anybody to
            // ask, and a command that hangs on a hidden question is worse to an agent
            // driving it than one that refuses.
            guard input.canAsk, !json else {
                print("")
                print(r.prose("Starting a job asks first and there is nobody here to ask. "
                              + "Pass --yes if you mean to start it."))
                leave(.failed)
            }
            // TYPED, not a keystroke. `y` is muscle memory; a word is a decision, and this
            // one spends money and turns a coding agent loose on the machine.
            let typed = InputPolicy.ask([
                "",
                "  Type start to confirm, or anything else to stop.",
                "",
            ])
            guard typed.lowercased() == "start" else {
                print("")
                print(r.prose("Nothing was started."))
                leave(.done)
            }
        }

        switch client.call(tool: "grux_agent", arguments: ["text": task]) {
        case .failure(let why):
            print("")
            print(r.prose(frame.explain(why)))
            leave(.failed)
        case .success(let text):
            if json { print(text); leave(.done) }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8))
                    as? [String: Any],
                  let job = obj["job"] as? [String: Any],
                  let id = job["id"] as? String else {
                print(r.prose(text))
                leave(.failed)
            }

            frame.open(.prove, "Handed over. It runs on its own from here, and nothing in "
                               + "this terminal is waiting for it.")
            // THE ID IS THE ANSWER, so it is a line of its own rather than a detail column
            // the renderer is allowed to drop on a narrow terminal.
            print(r.style.ink(.accent, r.prose(id, indent: 4)))
            print("")

            var rows: [(String, String)] = []
            if let status = job["status"] as? String {
                rows.append(("State", statusWord(status)))
            }
            if let root = job["root_dir"] as? String { rows.append(("Working in", tidy(root))) }
            if let workers = job["workers"] as? Int {
                rows.append(("Workers", "\(workers)"))
            }
            let width = rows.map { $0.0.count }.max() ?? 10
            for (label, detail) in rows {
                print(r.row(state: .satisfied, label: label, detail: detail,
                            labelWidth: width, indent: 2))
            }

            print("")
            print(r.rule())
            // The SHORT id, because the app resolves a leading fragment to the one job it
            // can only be, and a thirty six character line is one a person retypes wrong.
            let short = String(id.prefix(8))
            print("  " + r.style.ink(.dim, "grux agent --job \(short)")
                  + "   what it has done so far")
            print("  " + r.style.ink(.dim, "grux agent")
                  + "                  every job, newest first")
            leave(.done)
        }
    }

    // MARK: - The list

    private func showList(frame: Frame) -> Never {
        let r = frame.renderer
        let client = ControlClient()

        switch client.call(tool: "grux_agent") {
        case .failure(let why):
            if !json { frame.open(.look) }
            print(r.prose(frame.explain(why)))
            leave(.failed)
        case .success(let text):
            if json { print(text); leave(.done) }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8))
                    as? [String: Any],
                  let all = obj["jobs"] as? [[String: Any]] else {
                print(r.prose(text))
                leave(.failed)
            }
            let total = (obj["count"] as? Int) ?? all.count

            guard !all.isEmpty else {
                // NOT AN ERROR, AND THE COMMON STATE. Most people have never handed the
                // agent anything, and an empty list that reads like a failure teaches them
                // the command is broken rather than that they have not used it yet.
                frame.open(.prove, "Nothing has been handed to the agent on this Mac.")
                print(r.prose("A job is one task, run by a coding agent, in a folder of its "
                              + "own. Start one like this:"))
                print("")
                print("    " + r.style.ink(.accent,
                                           "grux agent \"the thing you want done\""))
                print("")
                print(r.style.ink(.dim, r.prose("It asks before it starts, and prints an id "
                    + "you can read back afterwards.", indent: 2)))
                leave(.done)
            }

            let shown = Array(all.prefix(max(1, limit)))
            frame.open(.prove, "What you have handed to the agent, newest first.")

            // A GRID SIZED FROM WHAT IS ON THE SCREEN. The status words run from four
            // characters to nine, so a guess is either a ragged column or a gutter of
            // nothing, and the age column goes entirely on a narrow terminal rather than
            // squeezing the title down to a word and a half.
            let states = shown.map { statusWord(($0["status"] as? String) ?? "") }
            let stateWidth = states.map(\.count).max() ?? 7
            let ages = shown.map { age(($0["created_at"] as? String)) }
            let ageWidth = ages.map(\.count).max() ?? 14
            let showAge = !r.style.isNarrow
            let fixed = 2 + 8 + 2 + stateWidth + 2 + (showAge ? ageWidth + 2 : 0)

            for (i, jobRow) in shown.enumerated() {
                let id = (jobRow["id"] as? String) ?? ""
                let title = (jobRow["title"] as? String) ?? "untitled"
                var line = "  " + r.style.ink(.accent, String(id.prefix(8)))
                line += "  " + r.style.ink(ink(for: states[i]),
                                           pad(states[i], to: stateWidth))
                if showAge { line += "  " + r.style.ink(.dim, pad(ages[i], to: ageWidth)) }
                // WHOLE IN A PIPE. A job title is data, a machine reading this wants all of
                // it, and there is no width to fit. Same asymmetry as grux logs, and it was
                // missing here: every title and every error was clipped on both surfaces.
                line += "  " + clip(title, to: r.style.isTTY
                                    ? max(12, r.style.width - fixed) : Int.max)
                print(line)
                // The reason it stopped, under the row it belongs to, because "failed" on
                // its own sends somebody to open a folder to find out why.
                if let error = jobRow["error"] as? String, !error.isEmpty {
                    // 200 IS ROOM ON A SCREEN, NOT A LIMIT ON THE VALUE. It was a bare
                    // literal, so a pipe got an ellipsis too: SwarmOrchestrator writes
                    // "workers failed: swarm-1, ..." and 20 failed workers is 205
                    // characters, cut where the last labels are, which is the part worth
                    // reading. --job and --json hand that string back whole, so a clipped
                    // list was the one surface of this command disagreeing with the rest.
                    print(r.style.ink(.dim, r.prose(clip(flatten(error),
                                                         to: r.style.isTTY ? 200 : Int.max),
                                                    indent: 6)))
                }
            }

            print("")
            print(r.rule())
            // EVERY ROW ON THE SCREEN ACCOUNTED FOR, and the buckets describe the rows above
            // rather than the whole store: a window that summarised jobs it did not print
            // would be a count nobody can check against the list under it.
            var buckets: [String: Int] = [:]
            for state in states { buckets[state, default: 0] += 1 }
            let parts = buckets.keys.sorted { $0.lowercased() < $1.lowercased() }
                .map { "\(buckets[$0] ?? 0) \($0)" }
            let head = shown.count == total
                ? "\(total) job\(total == 1 ? "" : "s")"
                : "\(shown.count) of \(total) jobs"
            print(r.prose(head + ": " + r.list(parts) + "."))
            // TWO DIFFERENT REASONS THE LIST IS SHORT, AND ONLY ONE OF THEM --limit FIXES.
            // Grux hands back its own most recent window, so telling somebody to ask for
            // forty when thirty nine will never arrive is an instruction that quietly fails.
            if shown.count < all.count {
                print("")
                print(r.style.ink(.dim, r.prose("grux agent --limit \(all.count) shows the "
                    + "rest of what Grux handed back.", indent: 2)))
            } else if all.count < total {
                print("")
                print(r.style.ink(.dim, r.prose("Grux hands back the \(all.count) most "
                    + "recent, so \(total - all.count) older job"
                    + "\(total - all.count == 1 ? " is" : "s are") not shown here. They are "
                    + "still in the Agents tab.", indent: 2)))
            }
            print("")
            print("  " + r.style.ink(.dim, "grux agent --job <id>")
                  + "   what one of them has done")
            leave(.done)
        }
    }

    // MARK: - Reading one back

    private func readBack(_ wanted: String, frame: Frame) -> Never {
        let r = frame.renderer
        let client = ControlClient()

        switch client.call(tool: "grux_agent", arguments: ["job": wanted]) {
        case .failure(let why):
            if !json { frame.open(.look) }
            print(r.prose(frame.explain(why)))
            // A REFUSAL IS THE ONLY FAILURE WORTH A SECOND QUESTION. Grux answered and said
            // it has no such job, so it is up and can be asked which ids it does have. A
            // connection failure cannot be asked anything, and asking again would print a
            // second copy of the same bad news.
            if case .toolFailed = why, !json, let near = nearest(to: wanted, client: client) {
                print("")
                print(r.style.ink(.dim, r.prose("Did you mean \(near)?", indent: 2)))
            }
            leave(.failed)
        case .success(let text):
            if json { print(text); leave(.done) }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8))
                    as? [String: Any],
                  let job = obj["job"] as? [String: Any] else {
                print(r.prose(text))
                leave(.failed)
            }
            render(job: job, envelope: obj, frame: frame)
        }
    }

    private func render(job: [String: Any], envelope: [String: Any], frame: Frame) -> Never {
        let r = frame.renderer
        let id = (job["id"] as? String) ?? ""
        let status = (job["status"] as? String) ?? ""

        frame.open(.prove, sentence(for: job))
        print(r.style.ink(.accent, r.prose((job["title"] as? String) ?? "untitled", indent: 2)))

        // NO STATE ROW HERE, and the sentence above is why: every row in this grid carries
        // the same glyph, which reads as "this is so", and "+ ready" beside the word failed
        // says two opposite things in one line. The state is the headline instead, where a
        // failure can have its own words.
        var rows: [(String, String)] = []
        if let workers = job["workers"] as? Int, workers > 0 {
            let done = (job["workers_done"] as? Int) ?? 0
            let failed = (job["workers_failed"] as? Int) ?? 0
            var detail = "\(done) of \(workers) done"
            if failed > 0 { detail += ", \(failed) failed" }
            rows.append(("Workers", detail))
        }
        if let spent = job["spent_usd"] as? Double, spent > 0 {
            rows.append(("Would have cost", money(spent)))
        }
        if let root = job["root_dir"] as? String { rows.append(("Working in", tidy(root))) }
        rows.append(("Job", id))
        let width = rows.map { $0.0.count }.max() ?? 10
        if !rows.isEmpty {
            print("")
            for (label, detail) in rows {
                print(r.row(state: .satisfied, label: label, detail: detail,
                            labelWidth: width, indent: 2))
            }
        }

        if let error = (job["error"] as? String), !error.isEmpty {
            print("")
            print(r.style.ink(.attention, r.prose(flatten(error), indent: 2)))
        }
        if (job["spent_usd"] as? Double ?? 0) > 0 {
            print("")
            print(r.style.ink(.dim, r.prose("That figure is what the run would have cost on "
                + "metered API. It ran on your Claude subscription, and nothing was billed "
                + "for it here.", indent: 2)))
        }

        let steps = (envelope["steps"] as? [[String: Any]]) ?? []
        print("")
        print(r.rule())
        guard !steps.isEmpty else {
            // A REAL STATE, NOT AN OVERSIGHT. A queued job has written nothing yet, and a
            // job that died before its first worker spoke never will, so this says which
            // rather than showing an empty heading.
            print(r.prose(status == "queued"
                ? "No steps yet. It has not started, and the first line appears the moment "
                  + "its worker does."
                : "No steps were recorded for this job."))
            if let log = envelope["log_path"] as? String {
                print("")
                print(r.style.ink(.dim, r.prose(tidy(log), indent: 2)))
            }
            leave(.done)
        }

        // THE TAIL IS THE ANSWER to "what is it doing", so the newest line is the last one
        // printed and sits nearest the prompt. A pipe gets every step there is, because the
        // thing reading it is not scrolling.
        let visible = r.style.isTTY ? Array(steps.suffix(20)) : steps
        let clocks = visible.map { time($0["at"] as? String) }
        let clockWidth = clocks.map(\.count).max() ?? 11
        let kinds = visible.map { spaced(($0["kind"] as? String) ?? "") }
        let kindWidth = kinds.map(\.count).max() ?? 8
        // Sized from the two columns actually drawn, so a run with no timestamps and a run
        // full of them both leave the text starting where the grid says it does.
        let room = r.style.isTTY
            ? max(24, r.style.width - (2 + clockWidth + 2 + kindWidth + 2))
            : Int.max
        print("")
        for (i, step) in visible.enumerated() {
            let text = clip(flatten((step["text"] as? String) ?? ""), to: room)
            print("  " + r.style.ink(.dim, pad(clocks[i], to: clockWidth))
                  + "  " + r.style.ink(kinds[i] == "error" ? .attention : .dim,
                                       pad(kinds[i], to: kindWidth))
                  + "  " + text)
        }

        print("")
        let truncated = (envelope["steps_truncated"] as? Bool) ?? false
        var summary = visible.count == steps.count
            ? "\(steps.count) step\(steps.count == 1 ? "" : "s")"
            : "The last \(visible.count) of \(steps.count) steps"
        summary += truncated ? ", and there are older ones in the log." : "."
        print(r.prose(summary))
        if let log = envelope["log_path"] as? String {
            print("")
            print(r.style.ink(.dim, r.prose(tidy(log), indent: 2)))
        }
        // ZERO EVEN WHEN THE JOB FAILED. The exit code answers for this command, and this
        // command asked a question and got one. An agent that read a failed job as a failed
        // read would retry the read forever.
        leave(.done)
    }

    // MARK: - Words

    /// One sentence about where the job stands, chosen by what the person can do about it.
    private func sentence(for job: [String: Any]) -> String {
        let status = (job["status"] as? String) ?? ""
        let started = age(job["started_at"] as? String)
        let finished = age(job["completed_at"] as? String)
        switch status {
        case "queued":
            return "Queued. It has not started yet."
        case "running":
            return started.isEmpty ? "Running." : "Running. It started \(started)."
        case "waiting", "paused":
            switch (job["waiting_on"] as? String) ?? "" {
            case "authLimitHit":
                return "Paused: the account it runs on hit its usage limit. Grux picks it "
                     + "up again when you sign in, or from the Agents tab."
            case "awaitingApproval":
                return "Paused, waiting for you to approve something in the Agents tab."
            default:
                return "Paused. The Agents tab can start it again."
            }
        case "done":
            return finished.isEmpty ? "Finished." : "Finished \(finished)."
        case "failed":
            return finished.isEmpty ? "It failed." : "It failed, \(finished)."
        case "cancelled":
            return finished.isEmpty ? "Cancelled." : "Cancelled \(finished)."
        default:
            return "Its state is \(status)."
        }
    }

    /// The state word a person reads, which is not always the one the store keeps.
    ///
    /// `waiting` is the store's word for two different situations and neither of them reads
    /// as waiting for the machine, which is what somebody scanning a list will assume.
    private func statusWord(_ status: String) -> String {
        switch status {
        case "waiting", "paused": return "paused"
        default: return status.isEmpty ? "unknown" : status
        }
    }

    private func ink(for state: String) -> TerminalStyle.Ink {
        switch state {
        case "done": return .ok
        case "running": return .accent
        case "failed", "paused": return .attention
        default: return .dim
        }
    }

    /// `assistantText` is a key. "assistant text" is what somebody reads, and splitting on
    /// the capitals means a kind added to `AgentStep` later reads properly without anybody
    /// remembering to come back here.
    private func spaced(_ key: String) -> String {
        var out = ""
        for character in key {
            if character.isUppercase && !out.isEmpty { out += " " }
            out += character.lowercased()
        }
        return out
    }

    private func pad(_ text: String, to width: Int) -> String {
        text.count >= width ? text
            : text + String(repeating: " ", count: width - text.count)
    }

    /// Clipped for a person, whole for a pipe. `room` arrives as `Int.max` when nothing is
    /// looking at a width, which is the same rule the rest of these commands follow.
    private func clip(_ text: String, to room: Int) -> String {
        guard room != Int.max, text.count > room, room > 1 else { return text }
        return String(text.prefix(room - 1)).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }

    /// A step's text is whatever a worker said, newlines and all, and a row is one line.
    /// Flattening is not clipping: it happens in a pipe too, because the alternative is a
    /// grid that stops being a grid halfway down.
    private func flatten(_ text: String) -> String {
        text.split(whereSeparator: { $0.isNewline || $0 == "\t" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func money(_ usd: Double) -> String {
        // Two decimals unless that would round a real cost to nothing, because "$0.00"
        // beside a run that made forty calls reads as broken rather than as cheap.
        usd > 0 && usd < 0.005 ? String(format: "$%.4f", usd) : String(format: "$%.2f", usd)
    }

    /// The home directory back to a tilde. Every path this prints starts with it, and the
    /// repetition costs the width that the part somebody is actually reading needs.
    private func tidy(_ path: String) -> String {
        let home = NSHomeDirectory()
        guard path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }

    private func age(_ iso: String?) -> String {
        guard let iso, let then = Self.stamp.date(from: iso) else { return "" }
        return Status.ago(Date().timeIntervalSince(then))
    }

    private func time(_ iso: String?) -> String {
        guard let iso, let then = Self.stamp.date(from: iso) else { return "" }
        return Self.clock.string(from: then)
    }

    private static let stamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Local time, and standard rather than 24 hour, because that is what the clock on this
    /// Mac says and a step log is read beside it.
    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm:ss a"
        formatter.amSymbol = "AM"
        formatter.pmSymbol = "PM"
        return formatter
    }()

    // MARK: - Did you mean

    /// The closest id to one that did not resolve.
    ///
    /// The app already resolves a leading fragment, so what reaches here is a fragment that
    /// matches nothing, and the common cause is a character copied wrong. Compared against
    /// the same number of characters that were typed, so the distance is a count of typos
    /// rather than a measure of how much of the UUID was left out.
    private func nearest(to wanted: String, client: ControlClient) -> String? {
        guard case .success(let text) = client.call(tool: "grux_agent"),
              let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8))
                as? [String: Any],
              let jobs = obj["jobs"] as? [[String: Any]] else { return nil }
        let needle = wanted.lowercased()
        let scored = jobs.compactMap { row -> (String, Int)? in
            guard let id = (row["id"] as? String)?.lowercased() else { return nil }
            return (String(id.prefix(8)),
                    Lookup.edits(needle, String(id.prefix(needle.count))))
        }
        let cutoff = max(1, needle.count / 4)
        return scored.filter { $0.1 <= cutoff }.min { $0.1 < $1.1 }?.0
    }
}
