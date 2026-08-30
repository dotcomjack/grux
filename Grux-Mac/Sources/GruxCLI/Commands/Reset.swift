import ArgumentParser
import Foundation
import GruxSetupCore

// MARK: - grux reset

/// Put one scope back to never-asked.
///
/// ## The scope is required and nothing is defaulted
///
/// The four scopes forget four unrelated things, and the cost of guessing wrong is not
/// symmetric: forgetting a brand costs a person one command, forgetting every consent
/// answer costs them three dialogs they had already read and dismissed. So a bare
/// `grux reset` lists what each one forgets and exits 1. That is the same reasoning
/// `grux undo` uses for refusing to pick a snapshot.
///
/// ## Never-asked is not off
///
/// `reset features` reads to most people as "turn everything off" and it is the opposite:
/// Grux stores the FACT that a choice was made, so taking that away leaves every feature on
/// and first run asking again. The COST screen says so in as many words before the
/// confirmation, because a person who found out afterwards would have found out too late.
struct Reset: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reset",
        abstract: "Put one scope back to never-asked.",
        discussion: """
            Name a scope. There is no default and nothing is guessed.

              grux reset features   forgets which features you chose, so all are on again
              grux reset brand      forgets which brand later commands are about
              grux reset consent    forgets the recording and microphone answers
              grux reset all        all three, named one by one

            It asks before it does anything, and what you type is the scope name rather \
            than y. Pass --yes to skip that.

            It never revokes a macOS permission and never deletes anything you wrote.
            """)

    @Argument(help: "features, brand, consent or all.")
    var scope: String?

    @Flag(name: .long, help: "Do not ask. For a script that has already decided.")
    var yes = false

    @Flag(name: .long, help: "Never prompt. Fails rather than waiting for a person.")
    var noInput = false

    // MARK: - What each scope forgets

    /// One line of the COST screen: something that goes, and what follows from it going.
    private struct Forget {
        let label: String
        let after: String
    }

    private struct Scope {
        let name: String
        /// One line for the menu. Reads after the command name.
        let blurb: String
        let forgets: [Forget]
        /// Printed in attention ink before the confirmation, for the one scope whose plain
        /// English reading is backwards.
        let warning: String?
    }

    private static let features = Scope(
        name: "features",
        blurb: "which features you chose",
        forgets: [Forget(label: "Your feature selection",
                         after: "every feature is on again")],
        warning: "Resetting features turns everything ON, not off. Grux stores the fact that "
               + "you chose; taking that away puts it back where a fresh install starts, with "
               + "every feature on and first run asking you to pick again. If you wanted "
               + "features switched off, grux disable <feature> is the one that does that.")

    private static let brand = Scope(
        name: "brand",
        blurb: "which brand later commands are about",
        forgets: [Forget(label: "The current brand", after: "grux use sets one again")],
        warning: nil)

    private static let consent = Scope(
        name: "consent",
        blurb: "the recording and microphone answers",
        forgets: [
            Forget(label: "The meeting recording answer",
                   after: "asked again before the next recording"),
            Forget(label: "The ambient listening answer",
                   after: "asked again before it takes the microphone"),
            Forget(label: "The wake word answer",
                   after: "asked again before it takes the microphone"),
        ],
        warning: nil)

    /// Three specific scopes, then the aggregate. NOT sorted: `all` is a superset of the
    /// other three, and an alphabetical list would file it first, where it reads as the
    /// obvious choice rather than the last resort.
    private static let scopes: [Scope] = [
        features, brand, consent,
        Scope(name: "all",
              blurb: "all three, named one by one",
              forgets: features.forgets + brand.forgets + consent.forgets,
              warning: features.warning),
    ]

    // MARK: - Run

    func run() throws {
        let frame = Frame()
        let r = frame.renderer

        guard let typed = scope?.trimmingCharacters(in: .whitespacesAndNewlines),
              !typed.isEmpty else {
            menu(frame)
            leave(.failed)
        }
        guard let chosen = Reset.scopes.first(where: { $0.name == typed.lowercased() }) else {
            unknown(typed, frame: frame)
            leave(.failed)
        }

        cost(chosen, frame: frame)
        confirm(chosen, frame: frame)

        let client = ControlClient()
        switch client.call(tool: "grux_reset", arguments: ["scope": chosen.name]) {
        case .failure(let why):
            frame.open(.prove)
            print(r.prose(frame.explain(why)))
            print("")
            // AFTER SOMEBODY HAS TYPED THE SCOPE NAME, silence here reads as "it probably
            // half happened". Nothing did: the writes all live inside the app.
            print(r.prose("Nothing was forgotten.", indent: 2))
            leave(.failed)
        case .success(let text):
            report(text, frame: frame)
        }
    }

    // MARK: - No scope

    /// The menu, which is what a bare `grux reset` is asking for even though it did not say
    /// so. A usage dump would answer a different question: somebody who typed `grux reset`
    /// knows what resetting is, they have not decided what to reset.
    private func menu(_ frame: Frame) {
        let r = frame.renderer
        frame.open(.look, "Four scopes, and reset will not pick one for you. Nothing has "
                          + "been forgotten.")

        let width = Reset.scopes.map(\.name.count).max() ?? 8
        for s in Reset.scopes {
            let pad = String(repeating: " ", count: width - s.name.count)
            print("    " + r.style.ink(.accent, s.name) + pad + "  "
                  + r.style.ink(.dim, s.blurb))
        }
        print("")
        print(r.prose("Naming the scope is the first half of the confirmation, so there is "
                      + "nothing sensible to default to. Each one asks again before it acts."))
        print("")
        print(r.style.ink(.dim, r.prose(
            "None of them revokes a macOS permission, and none of them deletes anything you "
            + "wrote.", indent: 2)))
    }

    private func unknown(_ typed: String, frame: Frame) {
        let r = frame.renderer
        frame.open(.look)
        print(r.prose("No scope called \(typed). There are four: "
                      + r.list(Reset.scopes.map(\.name)) + "."))

        // A miss that only says "no such scope" sends somebody back to read the list for the
        // word they nearly typed. `Lookup.edits` is the Levenshtein the capability lookup
        // already uses, and a second copy here would drift from it within a release.
        let lowered = typed.lowercased()
        let cutoff = max(2, lowered.count / 3)
        let near = Reset.scopes.map(\.name)
            .filter { Lookup.edits(lowered, $0) <= cutoff }
            .sorted { $0.lowercased() < $1.lowercased() }
        if !near.isEmpty {
            print("")
            print(r.prose("Did you mean " + near.prefix(2).joined(separator: " or ") + "?",
                          indent: 2))
        }
        print("")
        print(r.style.ink(.dim, r.prose("grux reset with no scope lists what each one "
                                        + "forgets.", indent: 2)))
    }

    // MARK: - COST, before anything

    private func cost(_ chosen: Scope, frame: Frame) {
        let r = frame.renderer
        frame.open(.cost, "Everything grux reset \(chosen.name) forgets. Nothing has been "
                          + "forgotten yet.")

        // Sized from the widest label actually present, so the four scopes do not each
        // invent their own gutter.
        let width = chosen.forgets.map(\.label.count).max() ?? 0
        for f in chosen.forgets {
            print(r.row(state: .satisfied, label: f.label, detail: f.after,
                        labelWidth: width, indent: 2))
        }

        print("")
        print("  " + r.heading("What it never does"))
        print("")
        print(r.prose("It does not revoke a macOS permission. Only System Settings can, "
                      + "under Privacy & Security, and a command that claimed otherwise "
                      + "would be lying about the microphone.", indent: 2))
        print("")
        print(r.prose("It does not delete anything you wrote. Notes, meetings, transcripts "
                      + "and every other piece of content stay exactly where they are.",
                      indent: 2))

        if let warning = chosen.warning {
            print("")
            print(r.style.ink(.attention, r.prose(warning, indent: 2)))
        }
    }

    /// TYPED, and what is typed is the scope name.
    ///
    /// `y` is muscle memory. Typing `consent` is a decision, and it is the second time the
    /// person has had to name the scope, which is the point: the first naming chose it and
    /// this one confirms it after the cost has been read.
    private func confirm(_ chosen: Scope, frame: Frame) {
        guard !yes else { return }
        let r = frame.renderer

        guard !noInput else {
            print("")
            print(r.prose("You asked for no prompts, so pass --yes to reset "
                          + "\(chosen.name) without being asked."))
            leave(.failed)
        }
        guard RawMode.isSupported else {
            print("")
            print(r.prose("Nothing is attached to this terminal, so there is nobody to ask: "
                          + "pass --yes if you are sure."))
            leave(.failed)
        }

        let answer = InputPolicy.ask([
            "",
            "  Type the scope name to confirm, or anything else to stop.",
            "  " + r.style.ink(.accent, chosen.name),
            "",
        ])
        guard answer == chosen.name else {
            print("")
            // STOPPING IS A COMPLETE ANSWER, so it exits 0. Somebody who read the cost and
            // decided against it has not failed at anything.
            print(r.prose("Left everything alone."))
            leave(.done)
        }
    }

    // MARK: - PROVE

    private func report(_ text: String, frame: Frame) {
        let r = frame.renderer
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8))
                as? [String: Any],
              let rows = obj["reset"] as? [[String: Any]], !rows.isEmpty else {
            // The app answered something this cannot lay out. Print it whole rather than
            // summarising around it: a reset that may or may not have happened is the one
            // thing this command must never paraphrase.
            frame.open(.prove)
            print(r.prose(text))
            leave(.failed)
        }

        frame.open(.prove, "Back to never-asked.")

        let width = rows.compactMap { ($0["label"] as? String)?.count }.max() ?? 0
        var stored = 0
        for row in rows {
            let label = (row["label"] as? String) ?? ""
            let was = (row["was"] as? String) ?? ""
            if (row["changed"] as? Bool) ?? false { stored += 1 }
            // The DETAIL is the past tense on purpose. "+ Meeting recording  acknowledged"
            // reads as a live state, which is the exact opposite of what just happened.
            print(r.row(state: .satisfied, label: label, detail: was,
                        labelWidth: width, indent: 2))
            if let note = row["note"] as? String, !note.isEmpty {
                print(r.style.ink(.dim, r.prose(note, indent: 6)))
            }
        }

        print("")
        print(r.rule())
        print(r.prose(summary(count: rows.count, stored: stored)))
        leave(.done)
    }

    /// Every row accounted for, and the "nothing was there" case said out loud.
    ///
    /// Running this twice is normal, and the second run genuinely changes nothing. A
    /// sentence that reported five successes both times would be true about the end state
    /// and false about the work, which is the wording mistake this rail exists to stop.
    private func summary(count: Int, stored: Int) -> String {
        let already = count - stored
        let head = "\(count) thing\(count == 1 ? "" : "s") back to never-asked."
        let tail: String
        if stored == 0 {
            tail = (count == 1 ? "It had nothing stored" : "None of them had anything stored")
                 + ", so nothing on this Mac actually changed."
        } else if already == 0 {
            tail = (stored == 1 ? "It was" : "All \(stored) were") + " storing something."
        } else {
            tail = "\(stored) \(stored == 1 ? "was" : "were") storing something, "
                 + "\(already) already had nothing."
        }
        return head + " " + tail
    }
}
