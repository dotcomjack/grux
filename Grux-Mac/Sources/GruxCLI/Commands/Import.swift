import ArgumentParser
import Foundation
import GruxSetupCore

// MARK: - grux import

/// A setup another Mac exported, applied to this one, with the whole diff shown first.
///
/// ## The inverse of `grux export`, and nothing wider
///
/// Export writes three blocks: which Grux wrote the file, which features were on and off,
/// and each capability's state. This reads those three and nothing else. A field export
/// omits is a field import must not invent, because the moment the two stop being mirrors
/// somebody has to hold both shapes in their head to know what travels.
///
/// That is also why no setting is written here. Export carries no setting value, so an
/// import has none to apply, and a `grux config` write on the strength of a field that is
/// not in the file would be this command making something up.
///
/// ## Nothing was redacted, because there was nothing to redact
///
/// The word matters. "Redacted" tells a reader a value was there and was taken out, which
/// invites them to assume the rest of the file went through the same filter and is therefore
/// clean. An export has never held a credential: it is built from `setup-status.json`, which
/// records that `key.anthropic` is satisfied and nowhere records what it is. So this says
/// the true thing instead, and names the credentials the person still has to set here.
struct Import: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Apply a setup another Mac exported.",
        discussion: """
            Reads a file written by `grux export` and applies the feature selection in it. \
            Every row it would change is shown before anything changes, and --dry-run stops \
            there and writes nothing.

            No credential travels in an export and none can arrive in an import. Nothing was \
            removed from that file on the way out: Grux records that a key is present and \
            never what it is. Every credential is still yours to set here, with \
            `grux connect`.
            """)

    @Argument(help: "A file written by grux export, on this Mac or another one.")
    var file: String?

    @Flag(name: .long, help: "Show the diff and change nothing.")
    var dryRun = false

    @Flag(name: .long, help: "Do not ask. For a script that has already asked.")
    var yes = false

    /// Accepted by every command, and it means one thing on all of
    /// them. See InputPolicy.
    @OptionGroup var input: InputPolicy

    func run() throws {
        let frame = Frame()
        let r = frame.renderer
        // 60 rather than the default 10. Applying the selection rewrites setup-status.json,
        // which re-measures every capability on the machine, and a cold Grux takes longer
        // than a warm one.
        let client = ControlClient(timeout: 60)

        // NOT EXIT 64. ArgumentParser's own missing-argument code is EX_USAGE, and this
        // surface documents 0, 1, 2 and 3, so an agent reading those four has nothing to do
        // with a fifth.
        guard let file, !file.isEmpty else {
            frame.open(.look)
            print(r.prose("Name the file to import. It is a document grux export wrote on "
                + "another Mac, and nothing is applied until you have seen the diff."))
            print("")
            print("    " + r.style.ink(.accent, "grux import their-mac.json --dry-run"))
            print("")
            print(r.style.ink(.dim, r.prose("--dry-run shows exactly what would change and "
                + "writes nothing.", indent: 2)))
            leave(.failed)
        }

        // THIS MAC'S OWN ANSWER FIRST, off disk, so the diff exists even with Grux closed.
        // Its three failure states already have designed screens; there is no second copy
        // of them here.
        let status: SetupStatus
        switch SetupStatusReader.read() {
        case .success(let s): status = s
        case .failure(let e): leave(frame.explain(e))
        }

        let url = URL(fileURLWithPath: (file as NSString).expandingTildeInPath)
        let doc: Document
        switch Document.read(url) {
        case .success(let d): doc = d
        case .failure(let problem):
            frame.open(.look)
            let said = explain(problem, url: url)
            print(r.prose(said.sentence))
            print("")
            print(r.style.ink(.dim, r.prose(said.next, indent: 2)))
            leave(.failed)
        }

        // ---- LOOK -----------------------------------------------------------------------
        let wantOn = doc.chosen
        let mentioned = wantOn.union(doc.off)

        frame.open(.look, "Nothing has been applied. This is the file, and this Mac.")
        let lookLabels = ["File", "Exported", "Written by", "This Mac", "Features named",
                          "Grux is running"]
        let lookWidth = lookLabels.map(\.count).max() ?? 16
        let room = max(16, r.style.width - lookWidth - 8)
        // A path is clipped from the LEFT on a terminal and kept whole in a pipe: the end of
        // a path identifies it and the start is the same home directory every time.
        let shownPath = (r.style.isTTY && url.path.count > room)
            ? "\u{2026}" + String(url.path.suffix(room - 1)) : url.path
        print(r.row(state: .satisfied, label: "File", detail: shownPath, labelWidth: lookWidth))
        print(r.row(state: .satisfied, label: "Exported", detail: doc.stamp,
                    labelWidth: lookWidth))
        print(r.row(state: .satisfied, label: "Written by", detail: doc.appVersion,
                    labelWidth: lookWidth))
        print(r.row(state: .satisfied, label: "This Mac", detail: status.appVersion,
                    labelWidth: lookWidth))
        print(r.row(state: .satisfied, label: "Features named", detail: "\(mentioned.count)",
                    labelWidth: lookWidth))
        print(r.row(state: client.isAvailable ? .satisfied : .needed, label: "Grux is running",
                    detail: client.socketPath, labelWidth: lookWidth))
        print("")
        // FRESHNESS IS PART OF THE ANSWER. This file is a cache of another machine's state,
        // and a person applying a three week old one is entitled to know that before they do.
        print(r.style.ink(.dim, r.prose(freshness(doc), indent: 2)))

        // ---- COST: the diff, which is the whole value of this command --------------------
        let byID = Dictionary(uniqueKeysWithValues: status.features.map { ($0.id, $0) })
        let onNow = Set(status.features.filter(\.chosen).map(\.id))

        var turningOn: [SetupStatus.Feature] = []
        var turningOff: [SetupStatus.Feature] = []
        var alreadyRight: [SetupStatus.Feature] = []
        for id in wantOn.sorted() {
            guard let f = byID[id] else { continue }
            if onNow.contains(id) { alreadyRight.append(f) } else { turningOn.append(f) }
        }
        // `wantOn` wins over `off`. A hand-edited file can name an id in both lists, and
        // counting it twice would print a diff whose rows outnumber the features.
        for id in doc.off.sorted() where !wantOn.contains(id) {
            guard let f = byID[id] else { continue }
            if onNow.contains(id) { turningOff.append(f) } else { alreadyRight.append(f) }
        }
        let strangers = mentioned.subtracting(byID.keys)
            .sorted { $0.lowercased() < $1.lowercased() }
        // SILENCE IS NOT AN INSTRUCTION. grux_set_features replaces the whole selection, so
        // a feature the file never mentions would be turned off by the act of applying a
        // file that says nothing about it. These are carried through untouched instead, and
        // listed, because "your Meta Ads tab disappeared" is not an acceptable surprise.
        let untouched = status.features.filter { !mentioned.contains($0.id) }
        let changeCount = turningOn.count + turningOff.count

        var headline = "Nothing changes. This Mac is already set up the way that file "
                     + "describes it."
        if changeCount > 0 {
            var parts: [String] = []
            if !turningOn.isEmpty { parts.append("\(turningOn.count) turning on") }
            if !turningOff.isEmpty { parts.append("\(turningOff.count) turning off") }
            headline = "\(changeCount) change\(changeCount == 1 ? "" : "s"): "
                     + r.list(parts) + "."
        }
        frame.open(.cost, headline)

        let widest = (turningOn + turningOff + alreadyRight + untouched).map { $0.label.count }
        let width = max(strangers.map(\.count).max() ?? 0, widest.max() ?? 0)

        section("Turning on", turningOn.map { Line(state: .satisfied, label: $0.label, id: $0.id) },
                width: width, r)
        section("Turning off", turningOff.map { Line(state: .skipped, label: $0.label, id: $0.id) },
                width: width, r)
        section("Already how the file wants them",
                alreadyRight.map { Line(state: onNow.contains($0.id) ? .satisfied : .skipped,
                                        label: $0.label, id: $0.id) },
                width: width, r)
        section("Not in the file, so left exactly as they are",
                untouched.map { Line(state: $0.chosen ? .satisfied : .skipped,
                                     label: $0.label, id: $0.id) },
                width: width, r)
        section("In the file, not in this Grux",
                strangers.map { Line(state: .skipped, label: $0, id: "no such feature here") },
                width: width, r)

        // THE GLYPH IS EXPLAINED, and it is explained ONCE, because five headings each
        // implying their own reading of `+` is how a diff becomes a puzzle. One rule: the
        // glyph is the state this import leaves the feature in.
        print(r.legend([.satisfied, .skipped]))
        print("")
        print(r.style.ink(.dim, r.prose("Every glyph above is the state AFTER this import, "
            + "not before it.", indent: 2)))
        print("")
        print(r.rule())

        // EVERY ROW ACCOUNTED FOR. A diff whose summary does not add up to its own list is
        // the one place a reader cannot check the command's arithmetic against anything.
        var tally: [String] = []
        if !turningOn.isEmpty { tally.append("\(turningOn.count) turning on") }
        if !turningOff.isEmpty { tally.append("\(turningOff.count) turning off") }
        if !alreadyRight.isEmpty { tally.append("\(alreadyRight.count) already right") }
        if !strangers.isEmpty { tally.append("\(strangers.count) this Grux does not have") }
        print(r.prose("The file names \(mentioned.count) feature"
            + "\(mentioned.count == 1 ? "" : "s"): " + r.list(tally) + "."))
        if !untouched.isEmpty {
            print(r.prose("\(untouched.count) feature\(untouched.count == 1 ? " is" : "s are") "
                + "on this Mac and not in the file. \(untouched.count == 1 ? "It stays" : "They stay") "
                + "exactly as \(untouched.count == 1 ? "it is" : "they are")."))
        }

        // ---- what an import can never carry ---------------------------------------------
        let localCaps = Dictionary(uniqueKeysWithValues: status.capabilities.map { ($0.id, $0) })
        let theirKeys = doc.capabilities.filter { $0.satisfied && $0.kind == "key" }
        let keysHere = theirKeys.filter { localCaps[$0.id] != nil }
        let toConnect = keysHere.filter { localCaps[$0.id]?.satisfied == false }
        let otherGaps = doc.capabilities.filter {
            $0.satisfied && $0.kind != "key" && localCaps[$0.id]?.satisfied == false
        }
        let unknownCaps = doc.capabilities.filter { localCaps[$0.id] == nil }

        print("")
        print("  " + r.heading("What no import can carry"))
        print("")
        print(r.prose("Nothing was taken out of that file, and there was nothing in it to "
            + "take out. Grux records that a credential is present and never records what it "
            + "is, so an export has no secret to remove and this has none to deliver.",
            indent: 4))
        print("")
        if keysHere.isEmpty {
            print(r.row(state: .satisfied, label: "That Mac had no credential set either.",
                        labelWidth: 0, indent: 4))
        } else {
            let keyWidth = keysHere.compactMap { localCaps[$0.id]?.label.count }.max() ?? 20
            for cap in keysHere.sorted(by: {
                (localCaps[$0.id]?.label ?? $0.id).lowercased()
                    < (localCaps[$1.id]?.label ?? $1.id).lowercased()
            }) {
                let mine = localCaps[cap.id]
                print(r.row(state: (mine?.satisfied ?? false) ? .satisfied : .needed,
                            label: mine?.label ?? cap.id, detail: cap.id,
                            labelWidth: keyWidth, indent: 4))
            }
            print("")
            let have = keysHere.count - toConnect.count
            print(r.prose("\(keysHere.count) credential\(keysHere.count == 1 ? "" : "s") that "
                + "Mac had set. \(have) already set here, \(toConnect.count) still yours to "
                + "set on this one.", indent: 4))
        }
        if !toConnect.isEmpty {
            print("")
            print(r.style.ink(.dim, r.prose("grux connect <id> sets one. It turns the "
                + "terminal's echo off, and what you type never reaches your shell history, "
                + "a flag or an environment variable.", indent: 4)))
        }
        if !otherGaps.isEmpty {
            print("")
            print(r.prose("That Mac also had \(otherGaps.count) other thing"
                + "\(otherGaps.count == 1 ? "" : "s") this one does not"
                + kindsPhrase(otherGaps, r) + ". Applying a file cannot grant those either. "
                + "grux status lists them and grux setup asks for them.", indent: 4))
        }
        if !unknownCaps.isEmpty {
            print("")
            print(r.style.ink(.dim, r.prose("The file names \(unknownCaps.count) other thing"
                + "\(unknownCaps.count == 1 ? "" : "s") this Grux has never heard of, which "
                + "means the two builds differ. Nothing here uses them.", indent: 4)))
        }

        if dryRun {
            print("")
            print(r.rule())
            print(r.prose("Dry run. Nothing was written."))
            leave(.done)
        }

        guard changeCount > 0 else {
            // "NOTHING TO DO" IS A RESULT, not a failure and not a reason to prompt. Asking
            // somebody to confirm zero changes teaches them to confirm without reading.
            print("")
            print(r.rule())
            print(r.prose("Nothing to apply, so nothing was written. Your selection already "
                + "matches the file."))
            leave(.done)
        }

        guard client.isAvailable else {
            // Reading is a file, writing is the app. You still got the entire diff above,
            // which is the half that does not need Grux open.
            print("")
            print(r.prose("Grux is not running, and it owns the feature selection, so none of "
                + "this can be applied from here. Open Grux and run this again."))
            leave(.failed)
        }

        if !yes {
            guard input.canAsk else {
                print("")
                print(r.prose("Nothing is attached to this terminal, so there is nobody to "
                    + "ask, and this turns \(changeCount) feature"
                    + "\(changeCount == 1 ? "" : "s") on or off. Pass --yes if you are sure, "
                    + "or --dry-run to see the diff and change nothing."))
                leave(.failed)
            }
            print("")
            // TYPED, not a keystroke. `y` is muscle memory. The number is the one thing on
            // this screen you cannot type without having read the screen.
            let typed = InputPolicy.ask([
                "  Type the number of changes, or the file's name, to confirm. Anything "
                    + "else stops.",
                "  " + r.style.ink(.accent, "\(changeCount)")
                    + r.style.ink(.dim, "  or  ")
                    + r.style.ink(.accent, url.lastPathComponent),
                "",
            ])
            guard typed == "\(changeCount)" || typed == url.lastPathComponent else {
                print("")
                print(r.prose("Left everything alone."))
                leave(.done)
            }
        }

        // ---- PROVE ----------------------------------------------------------------------
        let target = wantOn.intersection(byID.keys).union(untouched.filter(\.chosen).map(\.id))
        frame.open(.prove)
        switch client.call(tool: "grux_set_features",
                           arguments: ["features": target.sorted()]) {
        case .failure(let why):
            print(r.prose(frame.explain(why)))
            print("")
            print(r.style.ink(.dim, r.prose("Run grux list to see whether any of it landed.",
                                            indent: 2)))
            leave(.failed)
        case .success(let text):
            // The app's own sentence, unedited, because it is the only part of this screen
            // Grux wrote. WRAPPED WHEN IT IS LONG: a row does not wrap, and this reply grows
            // a dependency warning whenever the selection turns a feature on without the
            // feature it depends on, which runs a single row off the edge of the terminal.
            if text.count + 4 > r.style.width {
                print(r.prose(text))
            } else {
                print(r.row(state: .satisfied, label: text, labelWidth: 0))
            }
        }

        // MEASURED, NOT ASSUMED. grux_set_features calls FeatureSelection.choose, which
        // rewrites setup-status.json synchronously before the reply is sent, so the document
        // on disk is already the new answer and no refresh call is needed to read it back.
        guard case .success(let after) = SetupStatusReader.read() else {
            print("")
            print(r.prose("Grux applied it and said so, but the status document could not be "
                + "read back, so this cannot show you the result. Run grux list."))
            leave(.done)
        }
        let onAfter = Set(after.features.filter(\.chosen).map(\.id))
        let missedOn = turningOn.filter { !onAfter.contains($0.id) }
        let missedOff = turningOff.filter { onAfter.contains($0.id) }

        print("")
        let proofWidth = 12
        if !turningOn.isEmpty {
            print(r.row(state: missedOn.isEmpty ? .satisfied : .needed, label: "Turned on",
                        detail: "\(turningOn.count - missedOn.count) of \(turningOn.count)",
                        labelWidth: proofWidth))
        }
        if !turningOff.isEmpty {
            print(r.row(state: missedOff.isEmpty ? .satisfied : .needed, label: "Turned off",
                        detail: "\(turningOff.count - missedOff.count) of \(turningOff.count)",
                        labelWidth: proofWidth))
        }
        print(r.row(state: .satisfied, label: "On now",
                    detail: "\(after.summary.featuresChosen) of \(after.features.count)",
                    labelWidth: proofWidth))

        // THE GAP IS NAMED, NEVER SUMMARISED AWAY. A count that says 2 of 3 and stops leaves
        // the reader to work out which one, which is the one thing they need.
        if !missedOn.isEmpty || !missedOff.isEmpty {
            let missed = (missedOn + missedOff)
                .sorted { $0.label.lowercased() < $1.label.lowercased() }
            print("")
            print(r.prose("\(missed.count) did not end up where the file asked. Grux decides "
                + "what it will hold, so this is its answer and not a failed write:"))
            let w = missed.map { $0.label.count }.max() ?? 20
            for f in missed {
                print(r.row(state: .needed, label: f.label, detail: f.id, labelWidth: w,
                            indent: 4))
            }
        }

        print("")
        print(r.rule())
        var hints = [("grux list", "every feature, on or off"),
                     ("grux status", "what is still waiting on you")]
        if !toConnect.isEmpty {
            hints.append(("grux connect <id>",
                          "the \(toConnect.count) credential"
                          + "\(toConnect.count == 1 ? "" : "s") that file could not carry"))
        }
        let hintWidth = hints.map { $0.0.count }.max() ?? 0
        for (command, what) in hints {
            print("  " + r.style.ink(.dim, command)
                  + String(repeating: " ", count: hintWidth - command.count + 3) + what)
        }
        // A CREDENTIAL THE FILE COULD NOT CARRY IS EXIT 2, and this reported 0 while naming
        // them three lines earlier. An export never carries a secret, by construction, so
        // every one of these needs a person at THIS Mac to paste it into grux connect. No
        // invocation of grux import will ever supply one, which is the whole definition of
        // the code. Reporting 0 tells an agent the import finished when the features it just
        // turned on cannot run.
        leave(toConnect.isEmpty ? .done : .waitingOnYou)
    }

    // MARK: - Drawing

    /// One line of the diff. A struct rather than a tuple because five call sites build
    /// these and a tuple's element order is not checked by anything at any of them.
    private struct Line {
        let state: RowState
        let label: String
        let id: String
    }

    /// A titled group, or nothing at all when it is empty.
    ///
    /// An empty heading is worse than a missing one: "Turning off" with no rows under it
    /// reads as a list that failed to render rather than as a category with no members.
    private func section(_ title: String, _ lines: [Line], width: Int, _ r: Renderer) {
        guard !lines.isEmpty else { return }
        print("  " + r.heading(title))
        for line in lines {
            print(r.row(state: line.state, label: line.label, detail: line.id,
                        labelWidth: width, indent: 4))
        }
        print("")
    }

    /// The kinds of thing that Mac had and this one does not, by name.
    ///
    /// Named from what is actually in the list. An earlier draft said "permissions,
    /// addresses and one-time jobs" unconditionally, which is a sentence that is false for
    /// part of itself whenever only one of the three is present.
    private func kindsPhrase(_ caps: [Document.Cap], _ r: Renderer) -> String {
        let words = ["perm": "permissions", "endpoint": "addresses", "step": "one-time jobs"]
        let named = Set(caps.map(\.kind)).compactMap { words[$0] }
            .sorted { $0.lowercased() < $1.lowercased() }
        return named.isEmpty ? "" : ": " + r.list(named)
    }

    /// How old the file's answer is, as a sentence rather than a timestamp.
    private func freshness(_ doc: Document) -> String {
        guard let when = doc.exportedAt else {
            return "That file does not record a time this can read, so there is no saying how "
                 + "old its answer is."
        }
        let age = Date().timeIntervalSince(when)
        guard age >= 0 else {
            // NOT SILENTLY CLAMPED TO ZERO. Two Macs disagreeing about the time is a real
            // thing to know when you are about to trust one of them about the other.
            return "That file is stamped ahead of this Mac's clock, so how old it is cannot "
                 + "be said. The two machines disagree about the time."
        }
        return "That file was written \(howOld(age)). Anything the other Mac changed after "
             + "that is not in it."
    }

    private func howOld(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "less than a minute ago" }
        if minutes < 90 { return "\(minutes) minute\(minutes == 1 ? "" : "s") ago" }
        let hours = Int(seconds / 3600)
        if hours < 36 { return "\(hours) hour\(hours == 1 ? "" : "s") ago" }
        let days = Int(seconds / 86400)
        return "\(days) day\(days == 1 ? "" : "s") ago"
    }

    // MARK: - The file

    /// Why a file could not be used, and these are deliberately not one case.
    ///
    /// A file that will not parse, a file from a Grux speaking a different schema, and a
    /// file that is not an export at all are three problems with three different next
    /// actions. Collapsing them into "could not read that" hands the reader the job of
    /// working out which one they have, from a sentence written not to say.
    private enum Problem: Error {
        case noFile
        case isFolder
        case unreadable
        case notJSON
        case notAnExport
        case newerSchema(Int)
        case olderSchema(Int)
    }

    private func explain(_ problem: Problem, url: URL) -> (sentence: String, next: String) {
        switch problem {
        case .noFile:
            return ("There is no file at \(url.path).",
                    "On the Mac you are copying from, grux export --out setup.json writes one.")
        case .isFolder:
            return ("\(url.path) is a folder, and an export is a single file.",
                    "Name the file inside it. An export is one JSON document.")
        case .unreadable:
            return ("\(url.path) is there and this cannot read it.",
                    "Check that it is a file this account owns and can read.")
        case .notJSON:
            return ("\(url.lastPathComponent) will not parse. An export is JSON, and this is "
                    + "not JSON at all.",
                    "If it was copied between machines, copy it again: a file cut off part "
                    + "way through fails in exactly this way.")
        case .notAnExport:
            return ("\(url.lastPathComponent) is JSON, but it is not a Grux export. An export "
                    + "carries a grux block and a features block, and this one does not.",
                    "grux export on the other Mac writes the shape this reads.")
        case .newerSchema(let found):
            return ("That file speaks setup schema \(found) and this grux speaks "
                    + "\(SetupStatus.supportedSchema), so the file is the newer of the two.",
                    "Update Grux on this Mac and run this again. The grux inside "
                    + "Grux.app/Contents/MacOS always matches the app it shipped with.")
        case .olderSchema(let found):
            return ("That file speaks setup schema \(found) and this grux speaks "
                    + "\(SetupStatus.supportedSchema), so the file is the older of the two.",
                    "Update Grux on the Mac that wrote it and export again. Applying it as "
                    + "it stands would mean guessing at what changed between the two.")
        }
    }

    /// The export document, read field by field.
    ///
    /// Field by field and by name, the same way the exporter writes it. A wholesale decode
    /// would apply a field the day somebody added one to the export, without anybody having
    /// decided that it may be applied.
    private struct Document {
        let appVersion: String
        let exportedAt: Date?
        let stamp: String
        // A REPEATED ID IS NOT A SECOND FEATURE, so these two arrive as sets and the rest of
        // the command cannot see a duplicate at all. An export a person has hand edited can
        // list the same id twice, and while it was read as an array the diff appended that
        // one feature's row to `turningOff` once per occurrence while `mentioned` counted it
        // once: two real features printed three rows, the COST headline said "3 changes",
        // the closing tally read "The file names 39 features: 3 turning off and 37 already
        // right" (40 against its own 39), and the typed confirmation demanded a number
        // nobody could arrive at by counting the diff.
        let chosen: Set<String>
        let off: Set<String>
        let capabilities: [Cap]

        struct Cap {
            let id: String
            let kind: String
            let satisfied: Bool
        }

        static func read(_ url: URL) -> Result<Document, Problem> {
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else {
                return .failure(.noFile)
            }
            guard !isFolder.boolValue else { return .failure(.isFolder) }
            guard let data = try? Data(contentsOf: url) else { return .failure(.unreadable) }
            guard let any = try? JSONSerialization.jsonObject(with: data) else {
                return .failure(.notJSON)
            }
            guard let root = any as? [String: Any],
                  let head = root["grux"] as? [String: Any],
                  let features = root["features"] as? [String: Any],
                  features["chosen"] != nil || features["off"] != nil,
                  let schema = head["schema"] as? Int else {
                return .failure(.notAnExport)
            }
            guard schema == SetupStatus.supportedSchema else {
                return .failure(schema > SetupStatus.supportedSchema
                                ? .newerSchema(schema) : .olderSchema(schema))
            }

            let raw = head["exportedAt"] as? String ?? ""
            let when = ISO8601DateFormatter().date(from: raw)
            let stamp: String
            if let when {
                let f = DateFormatter()
                f.dateFormat = "d MMM yyyy, h:mm a"
                f.amSymbol = "AM"; f.pmSymbol = "PM"
                stamp = f.string(from: when)
            } else {
                stamp = raw.isEmpty ? "no time recorded" : raw
            }

            let caps = (root["capabilities"] as? [[String: Any]] ?? []).compactMap { c -> Cap? in
                guard let id = c["id"] as? String else { return nil }
                return Cap(id: id, kind: c["kind"] as? String ?? "",
                           satisfied: (c["satisfied"] as? Bool) ?? false)
            }

            return .success(Document(
                appVersion: head["appVersion"] as? String ?? "a version it did not record",
                exportedAt: when, stamp: stamp,
                chosen: Set(features["chosen"] as? [String] ?? []),
                off: Set(features["off"] as? [String] ?? []),
                capabilities: caps))
        }
    }
}
