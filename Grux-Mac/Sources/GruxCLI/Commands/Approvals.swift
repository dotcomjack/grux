import ArgumentParser
import Foundation
import GruxSetupCore

// MARK: - grux approvals

/// What the agent may do without asking, and what is waiting on an answer.
///
/// ## The read never touches the app, and that is the point
///
/// Both halves live in files Grux writes: `~/.grux/jax/autonomy.json` holds the mode and the
/// hard stop, `~/.grux/jax/approvals.json` holds the queue. Reading them here means the
/// question "what has been held back for me" answers with Grux closed, which is exactly the
/// state somebody is in when they think to ask it. Only the three writes need the app,
/// because the app is the one process allowed to actually run an approved action.
///
/// ## Why the list is clipped and the count is not
///
/// The queue on the machine this was written against holds 928 waiting items in 780 KB, and
/// 910 of them are the same request. Printing all of them would be unreadable, and printing
/// six without saying so would misrepresent the size of the backlog, so the true count, the
/// clip and the repeat are all stated together directly under the list.
struct Approvals: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "approvals",
        abstract: "What the agent may do without asking.",
        discussion: """
            With no flags it prints the mode, the hard stop and what is waiting, oldest \
            first. That half reads files and works with Grux closed.

              grux approvals --limit 40          more of the queue
              grux approvals --mode observe      how far Grux goes on its own.
                                                 Raising it asks first.
              grux approvals --approve <id>      let one waiting item run. Asks first.
              grux approvals --skip <id>         refuse one waiting item

            An id may be shortened to any prefix that names exactly one item.
            """)

    @Option(name: .long, help: "How far Grux goes on its own: simulate, observe or live.")
    var mode: String?

    @Option(name: .long, help: "The id of one waiting item. Runs it, and asks first.")
    var approve: String?

    @Option(name: .long, help: "The id of one waiting item. Refuses it, and runs nothing.")
    var skip: String?

    @Flag(name: .long,
          help: ArgumentHelp("Do not ask before approving, or before raising the mode. "
                             + "For a script that already did."))
    var yes = false

    @Option(name: .long, help: "How many waiting items to list. Default 6.")
    var limit: Int = 6

    @Flag(name: .long, help: "Machine readable.")
    var json = false

    // MARK: - The three modes

    /// A mode name tells nobody anything, so each one carries the sentence that says what it
    /// permits, and that sentence is what leads the screen.
    ///
    /// The names mirror `AutonomyMode` in the app, which this binary cannot import: GruxCLI
    /// links GruxSetupCore, not the app target. Holding the list here is also what lets
    /// `--mode nonsense` fail as a bad invocation with Grux closed, rather than failing as
    /// "Grux is not running" and sending somebody to launch an app they did not need.
    struct Mode {
        let id: String
        let label: String
        let permits: String
    }

    static let modes: [Mode] = [
        Mode(id: "simulate", label: "Simulate",
             permits: "Grux works out its own next move and writes it down. It starts "
                    + "nothing by itself, so nothing it plans reaches anybody."),
        Mode(id: "observe", label: "Observe",
             permits: "Grux works out its own next move and puts it in the queue below. "
                    + "Nothing it plans runs until you say yes to it by name."),
        Mode(id: "live", label: "Live",
             permits: "Grux works out its own next move and runs it without asking. "
                    + "Everything it does still goes through the gate first."),
    ]

    static func mode(_ id: String) -> Mode? {
        modes.first { $0.id == id.lowercased() }
    }

    // MARK: - What is on disk

    /// One queue entry, decoded leniently.
    ///
    /// EVERY FIELD IS OPTIONAL ON PURPOSE. `decode([Item].self)` throws for the whole array
    /// when a single element is missing a key it required, so one malformed row would take a
    /// 900 item queue with it and this command would print "nothing is waiting", which is the
    /// most dangerous wrong answer it could give. A missing value renders as unknown instead.
    /// The app decodes the same file leniently, for the same reason.
    struct Item: Decodable {
        struct Action: Decodable {
            var summary: String?
            var target: String?
            var detail: [String: String]?
            var isSpend: Bool?
            var isExternalComms: Bool?
            var isPublicPost: Bool?
            var touchesSecrets: Bool?
        }
        var id: String?
        var action: Action?
        var createdAt: String?
        var resolvedAt: String?
        var urgent: Bool?
        var reason: String?
        var state: String?
    }

    /// An item with its stamp already parsed, so 929 rows go through one formatter rather
    /// than one formatter per row.
    struct Waiting {
        let item: Item
        let created: Date?

        var id: String { item.id ?? "" }
        var summary: String {
            let s = item.action?.summary ?? ""
            return s.isEmpty ? "an action that did not record what it is" : s
        }
        var target: String { item.action?.target ?? "" }
        var runs: String? {
            let tool = item.action?.detail?["__replay_tool"] ?? ""
            return tool.isEmpty ? nil : tool
        }
        var isPending: Bool { (item.state ?? "pending") == "pending" }
        var waited: TimeInterval? { created.map { Date().timeIntervalSince($0) } }
    }

    struct Store {
        var modeID: String
        /// False when autonomy.json has never been written, which means the app's own
        /// default rather than an absent answer.
        var modeChosen: Bool
        var killed: Bool
        var rows: [Waiting]
        var queueExists: Bool
        var queueUnreadable: Bool
        var queueAge: TimeInterval?
    }

    static var jaxDir: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".grux", isDirectory: true)
            .appendingPathComponent("jax", isDirectory: true)
    }
    static var autonomyURL: URL { jaxDir.appendingPathComponent("autonomy.json") }
    static var queueURL: URL { jaxDir.appendingPathComponent("approvals.json") }

    // MARK: - Run

    /// Accepted by every command, and it means one thing on all of
    /// them. See InputPolicy.
    @OptionGroup var input: InputPolicy

    func run() throws {
        let frame = Frame()

        // ONE WRITE PER INVOCATION. These three change different things, and running two at
        // once leaves the reader unable to tell which one a confirmation belonged to.
        //
        // ON THE SAME TWO STREAMS AS EVERY OTHER WRITE PATH. This guard kept `frame.open`
        // and `print` when the rest of the file moved to `say`, so it was the one place
        // `--json` still put the human screen on the machine surface. Measured on the
        // shipped binary: `grux approvals --mode live --skip <id> --json` wrote 147 bytes of
        // rail and prose to stdout, left stderr empty, emitted no object at all and exited
        // 1, so `| jq .` failed to parse.
        //
        // The sentence names the flags that were ACTUALLY passed rather than all three,
        // because a caller who passed two does not need to be told about the third.
        let asked = [("--mode", mode), ("--approve", approve), ("--skip", skip)]
            .filter { $0.1 != nil }.map { $0.0 }
        if asked.count > 1 {
            sayRail(frame, .look)
            say(frame.renderer.prose("Do one of these at a time. "
                + frame.renderer.list(asked) + " each change something different."))
            sayOutcome("conflicting_writes", ["flags": asked, "changed": false])
            leave(.failed)
        }

        let store = Self.read()

        if let mode { setMode(mode, store: store, frame: frame) }
        if let approve { approveOne(approve, store: store, frame: frame) }
        if let skip { skipOne(skip, store: store, frame: frame) }
        show(store, frame: frame)
    }

    // MARK: - Reading the two files

    static func read() -> Store {
        var modeID = modes[0].id      // simulate, which is the app's own default
        var modeChosen = false
        var killed = false
        if let data = try? Data(contentsOf: autonomyURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            modeChosen = true
            if let m = obj["mode"] as? String, !m.isEmpty { modeID = m.lowercased() }
            killed = (obj["killed"] as? Bool) ?? false
        }

        let manager = FileManager.default
        let exists = manager.fileExists(atPath: queueURL.path)
        var rows: [Waiting] = []
        var unreadable = false
        var age: TimeInterval?

        if exists {
            age = (try? manager.attributesOfItem(atPath: queueURL.path))
                .flatMap { $0[.modificationDate] as? Date }
                .map { Date().timeIntervalSince($0) }
            if let data = try? Data(contentsOf: queueURL),
               let items = try? JSONDecoder().decode([Item].self, from: data) {
                let stamp = ISO8601DateFormatter()
                rows = items.map { item in
                    Waiting(item: item,
                            created: item.createdAt.flatMap { stamp.date(from: $0) })
                }
            } else {
                unreadable = true
            }
        }

        return Store(modeID: modeID, modeChosen: modeChosen, killed: killed, rows: rows,
                     queueExists: exists, queueUnreadable: unreadable, queueAge: age)
    }

    /// Oldest first, and a row whose stamp will not parse sorts LAST rather than first.
    ///
    /// Sorting an unknown date as the distant past would put it at the top of a screen whose
    /// whole promise is "these have waited longest", which is the one place a missing value
    /// must not be allowed to masquerade as an extreme one.
    static func oldestFirst(_ rows: [Waiting]) -> [Waiting] {
        rows.sorted { ($0.created ?? .distantFuture) < ($1.created ?? .distantFuture) }
    }

    /// The one request this queue is mostly made of, when it is mostly made of one.
    ///
    /// Measured on this Mac: 910 of the 928 waiting items are the same design_generate call.
    /// Six of the oldest therefore read as six separate decisions when they are one decision
    /// made 910 times, and naming the repeat is the difference between a list somebody can
    /// act on and a list they scroll past.
    static func dominant(_ rows: [Waiting]) -> (target: String, count: Int)? {
        var counts: [String: Int] = [:]
        for row in rows where !row.target.isEmpty { counts[row.target, default: 0] += 1 }
        let ranked = counts.sorted { a, b in
            a.value != b.value ? a.value > b.value : a.key.lowercased() < b.key.lowercased()
        }
        guard let best = ranked.first, best.value * 2 > rows.count else { return nil }
        return (best.key, best.value)
    }

    // MARK: - The screen

    private func show(_ store: Store, frame: Frame) -> Never {
        let r = frame.renderer

        if store.queueUnreadable {
            if json {
                print(Self.jsonText(["error": "the queue file will not parse",
                                     "queue_file": Self.queueURL.path]))
                leave(.waitingOnYou)
            }
            frame.open(.look)
            print(r.prose("The queue at \(Self.queueURL.path) will not parse, so neither this "
                + "command nor Grux itself can read what is in it."))
            print("")
            print(r.prose("Grux writes it atomically, so a half written file should not be "
                + "possible and something else has edited it. Move it aside to start a clean "
                + "queue, and keep the copy if what was in it matters.", indent: 2))
            // NOBODY CAN CALL THIS COMMAND INTO SUCCESS. A better invocation does not help and
            // grux doctor does not look at this file, so it is a person's turn.
            leave(.waitingOnYou)
        }

        let pending = Self.oldestFirst(store.rows.filter(\.isPending))
        let shown = Array(pending.prefix(max(1, limit)))
        let answered = store.rows.count - pending.count

        if json { emitJSON(store, pending: pending, shown: shown); leave(.done) }

        // The whole command is the answer, so it opens on PROVE and stays there.
        frame.open(.prove)

        // ---- the answer first ------------------------------------------------------------
        let known = Self.mode(store.modeID)
        if let known {
            print(r.prose("Grux is in \(known.label) mode. " + known.permits))
        } else {
            // VERSION SKEW GETS ITS OWN SENTENCE. A mode this binary does not know means the
            // app that wrote the file is a different build, and the reader needs to hear that
            // rather than see a blank where the explanation should be.
            print(r.prose("Grux is in a mode called \(store.modeID), which this grux does not "
                + "know. It knows " + r.list(Self.modes.map(\.id)) + ", so the two came from "
                + "different builds."))
        }
        print("")

        let width = ["Mode", "Hard stop", "Waiting"].map(\.count).max() ?? 9
        let modeLabel = known?.label ?? store.modeID
        print(Self.stat(r, known == nil ? .needed : .satisfied, "Mode",
                        store.modeChosen ? modeLabel : "\(modeLabel), never changed",
                        width: width))
        print(Self.stat(r, store.killed ? .needed : .satisfied, "Hard stop",
                        store.killed ? "ON" : "off", width: width))
        print(Self.stat(r, pending.isEmpty ? .satisfied : .needed, "Waiting",
                        pending.isEmpty ? "nothing"
                            : "\(pending.count) thing\(pending.count == 1 ? "" : "s")",
                        width: width))

        // ---- the hard stop, unmissable when it is on -------------------------------------
        if store.killed {
            print("")
            print(r.row(state: .needed, label: "THE HARD STOP IS ON", labelWidth: 0))
            print(r.style.ink(.attention, r.prose(
                "Nothing Grux would start by itself runs, in any mode, Live included, until "
                + "this is cleared in the Autonomy panel in Jax Command inside Grux. "
                + "Approving something here still runs it: the hard stop governs what Grux "
                + "starts, not what you ask it for.", indent: 4)))
        }

        if !pending.isEmpty {
            print("")
            print(r.legend([.satisfied, .needed]))
        }

        // ---- what is waiting -------------------------------------------------------------
        if pending.isEmpty {
            print("")
            if !store.queueExists {
                // THE EXPECTED STATE OF A MAC NOBODY HAS ASKED FOR ANYTHING BIG YET, and it
                // must not read like a fault.
                print(r.prose("Nothing has ever been held back for you on this Mac. Grux "
                    + "writes the queue the first time it is asked to do something the gate "
                    + "does not read as routine and reversible."))
            } else {
                print(r.prose("Nothing is waiting on you."
                    + (answered > 0 ? " \(answered) item\(answered == 1 ? " has" : "s have") "
                       + "been answered." : "")))
                print("")
                print(r.style.ink(.dim, r.prose(Self.freshness(store))))
            }
            leave(.done)
        }

        print("")
        print("  " + r.heading("OLDEST FIRST"))
        print("")

        let ageWidth = shown.map { Self.span($0.waited).count }.max() ?? 7
        let idColumn = 6 + ageWidth + 2
        for row in shown {
            let waited = Self.span(row.waited)
            let pad = waited + String(repeating: " ", count: max(0, ageWidth - waited.count))
            // A summary is DATA, so it is clipped for a terminal and kept whole in a pipe.
            let text = Self.clip(row.summary, to: max(16, r.style.width - idColumn),
                                 tty: r.style.isTTY)
            print("    " + r.style.ink(RowState.needed.ink, RowState.needed.glyph) + " "
                  + r.style.ink(.dim, pad) + "  " + text)

            // The id is what you type, so it is never clipped. It sits under the summary
            // unless a 36 character id plus that gutter would run off the terminal, which it
            // does at the 40 column floor, where it falls back to the left margin instead.
            let indent = (idColumn + row.id.count <= r.style.width) ? idColumn : 4
            var tail = String(repeating: " ", count: indent) + r.style.ink(.dim, row.id)
            if row.item.urgent == true { tail += "  " + r.style.ink(.attention, "urgent") }
            print(tail)

            // Only ever printed when one is true, which on this Mac is never: every waiting
            // item here is an unclassified side effect. When it IS true it is the single most
            // important fact about the row.
            let flags = Self.flags(row)
            if !flags.isEmpty {
                print(String(repeating: " ", count: indent)
                      + r.style.ink(.attention, r.list(flags)))
            }
        }

        // ---- reconcile the list with the count ------------------------------------------
        print("")
        print(r.rule())
        var counted = "\(pending.count) waiting"
        if answered > 0 { counted += " and \(answered) already answered" }
        counted += ", \(store.rows.count) in the file. Showing \(shown.count), oldest first."
        print(r.prose(counted))

        if let repeated = Self.dominant(pending), repeated.count > shown.count {
            print(r.prose("\(repeated.count) of them are the same request, "
                + "\(repeated.target).", indent: 2))
        }

        print("")
        print(r.style.ink(.dim, r.prose(
            "The mode governs what Grux starts by itself. It does not govern this queue: "
            + "anything Grux is asked to do that the gate does not read as routine and "
            + "reversible waits here whatever the mode says.")))

        // ---- freshness, as a sentence ----------------------------------------------------
        print("")
        print(r.style.ink(.dim, r.prose(Self.freshness(store))))

        print("")
        // THE NUMBER HAS TO BE BIGGER THAN THE SCREEN IT IS PRINTED UNDER, and the clamp was
        // to a constant, so it was not. Measured on this Mac with 956 waiting: `--limit 40`
        // printed "grux approvals --limit 40 to see more", naming the invocation that had
        // just run, and `--limit 100` printed "--limit 40", which shows 60 FEWER rows than
        // the caller already had. No chain of hints could ever reach item 41.
        //
        // Quadrupling what was just shown, floored at 40 so the six row default still opens
        // onto a real screen and capped at the true count, walks this queue in four runs and
        // is the same value the guard is now taken on, so the two cannot disagree about
        // whether there is anything left to suggest.
        let next = min(pending.count, max(40, shown.count * 4))
        if next > shown.count {
            print(r.style.ink(.dim, r.prose(
                "grux approvals --limit \(next) to see more.", indent: 2)))
        }
        print(r.style.ink(.dim, r.prose(
            "grux approvals --approve <id> to let one run. It prints exactly what will run "
            + "and asks first.", indent: 2)))
        print(r.style.ink(.dim, r.prose("grux approvals --skip <id> to refuse one.",
                                        indent: 2)))
        leave(.done)
    }

    /// The queue file IS the queue, not a copy of one, and saying so is the honest version of
    /// a freshness line.
    ///
    /// The spend ledger needs "this may be stale" because the app refreshes it from a vendor.
    /// This file is rewritten by the app on every change to the queue, so its age is the age
    /// of the last decision rather than the age of the answer.
    static func freshness(_ store: Store) -> String {
        guard store.queueExists else {
            return "There is no file at \(queueURL.path) yet."
        }
        guard let age = store.queueAge else {
            return "Read from \(queueURL.path). The filesystem will not say when it last "
                 + "changed, so its age is unknown."
        }
        return "Read from \(queueURL.path), which last changed \(span(age)) ago. Grux "
             + "rewrites it on every change, so this is the queue itself and not a copy that "
             + "can fall behind it."
    }

    /// The declared reasons the gate holds an action, in words rather than in field names.
    static func flags(_ row: Waiting) -> [String] {
        var out: [String] = []
        if row.item.action?.isSpend == true { out.append("it spends money") }
        if row.item.action?.isExternalComms == true {
            out.append("it sends something to another person")
        }
        if row.item.action?.isPublicPost == true { out.append("it posts in public") }
        if row.item.action?.touchesSecrets == true { out.append("it touches a credential") }
        return out
    }

    /// How long, as somebody says it. Never a timestamp: "73 days" answers how long this has
    /// been waiting and 2026-06-17T07:22:36Z does not.
    static func span(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "unknown" }
        // A NEGATIVE AGE MUST NEVER PRINT. The real file already holds a stamp ahead of this
        // machine's local clock, which is UTC doing its job, and "-1 days" reads as a bug in
        // the command rather than as a timezone.
        let s = max(0, seconds)
        func unit(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
        switch s {
        case ..<90: return "moments"
        case ..<5400: return unit(Int(s / 60), "minute")
        case ..<172_800: return unit(Int(s / 3600), "hour")
        default: return unit(Int(s / 86400), "day")
        }
    }

    /// Clip a value to what is left of the line, but only on a terminal. A pipe is a machine
    /// reading and a machine wants the whole thing.
    static func clip(_ text: String, to room: Int, tty: Bool) -> String {
        guard tty, text.count > room, room > 4 else { return text }
        return String(text.prefix(room - 1)).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }

    /// A label and the VALUE that answers it.
    ///
    /// `Renderer.row` drops its detail column below 60 columns, which is correct when the
    /// detail is a machine id sitting beside a human label. It is wrong here, where the
    /// detail IS the answer: on a 50 column terminal the mode block rendered as three rows
    /// reading `+ Mode`, `+ Hard stop` and `+ Waiting` with every value deleted. Folding the
    /// value into the label keeps it on the screen at any width.
    static func stat(_ r: Renderer, _ state: RowState, _ label: String, _ value: String,
                     width: Int, indent: Int = 2) -> String {
        r.style.isNarrow
            ? r.row(state: state, label: "\(label): \(value)", labelWidth: 0, indent: indent)
            : r.row(state: state, label: label, detail: value, labelWidth: width,
                    indent: indent)
    }

    // MARK: - Machine readable

    private func emitJSON(_ store: Store, pending: [Waiting], shown: [Waiting]) {
        var out: [String: Any] = [
            "mode": store.modeID,
            "mode_chosen": store.modeChosen,
            "modes": Self.modes.map(\.id),
            "killed": store.killed,
            "pending": pending.count,
            "total": store.rows.count,
            "showing": shown.count,
            "queue_file": Self.queueURL.path,
            "queue_file_exists": store.queueExists,
        ]
        if let m = Self.mode(store.modeID) { out["mode_permits"] = m.permits }
        if let age = store.queueAge { out["queue_file_age_seconds"] = Int(max(0, age)) }
        out["items"] = shown.map { row -> [String: Any] in
            var item: [String: Any] = [
                "id": row.id,
                "summary": row.summary,
                "target": row.target,
                "urgent": row.item.urgent ?? false,
                "reason": row.item.reason ?? "",
            ]
            if let created = row.item.createdAt { item["created_at"] = created }
            if let waited = row.waited { item["waited_seconds"] = Int(max(0, waited)) }
            if let runs = row.runs { item["runs"] = runs }
            let flags = Self.flags(row)
            if !flags.isEmpty { item["not_routine_because"] = flags }
            return item
        }
        print(Self.jsonText(out))
    }

    static func jsonText(_ any: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: any,
                                                     options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    // MARK: - Write: the mode

    /// One object on stdout for a path that ends without reaching the app.
    ///
    /// A refusal and a no-op are answers, and under --json they have to be READABLE answers.
    /// EVERY exit from a write path carries one now. Eleven of them ended with prose and no
    /// object at all: two flags at once, an unknown mode, an ambiguous id, an id that is not
    /// there, an unparseable queue, an item already answered, "already there", the app being
    /// closed, a refusal for want of a confirmation, and all three socket failures. An agent
    /// got an exit code and an empty stdout, and could not tell "already done" from "no such
    /// id" because both printed nothing.
    private func sayOutcome(_ outcome: String, _ detail: [String: Any] = [:]) {
        guard json else { return }
        var out: [String: Any] = detail
        out["outcome"] = outcome
        print(Self.jsonText(out))
    }

    /// The rail, on the same stream as everything else a person reads.
    private func sayRail(_ frame: Frame, _ beat: Beat, _ subtitle: String? = nil) {
        let rail = frame.renderer.rail(current: beat)
        if !rail.isEmpty { say("\n  " + rail) }
        if let subtitle { say("\n" + frame.renderer.prose(subtitle)) }
        say("")
    }

    /// Human output, and only when a human is reading.
    ///
    /// UNDER --json, STDOUT IS THE MACHINE SURFACE. Every write path here printed its rail
    /// and its COST screen before the socket call and only then checked the flag, so an
    /// agent running `grux approvals --mode live --json` got two screens of prose and then a
    /// JSON object, on one stream, and nothing could parse it. Two paths printed no JSON at
    /// all: "already there" and every refusal.
    ///
    /// The same rule `grux serve` runs on, for the same reason. A person still sees all of
    /// this, on stderr, where it cannot corrupt a parse.
    private func say(_ text: String = "") {
        if json {
            FileHandle.standardError.write(Data((text + "\n").utf8))
        } else {
            print(text)
        }
    }

    private func setMode(_ wanted: String, store: Store, frame: Frame) -> Never {
        let r = frame.renderer
        let key = wanted.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        guard let target = Self.mode(key) else {
            // ANSWERED HERE, NOT BY THE APP. A typo is a bad invocation whether or not Grux is
            // running, and routing it through the socket would turn "you misspelled a mode"
            // into "Grux is not running" for anybody whose app happens to be closed.
            sayRail(frame, .look)
            say(r.prose("There is no mode called \(wanted)."))
            say("")
            let idWidth = Self.modes.map(\.id.count).max() ?? 8
            for m in Self.modes {
                say(r.row(state: store.modeID == m.id ? .satisfied : .optional,
                            label: m.id,
                            detail: store.modeID == m.id ? "current" : m.label,
                            labelWidth: idWidth, indent: 4))
            }
            let near = Self.modes
                .map { ($0.id, Lookup.edits(key, $0.id)) }
                .filter { $0.1 <= max(2, key.count / 2) }
                .sorted { ($0.1, $0.0) < ($1.1, $1.0) }
            if let best = near.first {
                say("")
                say(r.style.ink(.dim, r.prose("Did you mean \(best.0)?", indent: 2)))
            }
            sayOutcome("unknown_mode", ["mode": wanted,
                                        "known": Self.modes.map(\.id)])
            leave(.failed)
        }

        // ALREADY THERE IS NOT A WRITE. Sending it anyway would print a confirmation for a
        // change that did not happen. A file that has never been written is different: the
        // mode reads as simulate by default and writing it makes that explicit, which is a
        // real change on disk, so that case goes through.
        if store.modeChosen, store.modeID == target.id {
            sayRail(frame, .prove)
            say(Self.stat(r, .satisfied, "Mode", target.label, width: 4))
            say("")
            say(r.prose("Already there, so nothing changed. " + target.permits))
            sayOutcome("unchanged", ["mode": target.id, "changed": false])
            leave(.done)
        }

        let from = Self.mode(store.modeID)?.label ?? store.modeID
        sayRail(frame, .cost, "This is what changes.")
        say(Self.stat(r, .skipped, "Now", from, width: 5))
        say(Self.stat(r, .satisfied, "After", target.label, width: 5))
        say("")
        say(r.prose(target.permits, indent: 2))
        if store.killed {
            // A MODE CHANGE UNDER THE HARD STOP CHANGES NOTHING TODAY. Somebody who has just
            // moved to Live and then sees nothing happen deserves to know why before they go
            // looking for a bug that is not there.
            say("")
            say(r.row(state: .needed, label: "The hard stop is on", labelWidth: 0))
            say(r.style.ink(.dim, r.prose("Nothing Grux would start by itself runs in any "
                + "mode until it is cleared inside Grux, so this takes effect later rather "
                + "than now.", indent: 4)))
        }

        // THE BLANKET DOOR IS GATED LIKE THE SINGLE ONE. Approving one queued item makes you
        // type its 36 character id or pass --yes, while raising the mode, which approves
        // every future action Grux thinks of, went straight to the socket: `echo | grux
        // approvals --mode live` persisted Live and exited 0 having asked nothing, and so did
        // `--mode live --json` and `--mode live --no-input`. The narrow door was locked and
        // the wide one was open.
        //
        // ONLY WHEN AUTONOMY GOES UP. The modes are declared in the order of how much they
        // permit, so the index IS the rank. Retreating to simulate is the safe direction and
        // gating it would make the dangerous move the easier one. A stored mode this build
        // cannot rank is version skew, which is not a reason to assume the change is a
        // retreat, so it is treated as a rise.
        let after = Self.modes.firstIndex { $0.id == target.id } ?? 0
        let escalates = Self.modes.firstIndex { $0.id == store.modeID }
            .map { $0 < after } ?? true
        if escalates, !yes {
            // A PIPE, --no-input AND --json ARE ONE CASE, the same call approveOne makes at
            // its own gate: nobody is there to answer, and hanging on a hidden question is
            // worse to an agent driving this than refusing outright.
            guard input.canAsk, !json else {
                say("")
                say(r.prose(json
                    ? "\(target.label) lets Grux start things without asking, so this asks "
                      + "first, and --json means a machine is reading. Pass --yes if you are "
                      + "sure."
                    : input.nobodyHere("--yes")))
                sayOutcome("needs_confirmation",
                           ["mode": target.id, "from": store.modeID, "changed": false])
                leave(.failed)
            }
            // TYPED, and the mode rather than a word, for the reason the id is typed one
            // screen over: y is muscle memory and typing the name is a decision.
            //
            // NOT THROUGH `say`. The question has to reach the person's terminal whatever
            // the streams are pointed at, and InputPolicy.ask is the one thing that knows
            // where that is.
            let typed = InputPolicy.ask([
                "",
                "  Type the mode to confirm, or anything else to stop.",
                "  " + r.style.ink(.accent, target.id),
                "",
            ])
            guard typed == target.id else {
                say("")
                say(r.prose("Left it in \(from). Nothing changed."))
                leave(.done)
            }
        }

        let client = ControlClient(timeout: 60)
        switch client.call(tool: "grux_approvals",
                           arguments: ["action": "mode", "mode": target.id]) {
        case .failure(let why):
            let sentence = frame.explain(why)
            say("")
            say(r.prose(sentence))
            sayOutcome("failed", ["mode": target.id, "changed": false, "reason": sentence])
            leave(.failed)
        case .success(let text):
            if json { print(text); leave(.done) }
            let obj = (try? JSONSerialization.jsonObject(with: Data(text.utf8)))
                as? [String: Any]
            sayRail(frame, .prove)
            say(Self.stat(r, .satisfied, "Mode", target.label, width: 4))
            say("")
            say(r.prose(target.permits))
            let waiting = (obj?["pending"] as? Int) ?? 0
            if waiting > 0 {
                // THE MODE DID NOT EMPTY THE QUEUE and nothing about this change touches it.
                say("")
                say(r.style.ink(.dim, r.prose("This did not touch the queue. \(waiting) "
                    + "thing\(waiting == 1 ? " is" : "s are") still waiting, and grux "
                    + "approvals reads them.", indent: 2)))
            }
            leave(.done)
        }
    }

    // MARK: - Write: approve one, which runs something

    private func approveOne(_ wanted: String, store: Store, frame: Frame) -> Never {
        let r = frame.renderer
        let row = resolve(wanted, asking: "approved", store: store, frame: frame)

        sayRail(frame, .cost, "This runs on your Mac the moment you say yes.")
        say(r.prose(row.summary))
        say("")

        // Sized from the widest label PRESENT, so a card with no reason on it does not carry
        // the gutter of one that has.
        let reason = row.item.reason ?? ""
        let width = reason.isEmpty ? 7 : 12
        say(Self.stat(r, .satisfied, "Waiting", Self.span(row.waited), width: width))
        if !reason.isEmpty {
            say(Self.stat(r, .satisfied, "Held because",
                            Self.clip(reason, to: max(20, r.style.width - width - 8),
                                      tty: r.style.isTTY),
                            width: width))
        }

        // EXACTLY WHAT WILL RUN, not a description of it. The app replays this stored input
        // verbatim through the same tool the model originally called, so anything less
        // specific than the input itself would be describing a different action. The tool
        // name goes in PROSE rather than in a row because a row's detail column is dropped on
        // a narrow terminal, and this is the one fact that must never disappear.
        say("")
        if let runs = row.runs {
            let input = Self.replayInput(row)
            say(r.prose(input.isEmpty
                ? "It runs \(runs), with no arguments."
                : "It runs \(runs), with this exact input:", indent: 2))
            if !input.isEmpty {
                say("")
                let keyWidth = input.map { $0.0.count }.max() ?? 8
                for (key, value) in input {
                    let room = max(12, r.style.width - keyWidth - 10)
                    say("    " + key.padding(toLength: keyWidth, withPad: " ", startingAt: 0)
                          + "  "
                          + r.style.ink(.dim, Self.clip(value, to: room, tty: r.style.isTTY)))
                }
            }
        } else {
            say(r.prose("It runs nothing. There are no replay coordinates on this one, so "
                + "approving it records your answer and performs nothing.", indent: 2))
        }

        let flags = Self.flags(row)
        if !flags.isEmpty {
            say("")
            say(r.row(state: .needed, label: "This one is not routine", labelWidth: 0))
            say(r.style.ink(.attention, r.prose("The gate held it because "
                + r.list(flags) + ".", indent: 4)))
        }

        // CHECKED BEFORE THE PROMPT, NEVER AFTER. Asking somebody to type a 36 character id
        // and only then telling them the app is closed is a thing this command must not do.
        let client = ControlClient(timeout: 60)
        guard client.isAvailable else {
            say("")
            say(r.prose("Grux is not running, and only Grux can run an approved action. "
                + "Open it and run this again. Nothing was approved."))
            sayOutcome("app_not_running", ["id": row.id, "changed": false])
            leave(.failed)
        }

        if !yes {
            // A PIPE AND A MACHINE READABLE RUN ARE THE SAME CASE. Neither has anybody to
            // ask, and hanging on a hidden question is worse to an agent driving this than
            // refusing it outright. --json on a terminal is still an agent.
            guard input.canAsk, !json else {
                say("")
                say(r.prose("Approving something runs it, so it asks first, and there is "
                    + "nobody here to ask. Pass --yes if you are sure."))
                sayOutcome("needs_confirmation", ["id": row.id, "changed": false])
                leave(.failed)
            }
            // TYPED, not a keystroke, and the id rather than a word. This is the command that
            // starts something running, so the confirmation has to be a decision.
            //
            // NOT THROUGH `say`. Under --json the screen goes to stderr, but the QUESTION
            // has to reach the person's terminal whatever the streams are pointed at, and
            // `input.ask` is the one thing that knows where that is.
            let typed = InputPolicy.ask([
                "",
                "  Type the id to confirm, or anything else to stop.",
                "  " + r.style.ink(.accent, row.id),
                "",
            ])
            guard typed == row.id else {
                say("")
                say(r.prose("Nothing ran. It is still waiting."))
                leave(.done)
            }
        }

        switch client.call(tool: "grux_approvals",
                           arguments: ["action": "approve", "id": row.id]) {
        case .failure(let why):
            let sentence = frame.explain(why)
            say("")
            say(r.prose(sentence))
            sayOutcome("failed", ["id": row.id, "changed": false, "reason": sentence])
            leave(.failed)
        case .success(let text):
            if json { print(text); leave(.done) }
            let obj = (try? JSONSerialization.jsonObject(with: Data(text.utf8)))
                as? [String: Any]
            let runs = (obj?["runs"] as? String) ?? ""
            sayRail(frame, .prove)
            say(Self.stat(r, .satisfied, "Approved", row.id, width: 8))
            say("")
            if runs.isEmpty {
                say(r.prose("Nothing executable was attached to that one, so your answer is "
                    + "recorded and nothing was performed."))
            } else {
                // HONEST ABOUT WHAT THIS COMMAND CAN SEE. The app starts the work and answers
                // straight away, so no result can come back down this socket. It stays
                // checkable, because a run the app catches failing goes back in the queue.
                // "Caught it failing" rather than "it failed", because that detection reads
                // the tool's own wording and a tool that fails in other words stays approved.
                say(r.prose("Grux has it and started \(runs). This command cannot wait for "
                    + "the result, so run grux approvals again in a moment: it is gone from "
                    + "the queue if it went through, and back to waiting if Grux caught it "
                    + "failing."))
            }
            leave(.done)
        }
    }

    // MARK: - Write: refuse one

    private func skipOne(_ wanted: String, store: Store, frame: Frame) -> Never {
        let r = frame.renderer
        let row = resolve(wanted, asking: "skipped", store: store, frame: frame)

        sayRail(frame, .look, "This is what you are refusing. Nothing runs either way.")
        say(r.prose(row.summary))
        say("")
        let width = row.runs == nil ? 7 : 12
        say(Self.stat(r, .satisfied, "Waiting", Self.span(row.waited), width: width))
        if let runs = row.runs {
            say(Self.stat(r, .skipped, "Will not run", runs, width: width))
        }
        say("")
        say(r.style.ink(.dim, r.prose(row.id, indent: 2)))

        let client = ControlClient(timeout: 60)
        switch client.call(tool: "grux_approvals",
                           arguments: ["action": "skip", "id": row.id]) {
        case .failure(let why):
            let sentence = frame.explain(why)
            say("")
            say(r.prose(sentence))
            sayOutcome("failed", ["id": row.id, "changed": false, "reason": sentence])
            leave(.failed)
        case .success(let text):
            if json { print(text); leave(.done) }
            let waiting = (try? JSONSerialization.jsonObject(with: Data(text.utf8)))
                .flatMap { ($0 as? [String: Any])?["pending"] as? Int }
            sayRail(frame, .prove)
            say(Self.stat(r, .skipped, "Refused", row.id, width: 7))
            say("")
            // ANSWERED, NOT DELETED. It stays in the file as a refusal and it does not come
            // back for another look, which is the part somebody needs to hear before they
            // decide, not after.
            say(r.prose("It is answered and will not be offered again. Nothing ran."))
            if let waiting {
                say("")
                say(r.style.ink(.dim, r.prose(waiting == 0
                    ? "Nothing else is waiting."
                    : "\(waiting) still waiting.", indent: 2)))
            }
            leave(.done)
        }
    }

    // MARK: - Finding one item

    /// One item by its id, or by any prefix that names exactly one.
    ///
    /// A queue id is a 36 character UUID and this Mac holds 929 of them, so demanding the
    /// whole thing on the FLAG would mean nobody ever types one. A prefix is taken only while
    /// it names exactly one item: the moment two share it the command stops and prints them,
    /// because approving the wrong one runs the wrong thing.
    ///
    /// - Parameter asking: the state the caller wants this item to end in, `approved` or
    ///   `skipped`, matching `PendingApproval.State` in the app. It is what tells a repeat of
    ///   the same answer, which is done, from a contradiction of one already on record, which
    ///   is not.
    private func resolve(_ wanted: String, asking: String, store: Store,
                         frame: Frame) -> Waiting {
        let r = frame.renderer
        let needle = wanted.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        var hit: Waiting?
        if let exact = store.rows.first(where: { $0.id.lowercased() == needle }) {
            hit = exact
        } else if needle.count >= 4 {
            // FOUR IS A FLOOR, NOT A GUARANTEE. Uniqueness is what makes the prefix safe; the
            // floor only stops `--approve a` from silently resolving to whichever item
            // happened to be alone under one character.
            let prefixed = store.rows.filter { $0.id.lowercased().hasPrefix(needle) }
            if prefixed.count == 1 {
                hit = prefixed[0]
            } else if prefixed.count > 1 {
                sayRail(frame, .look)
                say(r.prose("\(prefixed.count) items start with \(wanted), so this command "
                    + "cannot tell which one you mean. Type more of it."))
                say("")
                for row in prefixed.prefix(8) {
                    say("    " + r.style.ink(.accent, row.id))
                }
                if prefixed.count > 8 {
                    say("    " + r.style.ink(.dim, "and \(prefixed.count - 8) more"))
                }
                sayOutcome("ambiguous_id", ["typed": wanted, "matches": prefixed.count,
                                            "ids": prefixed.prefix(8).map(\.id)])
                leave(.failed)
            }
        }

        guard let found = hit else {
            sayRail(frame, .look)
            if store.queueUnreadable {
                // NOT "THE QUEUE IS EMPTY". There are no rows because the file will not
                // parse, and calling that empty sends somebody looking for an item they can
                // still see inside Grux. It is the same fact the read reports, so it leaves
                // the same way: no invocation naming an id can succeed until the file does.
                say(r.prose("The queue at \(Self.queueURL.path) will not parse, so nothing "
                    + "can be looked up in it and nothing was approved or refused."))
                say("")
                say(r.prose("Move it aside to start a clean queue, and keep the copy if "
                    + "what was in it matters.", indent: 2))
                sayOutcome("queue_unreadable", ["typed": wanted, "changed": false,
                                                "queue_file": Self.queueURL.path])
                leave(.waitingOnYou)
            }
            say(r.prose(store.rows.isEmpty
                ? "The queue is empty, so there is no \(wanted) in it."
                : "Nothing in the queue has the id \(wanted)."))
            let near = Self.nearest(needle, in: store.rows)
            if !near.isEmpty {
                say("")
                say(r.prose(near.count == 1 ? "Did you mean this one?"
                                              : "The closest ids are:", indent: 2))
                say("")
                for row in near {
                    say("    " + r.style.ink(.accent, row.id) + "  "
                          + r.style.ink(.dim, Self.span(row.waited)))
                }
            }
            say("")
            say(r.style.ink(.dim, r.prose("grux approvals to see what is waiting.",
                                            indent: 2)))
            sayOutcome("not_found", ["typed": wanted, "changed": false,
                                     "in_queue": store.rows.count,
                                     "nearest": near.map(\.id)])
            leave(.failed)
        }

        guard found.isPending else {
            let state = found.item.state ?? "answered"
            let when = found.item.resolvedAt
                .flatMap { ISO8601DateFormatter().date(from: $0) }
                .map { " " + Self.span(Date().timeIntervalSince($0)) + " ago" } ?? ""
            let label = Self.clip(found.summary, to: max(20, r.style.width - 8),
                                  tty: r.style.isTTY)

            // THE SECOND RUN OF THE SAME ANSWER IS DONE, NOT FAILED. docs/cli-grammar.md
            // rule 2 requires every command to be idempotent because an agent WILL run it
            // twice, and this exited 1 on a retry loop, a resumed script or an agent
            // re-reading its own transcript while the world was already exactly what the
            // caller asked for. Remove.swift makes the same call for the same situation.
            // Under --json it was worse than a wrong code: exit 1 with an empty stdout, so
            // "already done" was indistinguishable from "no such id".
            if state == asking {
                let mark: RowState = asking == "approved" ? .satisfied : .skipped
                sayRail(frame, .prove)
                say(r.row(state: mark, label: label, labelWidth: 0, indent: 4))
                say("")
                say(r.prose(asking == "approved"
                    ? "Already approved\(when), so nothing changed. Grux ran it then and "
                      + "this did not start it again."
                    : "Already refused\(when), so nothing changed and nothing ran."))
                sayOutcome("unchanged", ["id": found.id, "state": state, "changed": false])
                leave(.done)
            }

            // A DIFFERENT ANSWER IS STILL 1. Refusing something already approved contradicts
            // what is on record rather than repeating it, and reporting that as success
            // would hide the disagreement from the only caller who could resolve it.
            sayRail(frame, .look)
            say(r.prose("That one was already \(state)\(when), so there is nothing left to "
                + "do with it. Only a waiting item can be approved or refused."))
            say("")
            say(r.row(state: .skipped, label: label, labelWidth: 0, indent: 4))
            sayOutcome("already_resolved", ["id": found.id, "state": state,
                                            "asked": asking, "changed": false])
            leave(.failed)
        }
        return found
    }

    /// The closest ids to something that did not resolve.
    ///
    /// The cutoff is deliberately tight and scales with what was typed. Levenshtein over a
    /// pool of UUIDs will happily rank three unrelated ids as the closest to any input, which
    /// is worse here than suggesting nothing: it invites somebody to approve one of them.
    /// Four edits inside a 36 character id is a typo, twenty eight is a different id.
    static func nearest(_ needle: String, in rows: [Waiting], limit: Int = 3) -> [Waiting] {
        guard !needle.isEmpty else { return [] }
        let cutoff = min(4, max(1, needle.count / 8))
        return rows.map { row -> (Waiting, Int) in
            let id = row.id.lowercased()
            // Compared against the whole id AND against its leading run, so a mistyped short
            // prefix is found as readily as a mistyped full id.
            let head = String(id.prefix(needle.count))
            return (row, min(Lookup.edits(needle, id), Lookup.edits(needle, head)))
        }
        .filter { $0.1 <= cutoff }
        .sorted { ($0.1, $0.0.id) < ($1.1, $1.0.id) }
        .prefix(limit)
        .map { $0.0 }
    }

    /// The stored replay input, as sorted key and value pairs.
    ///
    /// Sorted CASE INSENSITIVELY. A plain `<` on a String is an ASCII sort, so a lowercase key
    /// files after every uppercase one, and this codebase has shipped that defect three times.
    static func replayInput(_ row: Waiting) -> [(String, String)] {
        guard let raw = row.item.action?.detail?["__replay_input"],
              let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        return obj.map { key, value -> (String, String) in
            if let text = value as? String { return (key, text) }
            if let list = value as? [Any] {
                return (key, list.map { "\($0)" }.joined(separator: ", "))
            }
            return (key, "\(value)")
        }
        .sorted { $0.0.lowercased() < $1.0.lowercased() }
    }
}
