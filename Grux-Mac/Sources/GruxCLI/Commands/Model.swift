import ArgumentParser
import Foundation
import GruxSetupCore

// MARK: - grux model

/// Which model each surface uses.
///
/// ## Why this reads from the app rather than from the file
///
/// The names live in `config.json`, and `AppState.load()` is the only thing that ever reads
/// it. There is no watcher, so a value written underneath the running app survives exactly
/// until the app next saves. Both halves of this command therefore go through the socket,
/// which makes a closed app a designed state here rather than an inconvenience.
///
/// ## Why nothing is validated
///
/// This Mac never asks a vendor whether a model exists. It could, and it would cost a
/// network call, a key for every vendor a name might belong to, and a new way to be wrong
/// while offline. Saying so plainly is worth more than a check that is right most of the
/// time, so every write says the name went in unexamined and names the moment it will
/// surface if it is wrong.
struct Model: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "model",
        abstract: "Which model a surface uses.",
        discussion: """
            With no arguments it lists every surface Grux sends a model name for, and what \
            each one is. With a surface it prints that one and where it is used. With a \
            surface and a name it sets it.

              grux model
              grux model vision
              grux model vision claude-sonnet-5

            No name is checked against a vendor, because this Mac never asks one. A name \
            that does not exist surfaces the next time that surface runs.
            """)

    @Argument(help: "chat, local, offline, vision or voice. Omit to list them all.")
    var surface: String?

    @Argument(help: "The model name to set. Omit to read.")
    var name: String?

    /// Accepted by every command, and it means one thing on all of
    /// them. See InputPolicy.
    @OptionGroup var input: InputPolicy

    func run() throws {
        let frame = Frame()
        let r = frame.renderer
        let client = ControlClient()

        var arguments: [String: Any] = [:]
        if let surface { arguments["surface"] = surface }
        if let name { arguments["name"] = name }

        switch client.call(tool: "grux_model", arguments: arguments) {
        case .failure(let why):
            // AN UNKNOWN SURFACE IS NOT A FAILURE TO REPORT, IT IS A LIST TO DRAW. The
            // refusal sentence is the right answer for an agent and the wrong one for a
            // person, who then has to go and find the five words it would not print.
            if case .toolFailed(let message) = why,
               message.hasPrefix("No surface called "), let typed = surface {
                unknown(typed, frame: frame)
            }
            frame.open(.look)
            print(r.prose(frame.explain(why)))
            leave(.failed)

        case .success(let text):
            guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8))
                    as? [String: Any] else {
                frame.open(.look)
                print(r.prose(text))
                leave(.failed)
            }
            if let rows = obj["surfaces"] as? [[String: Any]] { list(rows, frame: frame) }
            guard let row = obj["surface"] as? [String: Any] else {
                frame.open(.look)
                print(r.prose(frame.explain(
                    ControlClient.Failure.badAnswer("no surface in the reply"))))
                leave(.failed)
            }
            if name == nil { one(row, frame: frame) }
            wrote(obj, row: row, frame: frame)
        }
    }

    // MARK: - Every surface

    private func list(_ rows: [[String: Any]], frame: Frame) -> Never {
        let r = frame.renderer
        guard !rows.isEmpty else {
            // Unreachable from the handler, which carries a fixed list of five. Designed
            // anyway, because "nothing came back" printing as a blank screen under a rail
            // is the shape every one of these commands has to avoid.
            frame.open(.look)
            print(r.prose("Grux named no surfaces at all, which should not be possible. "
                          + "Run grux doctor."))
            leave(.selfRepairAvailable)
        }

        frame.open(.look, "Every surface Grux sends a model name for, and what each one is.")
        let counted = grid(rows, r: r)

        print("")
        print(r.rule())
        // EVERY ROW ACCOUNTED FOR. A count that does not add up to the list above it is
        // worse than no count, because it is the line somebody quotes later.
        var parts = ["\(counted.set) set"]
        if counted.fallback > 0 { parts.append("\(counted.fallback) falling back") }
        if counted.missing > 0 { parts.append("\(counted.missing) empty") }
        print(r.prose("\(rows.count) surfaces. " + r.list(parts) + "."))

        if counted.missing > 0 {
            print("")
            // A LIST BELONGS IN THE SENTENCE, NEVER INSIDE THE COMMAND. Splicing the ids into
            // one command line printed `grux model chat, offline and voice <name>`, which is
            // not a command anything can run, and a line shaped like a command is the line
            // somebody pastes.
            let fix = counted.missingIds.count == 1
                ? "Set it with grux model \(counted.missingIds[0]) <name>."
                : "Set " + r.list(counted.missingIds) + " with grux model <surface> <name>."
            print(r.prose("An empty surface with nothing to fall back on fails the call it "
                + "is used in. " + fix, indent: 2))
        }

        print("")
        print(r.legend(counted.states))
        print("")
        print(r.style.ink(.dim, r.prose(
            "grux model <surface> <name> changes one. Nothing here is checked against a "
            + "vendor: this Mac never asks one, so a name that does not exist surfaces "
            + "when that surface next runs.", indent: 2)))
        leave(.done)
    }

    // MARK: - One surface

    private func one(_ row: [String: Any], frame: Frame) -> Never {
        let r = frame.renderer
        let id = string(row, "id")
        frame.open(.look)
        put(r, state: state(of: row), label: id, value: shown(row), labelWidth: id.count)
        print("")
        print(r.prose(string(row, "label") + ", " + string(row, "used") + "."))
        print("")
        print(r.prose(string(row, "site"), indent: 2))
        let note = string(row, "note")
        if !note.isEmpty {
            print("")
            print(r.style.ink(.dim, r.prose(note, indent: 2)))
        }
        print("")
        print(r.style.ink(.dim, r.prose("grux model \(id) <name> changes it. The name is not "
            + "checked against a vendor.", indent: 2)))
        leave(.done)
    }

    // MARK: - A surface, set

    private func wrote(_ obj: [String: Any], row: [String: Any], frame: Frame) -> Never {
        let r = frame.renderer
        let id = string(row, "id")
        let was = (obj["was"] as? String) ?? ""
        let now = (obj["now"] as? String) ?? ""
        let changed = (obj["changed"] as? Bool) ?? false

        frame.open(.prove)
        print(r.prose(string(row, "label") + ", " + string(row, "used") + "."))
        print("")

        if changed {
            // BOTH VALUES, ONE SCREEN. A report that shows only the new name asks the reader
            // to remember what they overwrote, and the moment they most want the old one is
            // the moment they realise the new one was a typo.
            put(r, state: .skipped, label: "was", value: was.isEmpty ? "not set" : was,
                labelWidth: 3)
            put(r, state: state(of: row), label: "now", value: now.isEmpty ? "not set" : now,
                labelWidth: 3)
        } else {
            put(r, state: state(of: row), label: id, value: shown(row), labelWidth: id.count)
            print("")
            print(r.prose("That is what it was already, so nothing changed."))
        }

        let note = string(row, "note")
        if !note.isEmpty {
            print("")
            print(r.style.ink(.dim, r.prose(note, indent: 2)))
        }

        // ONLY ABOUT A NAME. Clearing a surface writes nothing a vendor could ever have
        // been asked about, and the note above already says what runs in its place.
        if !now.isEmpty {
            print("")
            print(r.prose("Nothing checked that name. This Mac never asks a vendor whether a "
                + "model exists, so a wrong one surfaces the next time \(id) runs, not now."))
        }

        if let near = nearMiss(to: now, in: (obj["inUse"] as? [[String: Any]]) ?? []) {
            // THE ONLY TYPO EVIDENCE THIS MACHINE CAN HONESTLY PRODUCE. A near miss on a
            // name already in use here is a measurement; a guess about whether a name exists
            // at a vendor is not, and this command refuses to make one.
            let lead = near.distance == 1 ? "That is one character from" : "That is close to"
            print("")
            let verb = near.surfaceCount == 1 ? "uses" : "use"
            print(r.prose("\(lead) \(near.name), which \(near.surfaces) \(verb). If you "
                + "meant that one:", indent: 2))
            print("")
            print("    " + r.style.ink(.accent, "grux model \(id) \(near.name)"))
        }

        if let caveat = obj["caveat"] as? String {
            print("")
            print(r.style.ink(.dim, r.prose(caveat, indent: 2)))
        }
        leave(.done)
    }

    // MARK: - A surface that does not exist

    private func unknown(_ typed: String, frame: Frame) -> Never {
        let r = frame.renderer
        // A SECOND CALL, ON THE ERROR PATH ONLY. The list is what makes the refusal usable
        // and this command has no way to know it without asking, so it pays one more round
        // trip exactly when somebody has already got something wrong.
        guard case .success(let text) = ControlClient().call(tool: "grux_model"),
              let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8))
                as? [String: Any],
              let rows = obj["surfaces"] as? [[String: Any]], !rows.isEmpty else {
            frame.open(.look)
            print(r.prose("No surface called \(typed). Run grux model with nothing after it "
                          + "to see the ones there are."))
            leave(.failed)
        }

        frame.open(.look, "No surface called \(typed). These are the ones there are.")
        _ = grid(rows, r: r)

        let ids = rows.map { string($0, "id") }
        let lowered = typed.lowercased()
        // The same cutoff `Lookup.nearest` uses, scaled to what was typed. Without it every
        // miss suggests three unrelated surfaces, which is worse than suggesting none.
        let cutoff = max(2, lowered.count / 3)
        let near = ids.map { (id: $0, distance: Lookup.edits(lowered, $0.lowercased())) }
            .filter { $0.distance <= cutoff }
            .sorted { ($0.distance, $0.id) < ($1.distance, $1.id) }
            .prefix(3).map { $0.id }
        if !near.isEmpty {
            print("")
            print(r.prose("Did you mean " + r.list(near) + "?", indent: 2))
        }
        leave(.failed)
    }

    // MARK: - Drawing

    private struct Counted {
        var set = 0
        var fallback = 0
        var missing = 0
        var missingIds: [String] = []
        var states: [RowState] = []
    }

    /// The rows themselves, on a grid sized from the widest id present.
    ///
    /// The id is the label because the id is what you type back. The plain words go under it
    /// dimmed, which is the house order: the answer first, what it means beneath it.
    private func grid(_ rows: [[String: Any]], r: Renderer) -> Counted {
        var counted = Counted()
        let width = rows.map { string($0, "id").count }.max() ?? 8

        for row in rows {
            let id = string(row, "id")
            let rowState = state(of: row)
            let isSet = (row["set"] as? Bool) ?? false
            let fallsBack = (row["fallsBack"] as? Bool) ?? false
            if isSet { counted.set += 1 } else if fallsBack { counted.fallback += 1 } else {
                counted.missing += 1
                counted.missingIds.append(id)
            }
            if !counted.states.contains(where: { $0.glyph == rowState.glyph }) {
                counted.states.append(rowState)
            }

            put(r, state: rowState, label: id, value: shown(row), labelWidth: width)
            print(r.style.ink(.dim, r.prose(string(row, "used"), indent: 6)))
            let note = string(row, "note")
            if !note.isEmpty { print(r.style.ink(.dim, r.prose(note, indent: 6))) }
        }
        return counted
    }

    /// One row, and on a narrow terminal the value BENEATH it rather than dropped.
    ///
    /// `Renderer.row` drops the detail column below 60 columns, which is right when the
    /// detail is a machine id sitting beside the label somebody came for. Here the detail is
    /// the model name, which is the entire answer, so a narrow terminal gives it its own
    /// line instead of printing a command about model names that shows none.
    private func put(_ r: Renderer, state: RowState, label: String, value: String,
                     labelWidth: Int) {
        guard !r.style.isNarrow else {
            print(r.row(state: state, label: label, labelWidth: 0, indent: 2))
            print(r.prose(value, indent: 6))
            return
        }
        // CLIPPED ON A TTY, WHOLE IN A PIPE. A long model id is data, and a machine reading
        // this wants the id it would have to type back, not an ellipsis.
        let room = max(12, r.style.width - labelWidth - 8)
        let clipped = (r.style.isTTY && value.count > room)
            ? String(value.prefix(room - 1)) + "\u{2026}" : value
        print(r.row(state: state, label: label, detail: clipped, labelWidth: labelWidth,
                    indent: 2))
    }

    // MARK: - Reading the reply

    private func string(_ row: [String: Any], _ key: String) -> String {
        (row[key] as? String) ?? ""
    }

    private func shown(_ row: [String: Any]) -> String {
        let value = string(row, "value")
        return value.isEmpty ? "not set" : value
    }

    /// A name with nothing set is not one state, it is two.
    ///
    /// Vision borrows the chat model when it is empty, so empty is a complete answer there.
    /// Chat, offline chat and spoken replies send the id straight on, so empty is a call
    /// that fails. One glyph for both would report a broken surface as a settled one.
    private func state(of row: [String: Any]) -> RowState {
        if (row["set"] as? Bool) ?? false { return .satisfied }
        return ((row["fallsBack"] as? Bool) ?? false) ? .optional : .needed
    }

    private struct NearMiss {
        let name: String
        let surfaces: String
        /// How many surfaces that sentence names, so the verb agrees with it.
        let surfaceCount: Int
        let distance: Int
    }

    /// The closest name ALREADY IN USE on this Mac, if anything is close.
    ///
    /// Deliberately tighter than the capability cutoff in `Lookup.nearest`, which scales to a
    /// third of what was typed. A model id runs to twenty five characters, so that rule would
    /// allow eight edits, and eight edits apart is a different model rather than a slip: this
    /// tops out at three, which is the size of a typo.
    private func nearMiss(to typed: String, in inUse: [[String: Any]]) -> NearMiss? {
        guard !typed.isEmpty else { return nil }
        let cutoff = min(3, max(2, typed.count / 8))
        return inUse.compactMap { entry -> NearMiss? in
            let candidate = string(entry, "name")
            guard !candidate.isEmpty else { return nil }
            let distance = Lookup.edits(typed.lowercased(), candidate.lowercased())
            // Distance 0 is the same name on another surface, which is not a typo and needs
            // no sentence.
            guard distance > 0, distance <= cutoff else { return nil }
            let surfaces = string(entry, "surfaces")
            return NearMiss(name: candidate,
                            surfaces: surfaces.isEmpty ? "another surface" : surfaces,
                            surfaceCount: (entry["count"] as? Int) ?? 1,
                            distance: distance)
        }
        .sorted { ($0.distance, $0.name.lowercased()) < ($1.distance, $1.name.lowercased()) }
        .first
    }
}
