import ArgumentParser
import Foundation
import GruxSetupCore

// MARK: - grux intro

/// The safety primer, and the first thing a stranger runs.
///
/// A PURE READ. It opens no socket, prompts for nothing and writes nothing, so it answers
/// with Grux closed and on a Mac where Grux has never been opened at all. That last state is
/// the POINT of this command rather than a failure of it: the person deciding whether to
/// open the app for the first time is exactly the person who should be able to read what it
/// will ask for and how to stop it, and making them launch it to find out inverts the order
/// the whole CLI is built around. So "Grux has never run" exits 0 here. The command was
/// asked a question and it answered it.
///
/// Four questions in the order people actually ask them: what is this, what will it want
/// from ME, what will it never do, and how do I get out. Only the second needs the machine,
/// so a status document that is missing or unreadable costs question two and nothing else.
struct Intro: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "intro",
        abstract: "What Grux is, what it asks for, and how to stop it.",
        discussion: """
            Reads only. It opens no socket, asks for nothing and writes nothing, so it \
            answers with Grux closed and before Grux has ever been opened on this Mac.
            """)

    /// The four consent decisions, named here rather than read from the document.
    ///
    /// Question three has to be answerable on a Mac where nothing has ever been written, so
    /// these cannot come from the status file. The live label wins when there IS a document,
    /// which is why the id is carried alongside: a rename in the contract reaches this screen
    /// without this file being edited, and the id is the join.
    ///
    /// `CapabilityResolver.selfAttestedSteps` holds six. Two of them are not consent, an
    /// acknowledgement that you have read what a headless session runs and a setting the app
    /// owns, and putting either in a sentence about what nobody may answer for you would
    /// dilute the claim that matters.
    private static let consentSteps: [(id: String, label: String)] = [
        ("step.recording_consent_acknowledged", "Confirm you will tell people"),
        ("step.capture_exclusions_confirmed", "Confirm what stays private"),
        ("step.corpus_sources_confirmed", "Choose what gets indexed"),
        ("step.first_frame_reviewed", "Review the first capture"),
    ]

    /// Accepted by every command, and it means one thing on all of
    /// them. See InputPolicy.
    @OptionGroup var input: InputPolicy

    func run() throws {
        let frame = Frame()
        let r = frame.renderer

        // ONE BEAT, not two. Everything on this screen is LOOK: it reads what is already
        // true and asks for nothing, including the section about stopping, which names
        // commands rather than running them.
        frame.open(.look, "Nothing here asks for anything, changes anything, or needs "
                          + "Grux running.")

        // ---- 1. what this is -------------------------------------------------------------
        print("  " + r.heading("WHAT THIS IS"))
        print("")
        print(r.prose("Grux is a voice and dictation app for the Mac with an agent "
            + "attached. You talk, it types, and it can go and do the work in the apps you "
            + "keep open."))
        print("")
        print(r.prose("This binary is that app driven from a terminal. It reads what Grux "
            + "has already written, which works with Grux closed, and asks the running app "
            + "for anything that changes. The app is where everything is granted."))
        print("")

        // ---- 2. what it will ask you for -------------------------------------------------
        print(r.rule())
        print("  " + r.heading("WHAT IT WILL ASK YOU FOR, ON THIS MAC"))
        print("")

        var code = Exit.done
        var found: SetupStatus?
        switch SetupStatusReader.read() {
        case .success(let status):
            found = status
            askedFor(status, frame: frame)
        case .failure(let error):
            // The three designed sentences already exist on Frame and each one wants a
            // different thing from a person, so they are printed rather than flattened.
            let judged = frame.explain(error)
            if case .neverWritten = error {
                // EXPECTED, AND THIS IS THE COMMAND WHERE THAT MATTERS MOST. `frame.explain`
                // rates it "waiting on you" because every other command genuinely is. Here
                // three of the four questions need nothing from this Mac and are answered
                // below, so the run succeeded and the code stays 0.
                print("")
                print(r.style.ink(.dim, r.prose("This is the only question that needs your "
                    + "Mac. The two below do not, and they are the two worth reading first.",
                    indent: 2)))
            } else {
                code = judged
            }
        }
        print("")

        // ---- 3. what it will never do ----------------------------------------------------
        print(r.rule())
        print("  " + r.heading("WHAT IT WILL NEVER DO"))
        print("")
        print(r.prose("Four steps are yours and nobody may answer them for you, an agent "
            + "working for you included: " + r.list(consentLabels(found)) + ". Grux takes "
            + "your word for them, because a program that ticked one has not finished the "
            + "step, it has removed the point of it."))
        print("")
        print(r.prose("This binary never raises a macOS permission dialog. A permission "
            + "granted from a terminal belongs to the terminal, so the ask is handed over "
            + "and Grux raises each dialog under its own signature."))
        print("")
        print(r.prose("No credential arrives as a flag or an environment variable. A key is "
            + "typed at a prompt with the echo off, which refuses a pipe, and goes to the "
            + "Keychain. The document this binary reads records that a key is PRESENT, "
            + "never what it is."))
        print("")

        // ---- 4. how to stop it -----------------------------------------------------------
        print(r.rule())
        print("  " + r.heading("HOW TO STOP IT, AND HOW TO UNDO"))
        print("")
        stops(r)
        print("")
        print(r.prose("Disabling leaves a feature on the list, so grux enable brings it "
            + "back. Resetting puts one scope back to never asked. Neither takes a macOS "
            + "permission back: only System Settings can do that."))
        print("")
        print(r.prose("Grux snapshots a folder before it runs anything that could write "
            + "there, and grux undo puts the folder back to one. It asks first, and it "
            + "leaves your own git repository, your branch and your reflog untouched."))
        leave(code)
    }

    // MARK: - Question two

    /// The bill for whatever is turned on HERE, priced by the same arithmetic `grux cost`
    /// and `grux setup` use.
    private func askedFor(_ status: SetupStatus, frame: Frame) {
        let r = frame.renderer
        let chosen = Lookup.chosen(status)

        guard !chosen.isEmpty else {
            // A REAL STATE, not an empty one. Grux runs with nothing turned on, and somebody
            // who reset their selection should not read this as breakage.
            print(r.prose("Nothing is turned on, so nothing is asked for. Grux runs like "
                + "that: an empty sidebar, no permissions, no credentials."))
            print("")
            print(r.style.ink(.dim, r.prose("grux setup turns features on, and prices every "
                + "one of them before it asks you for anything.", indent: 2)))
            return
        }

        let view = BillView(renderer: r, capabilities: status.capabilities)
        let bill = GruxSetupCore.Cost.of(features: chosen,
                                         allCapabilities: status.capabilities.map(\.id),
                                         allFeatures: status.features)
        print(view.summary(for: bill, selectionCount: chosen.count,
                           totalCapabilities: status.capabilities.count))
        print("")

        // THE SHAPE OF THE BILL, NOT THE BILL. `grux cost` itemises, and on a full selection
        // that is 19 rows under four headings, which is longer than this entire command is
        // allowed to be. What somebody reading an intro needs first is how many dialogs, how
        // many keys and how much work, and the counts come from the arrays `grux cost` prints
        // so the two can never disagree. The Other bucket is why they reconcile with the
        // sentence above even if a capability arrives carrying a kind this binary predates.
        let byID = Dictionary(uniqueKeysWithValues: status.capabilities.map { ($0.id, $0) })
        var rows: [(label: String, need: Int, opt: Int)] = []
        var placed = Set<String>()
        for kind in BillView.kinds {
            let need = bill.blocking.filter { byID[$0]?.kind == kind.id }
            let opt = bill.degrading.filter { byID[$0]?.kind == kind.id }
            guard !need.isEmpty || !opt.isEmpty else { continue }
            placed.formUnion(need)
            placed.formUnion(opt)
            rows.append((kind.heading, need.count, opt.count))
        }
        let orphans = (bill.blocking + bill.degrading).filter { !placed.contains($0) }
        if !orphans.isEmpty {
            let blocking = Set(bill.blocking)
            rows.append(("Other", orphans.filter { blocking.contains($0) }.count,
                         orphans.filter { !blocking.contains($0) }.count))
        }

        let width = rows.map { $0.label.count }.max() ?? 0
        for row in rows {
            // THE WORDS CARRY IT, not the glyph. A row that says "5 required" has already
            // explained its own state, which is why there is no legend under this block.
            var parts: [String] = []
            if row.need > 0 { parts.append("\(row.need) required") }
            if row.opt > 0 { parts.append("\(row.opt) optional") }
            let counts = parts.joined(separator: ", ")
            // THE COUNT IS THE ANSWER, NOT MACHINE DETAIL, so a narrow terminal stacks it
            // rather than dropping it. `Renderer.row` hides the detail column below 60
            // columns, which is right for the capability ids every other screen puts there
            // and wrong here: it left four identical rows reading `! Credentials` with every
            // number gone. Stacked rather than appended to the label, because the longest of
            // these runs to 46 columns and the clamp bottoms out at 40.
            print(r.row(state: row.need > 0 ? .needed : .optional, label: row.label,
                        detail: r.style.isNarrow ? nil : counts,
                        labelWidth: width, indent: 4))
            if r.style.isNarrow { print("      " + r.style.ink(.dim, counts)) }
        }

        // AN ANY-OF GROUP IS IN NEITHER COUNT ABOVE, by construction: `Cost` pulls a grouped
        // capability out of both lists because the group is the ask. Saying so is the
        // difference between a count that reconciles and one that quietly under-reports.
        // COUNT THE MEMBERS, NOT THE GROUPS, because the reader is adding up CAPABILITIES.
        // The first version named the number of either-or GROUPS, which is a true sentence
        // that leaves the arithmetic open: measured on this Mac, 19 required plus 12
        // optional plus 8 never asked is 39, the reader is holding a total of 41, and
        // "one ask sits outside" accounts for one of the two missing rows. Every row has to
        // be reachable from the summary or the summary is not one.
        var tail = ""
        let members = Set(bill.choices.flatMap(\.capabilities)).count
        if let group = bill.choices.first, members > 0 {
            let these = members == 1 ? "One of the \(status.capabilities.count) sits"
                                     : "\(members) of the \(status.capabilities.count) sit"
            tail = bill.choices.count == 1
                ? "\(these) outside those counts because they are one either-or: "
                  + "\(group.featureLabel) needs any \(group.min) of them. "
                : "\(these) outside those counts because they are \(bill.choices.count) "
                  + "either-or groups, where any one member finishes its group. "
        }
        print("")
        let already = (bill.blocking + bill.degrading).filter { byID[$0]?.satisfied == true }
        if !already.isEmpty {
            // Freshness belongs to this sentence and not to the ones above it. The bill is a
            // contract and does not go stale; "already true" is a MEASUREMENT the app took
            // at some point in the past, and somebody who granted something an hour ago
            // needs to know whether this answer is older than that.
            let when = SetupStatusReader.age(of: status).map { " when Grux last looked, "
                + Status.ago($0) } ?? ""
            tail += "\(already.count) of those were already true here\(when). "
        }
        print(r.style.ink(.dim, r.prose(tail + "Turning a feature off takes its asks off "
            + "this bill, and grux cost prices any selection you like, row by row.",
            indent: 2)))
    }

    /// The four labels, preferring what the app calls them today over what shipped here.
    private func consentLabels(_ status: SetupStatus?) -> [String] {
        let live = Dictionary(uniqueKeysWithValues:
            (status?.capabilities ?? []).map { ($0.id, $0.label) })
        // Sorted case insensitively. A plain `<` on a String is an ASCII sort, which files a
        // lowercase label last, and that has gone wrong three times in this codebase.
        return Self.consentSteps.map { live[$0.id] ?? $0.label }
            .sorted { $0.lowercased() < $1.lowercased() }
    }

    // MARK: - Question four

    /// The three ways out, as a grid when there is room for one and a stack when there is not.
    private func stops(_ r: Renderer) {
        let ways: [(command: String, what: String)] = [
            ("grux disable <feature>", "turn one feature off"),
            ("grux reset <scope>", "features, brand, consent or all"),
            ("grux undo", "put a folder back to a snapshot"),
        ]
        let width = ways.map { $0.command.count }.max() ?? 0
        // Content decides, not a guessed breakpoint. The description is dim and would be
        // wrapped by the terminal rather than by anything that had thought about it.
        let room = r.style.width - 6 - width
        let stacked = r.style.isNarrow || ways.contains { $0.what.count > room }

        for way in ways {
            let name = r.style.ink(.accent, stacked ? way.command
                : way.command.padding(toLength: width, withPad: " ", startingAt: 0))
            if stacked {
                print("    " + name)
                print("      " + r.style.ink(.dim, way.what))
            } else {
                print("    " + name + "  " + r.style.ink(.dim, way.what))
            }
        }
    }
}
