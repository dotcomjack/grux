import ArgumentParser
import Foundation
import GruxSetupCore

// MARK: - grux run

/// The app's own commands, listed and started.
///
/// Grux keeps TWO lists of runnable things and draws them in two different tabs: the phase
/// gated workflows it ships with, in Workflows, and the macros a person built, in Commands.
/// Neither list knows the other exists, so "what can Grux run" had no answer anywhere on the
/// product. THE LISTING IS THE POINT OF THIS COMMAND. Starting one is the smaller half, and
/// it is deliberately the half that claims less.
struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run one of the app's own commands.",
        discussion: """
            Run it with nothing to see everything that can be run, whichever list it came \
            from. Naming one starts it. Nothing here waits for it to finish.

              grux run
              grux run smoke-hello-world
            """)

    @Argument(help: "A command id or name. Leave it out to see what there is.")
    var command: String?

    @Flag(name: .long, help: "Machine readable.")
    var json = false

    /// One runnable thing, as the app describes it.
    struct Runnable {
        let id: String
        let name: String
        let blurb: String
        /// Which registry it came from: `workflow` or `macro`.
        let source: String
        /// `ready`, `needs` (takes a setting this cannot pass), `off`, or `empty`.
        let state: String
    }

    /// Accepted by every command, and it means one thing on all of
    /// them. See InputPolicy.
    @OptionGroup var input: InputPolicy

    func run() throws {
        let frame = Frame()
        let r = frame.renderer

        // TWENTY SECONDS TO ASK WHAT EXISTS. The default is ten, which is measured against a
        // warm app, and the ordinary reason this particular call is slow is a cold launch.
        // Twice the default rides that out. Much more than that would leave somebody staring
        // at a cursor when the honest answer is that Grux is wedged, which the designed "no
        // answer" sentence says far better than waiting does.
        let catalogue = ControlClient(timeout: 20)
        var payload = ""
        switch catalogue.call(tool: "grux_run") {
        case .failure(let why):
            frame.open(.look)
            print(r.prose(frame.explain(why)))
            leave(.failed)
        case .success(let text):
            payload = text
        }
        let commands = Self.parse(payload)

        let typed = (command ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else {
            if json { print(payload); leave(.done) }
            show(commands, frame: frame)
        }

        // RESOLUTION IS EXACT, AND IT HAPPENS ON THIS SIDE. Nothing below starts something
        // that merely looks like what was typed: on a command that changes state, guessing is
        // indistinguishable from being wrong, and the only thing sent over the socket is an id
        // that came back from the app a moment ago.
        let needle = typed.lowercased()
        let sameId = commands.filter { $0.id.lowercased() == needle }
        // A tie goes to the workflow, which is the order the app resolves in too.
        var hit = sameId.first(where: { $0.source == "workflow" }) ?? sameId.first
        if hit == nil { hit = commands.first(where: { $0.name.lowercased() == needle }) }

        guard let target = hit else {
            let near = Self.nearest(typed, in: commands)
            if json {
                print(Self.jsonLine(["error": "nothing runnable is called \(typed)",
                                     "did_you_mean": near]))
                leave(.failed)
            }
            frame.open(.look)
            print(r.prose("Nothing Grux can run is called \(typed)."))
            if !near.isEmpty {
                print("")
                print(r.prose("Did you mean " + r.list(near) + "?"))
            }
            print("")
            print(r.style.ink(.dim, r.prose(commands.isEmpty
                ? "Grux is not offering anything runnable at all right now."
                : "grux run on its own lists all \(commands.count) of them.", indent: 2)))
            leave(.failed)
        }

        // FIVE MINUTES TO RUN ONE. A macro's steps execute inside the app and this call does
        // not come back until the ones marked wait for completion are done: launching an app
        // waits up to 8 seconds on its own, opening a URL sleeps 1.5, and a macro is a
        // sequence of those. At the default ten seconds this command would report that Grux
        // never answered, over a macro that was working exactly as written.
        let runner = ControlClient(timeout: 300)
        switch runner.call(tool: "grux_run", arguments: ["command": target.id]) {
        case .failure(let why):
            frame.open(.look)
            print(r.prose(frame.explain(why)))
            if case .noAnswer = why {
                print("")
                // NOT "nothing happened". The app took the call. What ran out is this side's
                // patience, and whatever was started is very probably still going.
                print(r.style.ink(.dim, r.prose("Grux may still be running it. "
                    + "grux logs --follow shows what it is doing.", indent: 2)))
            }
            // EXIT 2 WHEN NO CALL COULD EVER SUCCEED. A workflow that takes a project and a
            // macro that is switched off are both refusals no better invocation gets past:
            // somebody has to open a tab in Grux. That is what waiting on you means, and it
            // is read off the row this command already had rather than off the refusal's
            // wording, because both of those refusals happen before anything else can. A
            // closed app, a busy engine and a bad argument all stay at 1.
            if case .toolFailed = why, target.state != "ready" { leave(.waitingOnYou) }
            leave(.failed)
        case .success(let text):
            if json { print(text); leave(.done) }
            report(text, target: target, frame: frame)
        }
    }

    // MARK: - The list

    private func show(_ commands: [Runnable], frame: Frame) -> Never {
        let r = frame.renderer
        frame.open(.look, "Everything Grux can run, from both of the lists it keeps.")

        guard !commands.isEmpty else {
            // Grux ships workflows of its own, so an empty list is not an empty shelf. It is
            // an app that has not finished starting, and the action is to wait rather than to
            // go and build something.
            print(r.prose("Nothing came back as runnable. Grux ships with workflows of its "
                + "own, so an empty list means the app is still starting up. Give it a moment "
                + "and run this again."))
            leave(.done)
        }

        // Case insensitively, for the reason every other list here is: a plain < on a String
        // is an ASCII sort and files every lowercase id after every uppercase one. Sorted on
        // this side even though the app sorts too, because the order is this command's
        // promise and the app answering may be an older build than this binary.
        let rows = commands.sorted { $0.id.lowercased() < $1.id.lowercased() }

        var states: [RowState] = []
        if rows.contains(where: { $0.state == "ready" }) { states.append(.satisfied) }
        if rows.contains(where: { $0.state == "needs" }) { states.append(.needed) }
        if rows.contains(where: { Self.state(of: $0) == .skipped }) { states.append(.skipped) }
        if !states.isEmpty {
            print(r.legend(states))
            print("")
        }

        let width = rows.map(\.id.count).max() ?? 12
        for c in rows {
            guard !r.style.isNarrow else {
                // Below 60 columns `row` drops the detail entirely, and the description is
                // the whole reason to read this list, so it moves to its own line rather than
                // going over the side with the machine word.
                print(r.row(state: Self.state(of: c), label: c.id, labelWidth: width))
                print(r.style.ink(.dim, r.prose(c.blurb, indent: 6)))
                continue
            }
            print(r.row(state: Self.state(of: c), label: c.id,
                        detail: detail(for: c, labelWidth: width, r: r), labelWidth: width))
        }

        print("")
        print(r.rule())

        // COUNTS THAT RECONCILE WITH THE ROWS, and they always sum to the total. The two
        // registries are the fact this list exists to smooth over, and the summary sentence
        // is the one place it is worth saying out loud that there are two of them.
        let workflows = rows.filter { $0.source == "workflow" }.count
        let macros = rows.count - workflows
        let theirs: String = "\(workflows) workflow\(workflows == 1 ? "" : "s") built into Grux"
        let mine: String = macros == 0
            ? "none of your own yet."
            : "\(macros) command\(macros == 1 ? "" : "s") of your own."
        print(r.prose("\(rows.count) runnable: " + theirs + " and " + mine))

        let needy = rows.filter { $0.state == "needs" }.count
        if needy > 0 {
            print(r.style.ink(.dim, r.prose("\(needy) of them take a setting this command has "
                + "no way to pass, marked !. The Workflows tab in Grux asks for it, and so "
                + "does saying the phrase out loud.", indent: 2)))
        }
        let quiet = rows.filter { Self.state(of: $0) == .skipped }.count
        if quiet > 0 {
            print(r.style.ink(.dim, r.prose("\(quiet) marked . will not run: switched off, or "
                + "with no steps in them yet. The Commands tab in Grux is where both of those "
                + "are fixed.", indent: 2)))
        }

        // TWO LISTS CAN NAME THE SAME THING. Rare enough that nobody would go looking for it
        // and confusing enough to be worth one line: macro names are sanitised to [a-z0-9_]
        // and every workflow id carries a hyphen, so this takes a hand edited macros.json.
        let doubled = Dictionary(grouping: rows, by: { $0.id.lowercased() })
            .filter { $0.value.count > 1 }.keys.sorted()
        if !doubled.isEmpty {
            print(r.style.ink(.dim, r.prose("Both lists answer to " + r.list(doubled)
                + ". The workflow is the one that runs.", indent: 2)))
        }

        if let example = rows.first(where: { $0.state == "ready" }) {
            print("")
            print("    " + r.style.ink(.accent, "grux run \(example.id)"))
        }
        leave(.done)
    }

    /// The dim half of a row: what it does, then which list it came from.
    ///
    /// Clipped to the line on a terminal and left whole in a pipe. A description is DATA, and
    /// the rule here is that a machine reading gets the value entire while a person gets a
    /// line that does not wrap into a stack.
    private func detail(for c: Runnable, labelWidth: Int, r: Renderer) -> String {
        let tail = "  " + c.source
        // Two of indent, two for the glyph and its space, the label column, then the two
        // space gap `row` puts in front of the detail.
        let room = r.style.width - (2 + 2 + labelWidth + 2 + tail.count)
        if !r.style.isTTY { return c.blurb + tail }
        if room <= 12 { return c.source }
        if c.blurb.count > room { return String(c.blurb.prefix(room - 1)) + "\u{2026}" + tail }
        return c.blurb + tail
    }

    // MARK: - What happened

    private func report(_ text: String, target: Runnable, frame: Frame) -> Never {
        let r = frame.renderer
        let obj = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
        let name = (obj?["name"] as? String) ?? target.name

        frame.open(.prove)

        guard (obj?["source"] as? String) == "macro" else {
            // A WORKFLOW. `start` returns the moment the run exists and puts the first phase
            // on a Task, so every word here is about a run existing and none of it is about
            // the work being done.
            print(r.prose("Grux started \(name). It runs inside the app, one phase at a time, "
                + "and this command does not wait for it, so nothing here can tell you it "
                + "finished."))
            print("")
            print(r.row(state: .satisfied, label: "Started", detail: target.id, labelWidth: 7))
            print("")
            let phases = (obj?["phases"] as? Int) ?? 0
            let first = (obj?["first_phase"] as? String) ?? ""
            var line = ""
            if phases > 0 {
                line = "\(phases) phase\(phases == 1 ? "" : "s")"
                if !first.isEmpty { line += ", beginning with \(first)" }
                line += ". "
            }
            let tag = (obj?["log_tag"] as? String) ?? ""
            line += tag.isEmpty
                ? "Watch it with grux logs --follow."
                : "Watch it with grux logs --follow, where its lines are tagged \(tag)."
            print(r.style.ink(.dim, r.prose(line, indent: 2)))
            leave(.done)
        }

        // A MACRO, AND ITS STEPS SPLIT THREE WAYS. The registry awaits the steps marked wait
        // for completion and lets the rest go, so "ran it" is a sentence that is false about
        // part of any macro with a detached step in it. Every step is accounted for here and
        // the three numbers sum to the total by construction.
        let total = (obj?["steps"] as? Int) ?? 0
        let waited = (obj?["steps_waited"] as? Int) ?? 0
        let detached = (obj?["steps_detached"] as? Int) ?? 0
        let off = (obj?["steps_off"] as? Int) ?? 0

        var clauses: [String] = []
        if waited > 0 { clauses.append("\(waited) ran and reported back") }
        if detached > 0 {
            let verb: String = detached == 1 ? "was" : "were"
            clauses.append("\(detached) " + verb + " left running in the background")
        }
        if off > 0 {
            let verb: String = off == 1 ? "is" : "are"
            clauses.append("\(off) " + verb + " switched off")
        }

        let steps: String = "\(total) step\(total == 1 ? "" : "s")"
        let tally: String = clauses.isEmpty ? "." : ": " + r.list(clauses) + "."
        print(r.prose("Grux ran \(name). " + steps + tally))
        print("")
        print(r.row(state: .satisfied, label: "Ran", detail: target.id, labelWidth: 3))

        // The macro's own trace, one line per step, verbatim. WHAT EACH STEP REPORTED IS NOT
        // A CLAIM THIS COMMAND MAKES: a step can come back with an error and still be a step
        // that ran, so the lines are shown rather than summarised into a verdict.
        let lines = ((obj?["report"] as? String) ?? "")
            .split(separator: "\n")
            // The first line is the registry's own "running macro 'x':" header, which is the
            // sentence above said a second time.
            .dropFirst()
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if !lines.isEmpty {
            print("")
            print(r.style.ink(.dim, "  What each step reported:"))
            for line in lines { print(r.style.ink(.dim, r.prose(line, indent: 4))) }
        }
        if detached > 0 {
            print("")
            print(r.style.ink(.dim, r.prose("The background ones are still going. "
                + "grux logs --follow shows what they do.", indent: 2)))
        }
        leave(.done)
    }

    // MARK: - Reading the reply

    static func parse(_ text: String) -> [Runnable] {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(text.utf8)))
                as? [String: Any],
              let rows = obj["commands"] as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let id = row["id"] as? String, !id.isEmpty else { return nil }
            return Runnable(id: id,
                            name: (row["name"] as? String) ?? id,
                            blurb: (row["description"] as? String) ?? "",
                            source: (row["source"] as? String) ?? "",
                            state: (row["state"] as? String) ?? "ready")
        }
    }

    static func state(of c: Runnable) -> RowState {
        switch c.state {
        case "ready": return .satisfied
        case "needs": return .needed
        default: return .skipped
        }
    }

    /// The closest ids to something that did not resolve.
    ///
    /// `Lookup.nearest` reads its candidates out of the status document, which has never
    /// heard of a macro, so what gets reused is the distance function and the cutoff rather
    /// than the whole search. Both matter: a transposed letter neither contains nor is
    /// contained by the right answer, and an unscaled cutoff suggests three unrelated
    /// commands for every miss, which is worse than suggesting none.
    static func nearest(_ typed: String, in commands: [Runnable], limit: Int = 3) -> [String] {
        let lowered = typed.lowercased()
        let cutoff = max(2, lowered.count / 3)
        let scored: [(id: String, distance: Int)] = commands.map { c in
            let candidates = [c.id.lowercased(), c.name.lowercased()]
            let best = candidates.map { Lookup.edits(lowered, $0) }.min() ?? Int.max
            // A substring hit counts as one edit, so typing "smoke" finds smoke-hello-world
            // even though the edit distance between them is large.
            let contains = lowered.count >= 3 && candidates.contains { $0.contains(lowered) }
            return (id: c.id, distance: contains ? min(best, 1) : best)
        }
        // `map(\.id)` would be the shorter spelling and it does not compile: a key path
        // cannot refer to a tuple element.
        return scored.filter { $0.distance <= cutoff }
            .sorted { ($0.distance, $0.id.lowercased()) < ($1.distance, $1.id.lowercased()) }
            .prefix(limit).map { $0.id }
    }

    static func jsonLine(_ any: [String: Any]) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: any,
                                                  options: [.prettyPrinted, .sortedKeys]),
              let t = String(data: d, encoding: .utf8) else { return "{}" }
        return t
    }
}
