import ArgumentParser
import Foundation
import GruxSetupCore

// MARK: - grux add

/// One more thing Grux should know about.
///
/// ## Adding is not replacing, and that is the defect this command exists to not have
///
/// Every noun here joins a list somebody is already keeping: the folders Grux may work in,
/// the brands, the mail accounts, the repositories. The app side reads each list, merges,
/// and writes it back, so a second `grux add project` cannot drop the first. That is the
/// failure nobody reports, because from the outside the second add looks like it worked.
///
/// ## It reports what a noun ACTUALLY bundles
///
/// `project` is three files, not one, so the reply carries a row per thing it touched and
/// this prints all of them. Two of the eight nouns land in a setting that NOTHING ON THIS
/// MAC READS YET, and they say so in the same breath as reporting success, because a
/// stored setting and a working one are different facts and only one of them is what
/// somebody thinks they bought.
///
/// ## Nothing here is a credential
///
/// Structurally, not as a promise. Every value is a path, an address, a name or a time.
/// There is no flag that takes a secret and no environment variable read, and the one noun
/// that has a password behind it says where the password goes instead of asking for it.
struct Add: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Tell Grux about one more thing.",
        discussion: """
            Run with no noun to see all eight, what each one bundles on this Mac, and how \
            many there are already. Run with a noun and no value and it asks for the value.

              grux add project ~/Code/thing
              grux add brand Acme acme.com
              grux add schedule "weekdays at 9:00 AM ask draft my recap"

            Running the same one twice changes nothing the second time and says so.
            """)

    /// The eight, from `docs/cli-grammar.md`. Held here ONLY so a misspelling gets a "did
    /// you mean" without a round trip; the app owns what each one means and does.
    static let nouns = ["brand", "domain", "feature", "mailbox", "project", "repo",
                        "schedule", "skill"]

    @Argument(help: "What to add. Omit to see all eight.")
    var noun: String?

    @Argument(help: "The path, address, name or time. Omit and it asks.")
    var words: [String] = []

    @Flag(name: .long, help: "Never ask. Names the missing argument and stops.")
    var noInput = false

    @Flag(name: .long, help: "Machine readable, and it never asks.")
    var json = false

    func run() throws {
        let frame = Frame()
        let r = frame.renderer
        let client = ControlClient()

        let wanted = (noun ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !wanted.isEmpty, !Self.nouns.contains(wanted.lowercased()) {
            // Caught here rather than at the app, because the near miss is the whole value:
            // "no noun called projcts" sends somebody back to read a list they nearly typed.
            let near = Self.nearest(wanted)
            if json {
                // THE MACHINE SURFACE GETS AN OBJECT, NOT THE SCREEN'S SENTENCES.
                // `if !json` suppressed the rail and nothing under it, so
                // `grux add projcts --json` printed three paragraphs of wrapped prose and
                // jq died on a parse error where an agent was reading the reason. Both
                // things the screen offers a person survive here, as data.
                emit(["error": "There is nothing called \(wanted) to add.",
                      "didYouMean": near,
                      "nouns": Self.nouns,
                      "added": false])
                leave(.failed)
            }
            frame.open(.look)
            print(r.prose("There is nothing called \(wanted) to add."))
            if !near.isEmpty {
                print("")
                print(r.prose("Did you mean " + r.list(near) + "?", indent: 2))
            }
            print("")
            print(r.style.ink(.dim, r.prose(
                "The nouns are " + r.list(Self.nouns) + ". Run grux add on its own to see "
                + "what each one does here.", indent: 2)))
            leave(.failed)
        }

        var arguments: [String: Any] = [:]
        if !wanted.isEmpty { arguments["noun"] = wanted.lowercased() }
        let value = words.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty { arguments["value"] = value }

        var reply = decode(call(client, arguments, frame), frame)

        if (reply["needsValue"] as? Bool) == true {
            arguments["value"] = askForValue(reply, frame: frame)
            reply = decode(call(client, arguments, frame), frame)
        }

        if reply["nouns"] != nil {
            renderNouns(reply, frame: frame)
        }
        renderWrite(reply, frame: frame)
    }

    // MARK: - The socket

    private func call(_ client: ControlClient, _ arguments: [String: Any],
                      _ frame: Frame) -> String {
        switch client.call(tool: "grux_add", arguments: arguments) {
        case .failure(let why):
            // ALWAYS frame.explain. A refusal arrives wrapped, and printing the wrapper
            // sends somebody off to check whether the app is running when it just answered.
            let sentence = frame.explain(why)
            // The same sentence, as an object, for the caller that asked for one. With Grux
            // closed this is the first thing `grux add project ~/Code/thing --json` hits, and
            // it used to hand back "Grux is not running" as a wrapped paragraph.
            if json {
                emit(["error": sentence, "added": false])
                leave(.failed)
            }
            frame.open(.look)
            print(frame.renderer.prose(sentence))
            leave(.failed)
        case .success(let text):
            return text
        }
    }

    private func decode(_ text: String, _ frame: Frame) -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8))
                as? [String: Any] else {
            // Every success grux_add can return is jsonText(...), so a reply that will not
            // parse means the app is not this version. Echoing it under --json would be the
            // non-JSON this branch exists to catch, so the diagnosis goes in `error` and the
            // reply rides along under `reply`, whole, for whoever is chasing the skew.
            if json {
                emit(["error": "Grux answered something this command could not read. This "
                             + "binary is newer than the app it is talking to, which happens "
                             + "when an update installs while Grux is still open. Quit Grux "
                             + "and open it again.",
                      "reply": text,
                      "added": false])
                leave(.failed)
            }
            print(frame.renderer.prose(text))
            leave(.failed)
        }
        // The machine surface prints the app's own reply verbatim. An answer that still
        // wants a value is not a success, so it leaves with 1 and an agent can fix its call.
        if json {
            print(text)
            // THE MACHINE SURFACE GETS THE SAME ANSWER AS THE SCREEN. It keyed only off
            // `needsValue`, so an agent reading exit codes was told 0 for the same reply a
            // person was shown a needed row for.
            if (object["needsValue"] as? Bool) == true { leave(.failed) }
            leave(Exit.forWriteRows(object["touched"] as? [[String: Any]] ?? []))
        }
        return object
    }

    /// One object on stdout, for a `--json` path that ends before the app gives a real answer.
    ///
    /// Three of them printed wrapped prose instead, because `if !json` suppressed the rail and
    /// left the sentences under it printing: an unknown noun, an unreachable or refusing app,
    /// and a reply that would not parse. Each handed jq a paragraph. `error` is the sentence a
    /// person would have read; `added` is the fact a caller branches on, and it is always
    /// false here because reaching this helper means nothing was written.
    private func emit(_ object: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: object,
                                                  options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: data, encoding: .utf8) { print(text) }
    }

    // MARK: - Asking for the value

    /// A noun with no value, when there is somebody there to ask.
    ///
    /// The question and the shape come from the app, so the eight of them are written once,
    /// beside the code that knows what each one does with the answer.
    private func askForValue(_ reply: [String: Any], frame: Frame) -> String {
        let r = frame.renderer
        let shape = (reply["shape"] as? String) ?? "grux add <noun> <value>"
        let hint = (reply["hint"] as? String) ?? ""
        let question = (reply["question"] as? String) ?? "What should Grux add?"

        guard !noInput else {
            frame.open(.look)
            print(r.prose("\(shape) still needs its value, and --no-input means there is "
                          + "nobody to ask. Nothing was added."))
            print("")
            print(r.style.ink(.dim, r.prose(hint, indent: 2)))
            leave(.failed)
        }
        guard RawMode.isSupported else {
            // A pipe with no value is a machine that forgot half its call. Hanging here
            // waiting for a person who is not there is the worst thing this could do to it.
            frame.open(.look)
            print(r.prose("Nothing is attached to this terminal, so there is nobody to ask. "
                          + "Pass the value: \(shape)"))
            leave(.failed)
        }

        frame.open(.cost, "One question, and nothing here is ever a password.")
        // THE QUESTION TRAVELS WITH THE CURSOR, not ahead of it through `print`.
        //
        // This was the one prompt the sweep missed. The others had their question written
        // beside the cursor and moved together; here the question and the hint were printed
        // to stdout and only an empty line went into `ask`, so with stdout redirected the
        // person's terminal showed a blank line and `  > ` and nothing else. They could not
        // see which noun was being asked for or what shape the value takes, and a guess goes
        // straight into the value that gets written.
        //
        // Which is why `ask` now takes the whole question: a call with nothing to say is a
        // call that has left its question somewhere else.
        var asked = [r.prose(question)]
        if !hint.isEmpty {
            asked.append("")
            asked.append(r.style.ink(.dim, r.prose(hint, indent: 2)))
        }
        asked.append("")
        let typed = InputPolicy.ask(asked)
        guard !typed.isEmpty else {
            print("")
            print(r.prose("Nothing typed, so nothing was added."))
            leave(.done)
        }
        return typed
    }

    // MARK: - The listing

    /// Every noun, what it bundles here, and how many there are already.
    ///
    /// This is the discoverability surface for the whole command, so it is two lines a noun
    /// rather than a name and a shrug: somebody who runs `grux add` once should be able to
    /// answer what Grux can be told about without opening a document.
    private func renderNouns(_ reply: [String: Any], frame: Frame) -> Never {
        let r = frame.renderer
        let rows = reply["nouns"] as? [[String: Any]] ?? []
        guard !rows.isEmpty else {
            // Cannot happen against a Grux that matches this binary, which is exactly why
            // it gets words rather than an empty screen.
            frame.open(.look)
            print(r.prose("This Grux offers nothing to add, which means it is older than "
                          + "this binary. Quit Grux and open it again."))
            leave(.failed)
        }

        frame.open(.look, "Everything Grux can be told about, and what each one changes here.")
        print(r.legend([.satisfied, .attested]))
        print("")

        let width = rows.compactMap { ($0["noun"] as? String)?.count }.max() ?? 10
        var unread: [String] = []
        for row in rows {
            let noun = (row["noun"] as? String) ?? ""
            let here = (row["here"] as? String) ?? ""
            let read = (row["read"] as? Bool) ?? true
            if !read { unread.append(noun) }
            // ~ marks the two whose list nothing consumes yet. The glyph is the only thing
            // that differs between a row that works and a row that is stored and unread, so
            // it carries that and the sentence under it spells it out.
            print(r.row(state: read ? .satisfied : .attested, label: noun, detail: here,
                        labelWidth: width, indent: 2))
            let bundles = (row["bundles"] as? String) ?? ""
            let reads = (row["reads"] as? String) ?? ""
            // The app writes `reads` as a fragment, so Mailbox and Chat keep their capitals
            // and nothing here has to lower case a proper noun to make a sentence.
            let sentence = reads.isEmpty
                ? bundles + " Nothing on this Mac reads that list yet."
                : bundles + " Read by " + reads
            print(r.style.ink(.dim, r.prose(sentence, indent: 6)))
        }

        print("")
        print(r.rule())
        // EVERY ROW ACCOUNTED FOR, and the two that are only half true are named rather
        // than counted away.
        let sorted = unread.sorted { $0.lowercased() < $1.lowercased() }
        var summary = "\(rows.count) nouns. \(rows.count - unread.count) land somewhere Grux "
            + "already reads"
        if sorted.isEmpty {
            summary += "."
        } else {
            summary += ", and " + r.list(sorted) + " "
                + (sorted.count == 1 ? "is" : "are") + " stored and read by nothing yet."
        }
        print(r.prose(summary))
        print("")
        print(r.style.ink(.dim, r.prose(
            "grux add <noun> <value>, or grux add <noun> on its own and it asks. Adding the "
            + "same thing twice changes nothing.", indent: 2)))
        leave(.done)
    }

    // MARK: - The result

    /// What it did, thing by thing.
    ///
    /// A noun that touched three files gets three rows. Collapsing them into one sentence is
    /// how a report ends up true about the first thing it names and false about the rest.
    private func renderWrite(_ reply: [String: Any], frame: Frame) -> Never {
        let r = frame.renderer
        frame.open(.prove)

        if let headline = reply["headline"] as? String, !headline.isEmpty {
            print(r.prose(headline))
            print("")
        }

        let rows = reply["touched"] as? [[String: Any]] ?? []
        let width = rows.compactMap { ($0["what"] as? String)?.count }.max() ?? 20
        for row in rows {
            let what = (row["what"] as? String) ?? ""
            let already = (row["already"] as? Bool) ?? false
            let failed = (row["failed"] as? Bool) ?? false
            var detail = (row["where"] as? String) ?? ""
            if already { detail += " (already there)" }
            // Clipped on a terminal, whole in a pipe. A path is data, and a machine reading
            // this wants all of it.
            let room = max(12, r.style.width - width - 8)
            if r.style.isTTY, detail.count > room {
                detail = String(detail.prefix(room - 1)) + "\u{2026}"
            }
            print(r.row(state: failed ? .needed : .satisfied, label: what, detail: detail,
                        labelWidth: width, indent: 2))
        }
        if rows.contains(where: { ($0["failed"] as? Bool) == true }) {
            print("")
            print(r.legend([.satisfied, .needed]))
        }

        if let note = reply["note"] as? String, !note.isEmpty {
            print("")
            print(r.prose(note))
        }
        if let verify = reply["verify"] as? String, !verify.isEmpty {
            print("")
            print(r.style.ink(.dim, r.prose("Check it without trusting this: \(verify).",
                                            indent: 2)))
        }
        leave(Exit.forWriteRows(rows))
    }

    // MARK: - Small things

    /// The closest nouns to something that did not match.
    ///
    /// `Lookup.edits` rather than a second distance function, and a cutoff scaled to what
    /// was typed for the same reason `Lookup.nearest` has one: without it every miss
    /// suggests three unrelated nouns, which is worse than suggesting none.
    private static func nearest(_ needle: String, limit: Int = 2) -> [String] {
        let lowered = needle.lowercased()
        let cutoff = max(2, lowered.count / 3)
        return nouns.map { (noun: $0, distance: Lookup.edits(lowered, $0)) }
            .filter { $0.distance <= cutoff }
            .sorted { ($0.distance, $0.noun) < ($1.distance, $1.noun) }
            .prefix(limit)
            .map(\.noun)
    }
}
