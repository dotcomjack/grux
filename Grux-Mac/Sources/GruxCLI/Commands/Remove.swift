import ArgumentParser
import Foundation
import GruxSetupCore

// MARK: - grux remove

/// Stop tracking one thing.
///
/// ## The whole safety story is one sentence, said three times
///
/// "Remove" reads as "delete" to everybody. So the confirmation says it, the help says it,
/// and the result says it: a project stops being watched and its files stay exactly where
/// they are, a mailbox stops being read and the mail is untouched. Every reply prints BOTH
/// halves, what stopped happening and what was left alone, because a list of what changed
/// with nothing beside it is what makes somebody go and check their folder is still there.
///
/// A removal that WOULD take away the only copy of something a person wrote is refused
/// rather than confirmed. The app decides that, not this file, and today it is `skill`: the
/// only removal Grux has for one deletes the folder holding its SKILL.md.
///
/// ## Two calls, and the first one writes nothing
///
/// The LOOK call asks the app what it is tracking. It answers whether Grux is running,
/// whether the noun is real, and what is under it, which is everything this command needs to
/// draw a did-you-mean, an empty state and a cost screen without having changed anything
/// first. The second call is the only one that writes, and it goes with the CANONICAL id off
/// the first, so what was confirmed on screen is what the app is asked to remove.
struct Remove: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Stop tracking one thing. Never deletes it.",
        discussion: """
            Removing stops Grux tracking something. IT NEVER DELETES THE THING. A project \
            stops being watched and its files stay exactly where they are. A mailbox stops \
            being read and the mail is untouched.

            Run it with no noun to see the nouns, or with a noun alone to see what Grux is \
            tracking under that noun.

              grux remove                       the nouns, and how many of each
              grux remove project               every project Grux watches
              grux remove project Jordan2       stop watching that one

            It asks you to type the name back before it changes anything, because y is \
            muscle memory and typing the name is a decision. --yes skips that.
            """)

    @Argument(help: "feature, project, brand, mailbox, repo, domain, schedule or skill.")
    var noun: String?

    @Argument(help: "Which one. Omit to see what is there.")
    var value: String?

    @Flag(name: .long, help: "Do not ask. For a script that has already decided.")
    var yes = false

    @Flag(name: .long, help: "Never wait for a person. Fails and names --yes instead.")
    var noInput = false

    @Flag(name: .long, help: "Machine readable, and it never asks.")
    var json = false

    func run() throws {
        let frame = Frame()
        let r = frame.renderer
        let client = ControlClient()

        let askedNoun = (noun ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let askedValue = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        // The machine surface leaves here and never comes back, because none of the screens
        // below are for it and the prompt in the middle would hang it.
        if json { machine(client: client, frame: frame, noun: askedNoun, value: askedValue) }

        // ---- LOOK. Asks the app what is there and changes nothing. ------------------------
        var lookup: [String: Any] = [:]
        if !askedNoun.isEmpty { lookup["noun"] = askedNoun }

        let looked: [String: Any]
        switch client.call(tool: "grux_remove", arguments: lookup) {
        case .failure(let why):
            frame.open(.look)
            print(r.prose(frame.explain(why)))
            // A REFUSAL IS NOT A BAD CALL. `skill` comes back refused however it is asked,
            // so no better invocation exists and exit 1 would send an agent round the loop
            // again. Exit 2 is the code for "a person has to do something on this Mac",
            // which is exactly what the refusal asks for.
            if case .toolFailed = why, Remove.isSkillNoun(askedNoun) {
                print("")
                print(r.style.ink(.dim, r.prose("Nothing was removed and nothing was deleted.",
                                                indent: 2)))
                leave(.waitingOnYou)
            }
            leave(.failed)
        case .success(let text):
            guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8))
                    as? [String: Any] else {
                frame.open(.look)
                print(r.prose(text))
                leave(.failed)
            }
            looked = obj
        }

        // No noun. The nouns, what each one stops, and how many of each there are.
        guard !askedNoun.isEmpty else {
            showNouns(looked, frame: frame)
            // EXIT 1, not 0. Nothing was removed and the invocation is incomplete, so an
            // agent should fix its own call rather than read this as a removal that worked.
            leave(.failed)
        }

        let items = (looked["items"] as? [[String: Any]]) ?? []
        let tracked = items.filter { ($0["tracked"] as? Bool) ?? true }
        // The app answers with the canonical noun, so `grux remove projects` reads back as
        // project rather than being pluralised a second time into projectses.
        let shownNoun = (looked["noun"] as? String) ?? askedNoun

        guard !askedValue.isEmpty else {
            showItems(noun: shownNoun, looked: looked, items: items, frame: frame)
            print("")
            print(r.style.ink(.dim, r.prose(tracked.isEmpty
                ? "grux add \(shownNoun) is what starts Grux tracking one."
                : "grux remove \(shownNoun) <name> removes one. It asks first.", indent: 2)))
            leave(.failed)
        }

        // ---- Which one, and the three ways that goes wrong -------------------------------
        let hits = items.filter { Remove.matches(askedValue, $0) }

        guard hits.count == 1, let item = hits.first else {
            frame.open(.look)
            if hits.count > 1 {
                // NEVER GUESS BETWEEN TWO. A typed confirmation cannot catch this one,
                // because the word typed is right and the thing behind it is not.
                print(r.prose("More than one thing here answers to \(askedValue), and Grux "
                              + "will not pick for you."))
                print("")
                // THE THING THAT TELLS THEM APART, not the thing they already typed. Two
                // schedules can share a title, and printing the title twice with the same
                // summary beside it leaves somebody exactly where they started.
                let width = hits.compactMap { ($0["label"] as? String)?.count }.max() ?? 12
                for hit in hits {
                    let alias = (hit["alias"] as? String) ?? ""
                    let apart = alias.isEmpty ? ((hit["detail"] as? String) ?? "") : alias
                    print(r.row(state: .needed, label: (hit["label"] as? String) ?? "",
                                detail: apart.isEmpty ? nil : apart,
                                labelWidth: width, indent: 4))
                }
                print("")
                print(r.style.ink(.dim, r.prose("Name one by the value in the dim column, or "
                                                + "remove it in the Grux window where you can "
                                                + "see which is which.", indent: 2)))
                leave(.failed)
            }
            // Not there. Plainly, then what IS there, then the nearest thing to what was
            // typed. A miss that only says no sends somebody to read the whole list.
            print(r.prose("Grux is not tracking \(shownNoun) \(askedValue)."))
            let near = Remove.nearest(askedValue, in: items)
            if !near.isEmpty {
                print("")
                print(r.prose("Did you mean " + r.list(near) + "?", indent: 2))
            }
            if !tracked.isEmpty {
                print("")
                showRows(tracked, frame: frame)
                print("")
                print(r.rule())
                print(r.prose("\(tracked.count) \(Remove.plural(shownNoun, tracked.count)), "
                              + "and none of them is \(askedValue)."))
            } else {
                print("")
                print(r.prose("Grux is not tracking any \(Remove.plural(shownNoun, 2)) at "
                              + "all, so there is nothing here to remove.", indent: 2))
            }
            leave(.failed)
        }

        let id = (item["id"] as? String) ?? askedValue
        let label = (item["label"] as? String) ?? id
        let detail = (item["detail"] as? String) ?? ""
        // WHAT THE WRITE IS SENT, which is not always what a person types. Two schedules can
        // share a title, so the app hands back an alias that is unique and this sends that:
        // sending the ambiguous name would have the app refuse the very row just confirmed.
        let alias = (item["alias"] as? String) ?? ""
        let sendValue = alias.isEmpty ? id : alias

        guard (item["tracked"] as? Bool) ?? true else {
            // IDEMPOTENT, and it exits 0. An agent runs a command twice; the second run
            // finds the world already the way it asked for, which is not a failure.
            frame.open(.prove)
            print(r.row(state: .skipped, label: label, detail: "already not tracked",
                        labelWidth: label.count))
            print("")
            print(r.prose("Grux was already not tracking \(label), so nothing changed and "
                          + "nothing was deleted."))
            leave(.done)
        }

        // ---- COST. What this will stop, and what it will not touch. ----------------------
        let stops = (looked["stops"] as? [String]) ?? []
        let keeps = (looked["keeps"] as? [String]) ?? []

        frame.open(.cost, "This stops Grux tracking it. It does not delete it.")
        // The same two column fact rows `grux undo` puts on its cost screen: a label on the
        // left, the value dimmed on the right, sized from the widest label present.
        let costWidth = 8
        print(r.row(state: .satisfied, label: "Removing", detail: label,
                    labelWidth: costWidth))
        if !detail.isEmpty {
            print(r.row(state: .satisfied, label: "Which is",
                        detail: Remove.fit(detail, r, used: costWidth + 6),
                        labelWidth: costWidth))
        }
        if !stops.isEmpty {
            print("")
            print("  " + r.heading("What stops"))
            for sentence in stops { print(r.prose(sentence, indent: 4)) }
        }
        if !keeps.isEmpty {
            print("")
            print("  " + r.heading("What is left alone"))
            for sentence in keeps { print(r.prose(sentence, indent: 4)) }
        }

        if !yes {
            guard !noInput, RawMode.isSupported else {
                print("")
                print(r.prose(noInput
                    ? "You passed --no-input and this asks before it changes anything, so "
                      + "pass --yes as well if you are sure."
                    : "Nothing is attached to this terminal, so there is nobody to ask: pass "
                      + "--yes if you are sure."))
                leave(.failed)
            }
            // TYPED, not a keystroke. `y` is muscle memory; typing the name is a decision,
            // and it is the last point where reading the two lists above still costs nothing.
            let typed = InputPolicy.ask([
                "",
                "  Type the name to confirm, or anything else to stop.",
                "  " + r.style.ink(.accent, id),
                "",
            ])
            // Case insensitively, because a capital letter is not a different decision and
            // the name on screen is whatever the app happens to store.
            guard typed.lowercased() == id.lowercased() else {
                print("")
                print(r.prose("Left everything alone."))
                leave(.done)
            }
        }

        // ---- PROVE. The only call that writes. -------------------------------------------
        frame.open(.prove)
        switch client.call(tool: "grux_remove",
                           arguments: ["noun": shownNoun, "value": sendValue]) {
        case .failure(let why):
            print(r.prose(frame.explain(why)))
            print("")
            print(r.style.ink(.dim, r.prose("Nothing was removed.", indent: 2)))
            leave(.failed)
        case .success(let text):
            guard let done = try? JSONSerialization.jsonObject(with: Data(text.utf8))
                    as? [String: Any] else {
                print(r.prose(text))
                leave(.failed)
            }
            report(done, label: label, noun: shownNoun, left: tracked.count - 1, frame: frame)
            leave(.done)
        }
    }

    // MARK: - The machine surface

    /// `--json`, which is the same two calls with none of the screens and no prompt.
    ///
    /// It asks for `--yes` rather than prompting, one sentence, exit 1. A command that hangs
    /// waiting for a person who is not there is the worst thing this could do to an agent
    /// driving it, and an agent is the only caller that passes this flag.
    private func machine(client: ControlClient, frame: Frame, noun: String,
                         value: String) -> Never {
        // A noun or a value missing is a READ, and the app's own reply is already the answer:
        // the nouns and their counts, or what is tracked under one. It still leaves with 1,
        // because nothing was removed and the call is incomplete.
        if noun.isEmpty || value.isEmpty {
            var lookup: [String: Any] = [:]
            if !noun.isEmpty { lookup["noun"] = noun }
            switch client.call(tool: "grux_remove", arguments: lookup) {
            case .failure(let why):
                emit(["error": frame.explain(why), "removed": false])
                if case .toolFailed = why, Remove.isSkillNoun(noun) {
                    leave(.waitingOnYou)
                }
                leave(.failed)
            case .success(let text):
                print(text)
                leave(.failed)
            }
        }

        guard yes else {
            emit(["error": "This changes what Grux tracks, so it asks first. Pass --yes to "
                         + "remove \(value) without being asked.",
                  "removed": false])
            leave(.failed)
        }

        switch client.call(tool: "grux_remove", arguments: ["noun": noun, "value": value]) {
        case .failure(let why):
            emit(["error": frame.explain(why), "removed": false])
            if case .toolFailed = why, Remove.isSkillNoun(noun) {
                leave(.waitingOnYou)
            }
            leave(.failed)
        case .success(let text):
            print(text)
            leave(.done)
        }
    }

    private func emit(_ object: [String: Any]) {
        if let d = try? JSONSerialization.data(withJSONObject: object,
                                               options: [.prettyPrinted, .sortedKeys]),
           let t = String(data: d, encoding: .utf8) { print(t) }
    }

    // MARK: - The result

    private func report(_ done: [String: Any], label: String, noun: String, left: Int,
                        frame: Frame) {
        let r = frame.renderer
        let changed = (done["changed"] as? Bool) ?? true
        let name = (done["label"] as? String) ?? label

        guard changed else {
            print(r.row(state: .skipped, label: name, detail: "already not tracked",
                        labelWidth: name.count))
            print("")
            print(r.prose("Nothing changed and nothing was deleted."))
            return
        }

        print(r.row(state: .satisfied, label: name, detail: "no longer tracked",
                    labelWidth: name.count))

        // BOTH HALVES, ALWAYS, and the second one is the reason this command is safe to run.
        let stopped = (done["stopped"] as? [String]) ?? []
        let kept = (done["kept"] as? [String]) ?? []
        if !stopped.isEmpty {
            print("")
            print("  " + r.heading("What stopped"))
            for sentence in stopped { print(r.prose(sentence, indent: 4)) }
        }
        if !kept.isEmpty {
            print("")
            print("  " + r.heading("What was left alone"))
            for sentence in kept { print(r.prose(sentence, indent: 4)) }
        }
        if let note = done["note"] as? String, !note.isEmpty {
            print("")
            print(r.style.ink(.attention, r.prose(note, indent: 2)))
        }
        // THE ONE COPY, HANDED BACK. A brand rule and an agent prompt exist nowhere else on
        // this Mac, so the app returns them rather than letting a removal take the words
        // with it. NEVER CLIPPED, on a terminal or anywhere else: half of the only copy is
        // not a copy, and this is the one value on screen that cannot be looked up again.
        if let restore = done["restore"] as? String, !restore.isEmpty {
            print("")
            print("  " + r.heading("Yours, in case you want it back"))
            print(r.style.ink(.dim, r.prose(restore, indent: 4)))
        }

        print("")
        print(r.rule())
        print(r.prose(left <= 0
            ? "Grux is tracking no \(Remove.plural(noun, 2)) now."
            : "\(left) \(Remove.plural(noun, left)) still tracked. "
              + "grux remove \(noun) lists them."))
    }

    // MARK: - The screens that only list

    private func showNouns(_ looked: [String: Any], frame: Frame) {
        let r = frame.renderer
        frame.open(.look, "What Grux is tracking, and what stops if you remove one.")

        let nouns = (looked["nouns"] as? [[String: Any]]) ?? []
        guard !nouns.isEmpty else {
            print(r.prose("This Grux does not list any nouns, which means the app and this "
                          + "binary came from different builds."))
            return
        }

        print(r.legend([.satisfied, .skipped]))
        print("")
        let width = nouns.compactMap { ($0["noun"] as? String)?.count }.max() ?? 8
        for row in nouns {
            let name = (row["noun"] as? String) ?? ""
            let count = (row["tracked"] as? Int) ?? 0
            let removable = (row["removable"] as? Bool) ?? true
            // The count survives even when the noun cannot be removed here, because a
            // number that disappears from one row is a row nobody can reconcile.
            let held = count == 0 ? "none" : "\(count) tracked"
            let detail = removable ? held : "\(held), not removable here"
            print(r.row(state: (removable && count > 0) ? .satisfied : .skipped,
                        label: name, detail: detail, labelWidth: width, indent: 4))
            if let bundles = row["bundles"] as? String, !bundles.isEmpty {
                print(r.style.ink(.dim, r.prose(bundles, indent: 6)))
            }
        }

        print("")
        print(r.rule())
        if let promise = looked["promise"] as? String {
            print(r.prose(promise))
        }
        print("")
        print(r.style.ink(.dim, r.prose("grux remove <noun> shows what is under one. "
            + "grux remove <noun> <name> removes it, and asks first.", indent: 2)))
    }

    private func showItems(noun: String, looked: [String: Any], items: [[String: Any]],
                           frame: Frame) {
        let r = frame.renderer
        let tracked = items.filter { ($0["tracked"] as? Bool) ?? true }
        frame.open(.look, "What Grux is tracking as \(Remove.plural(noun, 2)). Nothing here "
                          + "has been removed.")

        guard !tracked.isEmpty else {
            // THE EMPTY STATE IS THE NORMAL ONE for most of these nouns on most Macs, so it
            // must not read like a failure.
            print(r.prose("Grux is not tracking any \(Remove.plural(noun, 2))."))
            if items.count > tracked.count {
                print("")
                print(r.style.ink(.dim, r.prose("\(items.count - tracked.count) are known "
                    + "and already off.", indent: 2)))
            }
            return
        }

        showRows(tracked, frame: frame)
        print("")
        print(r.rule())
        print(r.prose("\(tracked.count) \(Remove.plural(noun, tracked.count))."))
        // EVERY ROW ACCOUNTED FOR. Features come back with the off ones included, and a
        // count that silently dropped them would not match the registry anybody can read.
        if items.count > tracked.count {
            print(r.style.ink(.dim, r.prose("\(items.count - tracked.count) more are known "
                + "and already off, so there is nothing to remove about them.", indent: 2)))
        }
        if let stops = (looked["stops"] as? [String])?.first {
            print("")
            print(r.style.ink(.dim, r.prose(stops, indent: 2)))
        }
    }

    private func showRows(_ rows: [[String: Any]], frame: Frame) {
        let r = frame.renderer
        // The grid is sized from the WIDEST LABEL PRESENT, never a fixed guess.
        let width = rows.compactMap { ($0["label"] as? String)?.count }.max() ?? 12
        for row in rows.sorted(by: {
            // Case insensitively. A plain < on a String files every lowercase label last.
            (($0["label"] as? String) ?? "").lowercased()
                < (($1["label"] as? String) ?? "").lowercased()
        }) {
            print(Remove.line(row, width: width, renderer: r, indent: 4))
        }
    }

    private static func line(_ row: [String: Any], width: Int, renderer r: Renderer,
                             indent: Int) -> String {
        let label = (row["label"] as? String) ?? ""
        let id = (row["id"] as? String) ?? label
        var detail = (row["detail"] as? String) ?? ""
        // The id earns the dim column when it is not just the label again: that is the word
        // somebody types back, so it has to be on screen somewhere.
        if detail.isEmpty && id.lowercased() != label.lowercased() { detail = id }
        let room = max(12, r.style.width - max(width, label.count) - indent - 4)
        return r.row(state: .satisfied, label: label,
                     detail: detail.isEmpty ? nil : fit(detail, r, used: 0, room: room),
                     labelWidth: width, indent: indent)
    }

    // MARK: - Small shared rules

    /// Clip a long value on a terminal, keep it whole in a pipe. DATA only: a sentence is
    /// wrapped by `prose`, never cut.
    private static func fit(_ text: String, _ r: Renderer, used: Int, room: Int? = nil)
        -> String {
        guard r.style.isTTY else { return text }
        let limit = room ?? max(20, r.style.width - used - 4)
        guard text.count > limit else { return text }
        return String(text.prefix(limit - 1)) + "\u{2026}"
    }

    /// The one noun the app refuses however it is asked, and the only reason this command
    /// ever leaves with 2.
    ///
    /// EXACTLY, never a prefix. `hasPrefix("skill")` also matched `skillz`, which is a
    /// misspelling the app answers with "No noun called skillz": a bad invocation, fixable
    /// by a better call, and exit 2 tells an agent the opposite, that it should stop and
    /// wake somebody. Singular and plural both, because `removalNoun` accepts either and
    /// the refusal that comes back is the same one.
    private static func isSkillNoun(_ noun: String) -> Bool {
        let n = noun.lowercased()
        return n == "skill" || n == "skills"
    }

    private static func matches(_ typed: String, _ row: [String: Any]) -> Bool {
        let t = typed.lowercased()
        for key in ["id", "label", "alias"] {
            if let v = row[key] as? String, !v.isEmpty, v.lowercased() == t { return true }
        }
        return false
    }

    /// The closest names to something that did not resolve.
    ///
    /// Reuses `Lookup.edits` rather than growing a second Levenshtein, and keeps the two
    /// rules `Lookup.nearest` measured its way to: a substring hit counts as one edit, so
    /// `mail` finds a long address, and the cutoff scales with what was typed, so a miss
    /// suggests nothing rather than three unrelated names.
    private static func nearest(_ needle: String, in rows: [[String: Any]],
                                limit: Int = 3) -> [String] {
        let lowered = needle.lowercased()
        guard !lowered.isEmpty else { return [] }

        struct Scored { let id: String; let distance: Int }
        let scored: [Scored] = rows.compactMap { row in
            guard let id = row["id"] as? String, !id.isEmpty else { return nil }
            let candidates = [id.lowercased(), ((row["label"] as? String) ?? id).lowercased()]
            let best = candidates.map { Lookup.edits(lowered, $0) }.min() ?? Int.max
            let contains = candidates.contains { $0.contains(lowered) && lowered.count >= 3 }
            return Scored(id: id, distance: contains ? min(best, 1) : best)
        }
        let cutoff = max(2, lowered.count / 3)
        return scored.filter { $0.distance <= cutoff }
            .sorted { ($0.distance, $0.id.lowercased()) < ($1.distance, $1.id.lowercased()) }
            .prefix(limit).map(\.id)
    }

    /// `mailbox` is the reason this is not `+ "s"`.
    private static func plural(_ noun: String, _ count: Int) -> String {
        guard count != 1 else { return noun }
        if noun.hasSuffix("x") || noun.hasSuffix("s") || noun.hasSuffix("ch") {
            return noun + "es"
        }
        return noun + "s"
    }
}
