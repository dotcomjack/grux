import ArgumentParser
import Foundation
import GruxSetupCore

// MARK: - grux repair

/// One repairable thing, as the app describes it.
private struct Repairable {
    let id: String
    let title: String
    let path: String
    /// Is it wrong on this Mac at this moment.
    let applies: Bool
    /// What is true about it right now, fault or not.
    let now: String
    /// What running it would do.
    let fix: String
}

/// Something wrong that repair will not touch, and why it will not.
private struct Unfixable {
    let id: String
    let label: String
    let what: String
    let why: String
}

/// What one repair did, after the app read the state back off the disk.
private struct Outcome {
    let title: String
    let path: String
    let wasWrong: Bool
    let verified: Bool
    let needsAPerson: Bool
    let before: String
    let after: String
}

/// Fix what doctor found and can fix, one thing at a time.
///
/// ## The list is short because the honest list is short
///
/// `grux doctor` checks four things and one of them has a repair behind it. Grux.app being
/// missing is a download. Grux not running cannot be repaired from here at all, since every
/// repair runs inside the app, so an answer arriving on this screen has already disproved
/// both of those findings. The version doctor prints is read out of the status document, so
/// it is the third check under a different name rather than a fourth thing to fix.
///
/// A menu of five repairs where four do nothing would read better and be worth less. The
/// whole set is shown instead, with what each one would do and whether it applies right
/// now, and everything that genuinely needs a person is named beside it rather than left
/// out because this command cannot help with it.
///
/// ## It never waits for anybody
///
/// No prompt, no confirmation, no credential. Rewriting the status document regenerates a
/// derived answer from live state, so there is no work for a confirmation to protect. That
/// is why there is no `--yes`, and why `--no-input`, which every command takes so that an
/// agent can pass it uniformly, changes nothing here: a command that cannot block has
/// nothing for the flag to switch off.
struct Repair: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "repair",
        abstract: "Fix what doctor found and can fix, one thing at a time.",
        discussion: """
            With no id it lists every repair with what is wrong right now, what running it \
            would do, and whether it applies on this Mac at this moment. A repair that is \
            not needed is still listed, as satisfied, so the set never changes shape.

              grux repair                 list them
              grux repair setup-status    run that one
              grux repair --all           run every one that applies, one at a time

            It asks for nothing and never prompts, so it is safe in a pipe and safe under \
            an agent.

            Exit codes: 0 repaired or nothing to repair, 1 an id that does not exist or \
            Grux is not running, 2 something is left that needs you, 3 a repair applies and \
            nothing here ran it. 3 is reported ahead of 2, so clear the repairs and list \
            them again to see what is still yours.
            """)

    @Argument(help: "The id of one repair. Omit to list them.")
    var what: String?

    @Flag(name: .long, help: "Run every repair that applies, one at a time, in list order.")
    var all = false

    // MARK: - Run

    /// Accepted by every command, and it means one thing on all of
    /// them. See InputPolicy.
    @OptionGroup var input: InputPolicy

    func run() throws {
        let frame = Frame()
        let r = frame.renderer
        let client = ControlClient()

        guard !(all && what != nil) else {
            frame.open(.look)
            print(r.prose("Name one repair or pass --all, not both. --all already runs "
                          + "every one that applies, so naming one alongside it is asking "
                          + "for two different things at once."))
            print("")
            print(r.style.ink(.dim, r.prose("Nothing was repaired.", indent: 2)))
            leave(.failed)
        }

        // THE LIST FIRST, EVERY TIME, INCLUDING WHEN AN ID WAS NAMED. It changes nothing, so
        // it costs one socket round trip, and it buys three things the second call cannot:
        // a misspelling gets a did-you-mean instead of a refusal, the LOOK beat can show
        // what was wrong BEFORE anything was touched, and --all learns its order from the
        // same place the list screen prints it rather than inventing a second one.
        let (repairs, unfixable) = fetchSet(frame, client)

        guard !repairs.isEmpty else {
            // Designed rather than impossible. A Grux old enough to answer this tool and
            // register nothing under it would otherwise print an empty screen and exit 0,
            // which reads as "all clear".
            frame.open(.look)
            print(r.prose("Grux answered and named no repairs at all. This binary is newer "
                          + "than the app it is talking to, which happens when an update "
                          + "installs while Grux is still open. Quit Grux and open it again."))
            leave(.failed)
        }

        // `unfixable` GOES DOWN EVERY PATH, not just the listing. Running the repairs does
        // not make what needs a person go away, and both run paths used to exit 0 having
        // never mentioned it. That is worse after the listing learned to exit 3, because the
        // help then points at --all as the answer to a 3 and --all reports everything done.
        if let typed = what?.trimmingCharacters(in: .whitespacesAndNewlines), !typed.isEmpty {
            runOne(typed, in: repairs, unfixable, frame: frame, client: client)
        } else if all {
            runAll(repairs, unfixable, frame: frame, client: client)
        } else {
            list(repairs, unfixable, frame: frame)
        }
    }

    // MARK: - LOOK, with nothing named

    private func list(_ repairs: [Repairable], _ unfixable: [Unfixable], frame: Frame) {
        let r = frame.renderer
        frame.open(.look, "What repair can fix on this Mac at this moment, and what it "
                          + "cannot. Nothing on this screen changes anything.")

        let width = repairs.map(\.title.count).max() ?? 0
        for item in repairs {
            print(r.row(state: item.applies ? .needed : .satisfied,
                        label: item.title, detail: item.id, labelWidth: width, indent: 2))
            print(r.style.ink(.dim, r.prose(item.now, indent: 6)))
            if item.applies {
                print(r.prose(item.fix, indent: 6))
            }
            print(r.style.ink(.dim, r.prose(clip(item.path, r), indent: 6)))
            print("")
        }

        if !unfixable.isEmpty {
            print("  " + r.heading("What needs you instead"))
            print("")
            let labelWidth = unfixable.map(\.label.count).max() ?? 0
            for item in unfixable {
                print(r.row(state: .needed, label: item.label, detail: item.id,
                            labelWidth: labelWidth, indent: 2))
                print(r.prose(item.what, indent: 6))
                print(r.style.ink(.dim, r.prose(item.why, indent: 6)))
                print("")
            }
        }

        // ONLY THE GLYPHS ACTUALLY ON SCREEN. A legend explaining a state nothing used sends
        // somebody back up the page to look for a row that is not there.
        var states: [RowState] = []
        if repairs.contains(where: { !$0.applies }) { states.append(.satisfied) }
        if repairs.contains(where: \.applies) || !unfixable.isEmpty { states.append(.needed) }
        print(r.legend(states))
        print("")
        print(r.rule())
        print(r.prose(summary(repairs, unfixable)))
        print("")

        // The two doctor findings this command structurally cannot be asked about, said out
        // loud rather than left as a silence somebody has to interpret.
        print(r.style.ink(.dim, r.prose(
            "Grux.app being installed and Grux running are the other two things grux doctor "
            + "checks. Neither can be repaired from here and neither needs to be: this "
            + "command reached Grux, so both are already true.", indent: 2)))
        print("")
        let anyApplies = repairs.contains(where: \.applies)
        print(r.style.ink(.dim, r.prose(
            anyApplies
                ? "grux repair <id> runs one. grux repair --all runs every one that applies."
                : "There is nothing here to run. Naming one anyway is safe and says so.",
            indent: 2)))
        // 2 ONLY WHEN THE REST IS GENUINELY SOMEBODY'S TURN. A repair that applies is not
        // waiting on a person, it is waiting on one more command, and reporting that as
        // "waiting on you" would send an agent looking for a person who has nothing to do.
        //
        // AND 3 IS WHAT A FIXABLE BREAK IS. This listed a repair that applies and exited 0,
        // which says everything asked for is satisfied, in the one state where something is
        // measurably wrong. Code 3 is defined as exactly this on the front of every help
        // screen: something is broken and grux repair can probably fix it. Using it here is
        // what makes it worth carrying.
        //
        // AND THE DISCUSSION ABOVE NAMES 3 BECAUSE OF THIS LINE. It emitted 3 while grux
        // repair --help published 0, 1 and 2 only, so on the ordinary Mac whose status
        // document is out of date the one code this command hands back was the one code its
        // own help never mentioned.
        if anyApplies { leave(.selfRepairAvailable) }
        leave(unfixable.isEmpty ? .done : .waitingOnYou)
    }

    /// Every row accounted for, and the counts match the list above them.
    private func summary(_ repairs: [Repairable], _ unfixable: [Unfixable]) -> String {
        let n = repairs.count
        let needed = repairs.filter(\.applies).count
        let head = "\(n) repair\(n == 1 ? "" : "s"). "
        let body: String
        if needed == 0 {
            body = n == 1 ? "It is already satisfied, so there is nothing to run."
                          : "All \(n) are already satisfied, so there is nothing to run."
        } else if needed == n {
            body = needed == 1 ? "It applies right now." : "All \(needed) apply right now."
        } else {
            body = "\(needed) of them apply right now."
        }
        guard !unfixable.isEmpty else {
            return head + body + " Nothing else on this Mac needs you."
        }
        let m = unfixable.count
        return head + body + " \(m) other thing\(m == 1 ? "" : "s") "
             + "\(m == 1 ? "needs" : "need") you, and repair will not touch "
             + "\(m == 1 ? "it" : "them")."
    }

    // MARK: - One repair

    private func runOne(_ typed: String, in repairs: [Repairable],
                        _ unfixable: [Unfixable],
                        frame: Frame, client: ControlClient) {
        let r = frame.renderer

        guard let item = repairs.first(where: { $0.id.lowercased() == typed.lowercased() })
        else {
            frame.open(.look)
            print(r.prose("No repair called \(typed). There "
                          + (repairs.count == 1 ? "is one: " : "are \(repairs.count): ")
                          + r.list(repairs.map(\.id)) + "."))

            // `Lookup.edits` is the Levenshtein the capability lookup already uses, with the
            // same cutoff scaled to what was typed. A second copy here would drift from it
            // inside a release, and a miss that only says "no such repair" sends somebody
            // back to read the list for the word they nearly typed.
            let lowered = typed.lowercased()
            let cutoff = max(2, lowered.count / 3)
            let near = repairs.map(\.id)
                .filter { Lookup.edits(lowered, $0.lowercased()) <= cutoff }
                .sorted { $0.lowercased() < $1.lowercased() }
            if !near.isEmpty {
                print("")
                print(r.prose("Did you mean " + r.list(Array(near.prefix(2))) + "?",
                              indent: 2))
            }
            print("")
            print(r.style.ink(.dim, r.prose("grux repair with no id lists every one and says "
                                            + "which apply.", indent: 2)))
            leave(.failed)
        }

        frame.open(.look, "What is true before anything is touched.")
        print(r.row(state: item.applies ? .needed : .satisfied,
                    label: item.title, detail: item.id, labelWidth: item.title.count))
        print(r.style.ink(.dim, r.prose(item.now, indent: 6)))

        // ASKED ANYWAY, even when the list just said it was satisfied. The app reads the
        // state again inside the call and its answer is the authoritative one, so a document
        // that changed between the two calls is reported as it is rather than as it was.
        frame.open(.prove, "Read back off the disk afterwards, not assumed from the call.")
        let outcome = perform(item.id, frame: frame, client: client)
        report(outcome, frame: frame)

        print("")
        if !outcome.wasWrong {
            print(r.prose("Nothing to do here. It was already right, so nothing was written."))
            leave(Self.close(stuck: 0, unfixable, frame: frame))
        }
        if outcome.needsAPerson || !outcome.verified {
            print(r.style.ink(.attention, r.prose(
                "That is as far as this command goes. The rest is yours.")))
            leave(.waitingOnYou)
        }
        print(r.prose("Repaired."))
        leave(Self.close(stuck: 0, unfixable, frame: frame))
    }

    // MARK: - Every repair that applies

    private func runAll(_ repairs: [Repairable], _ unfixable: [Unfixable],
                        frame: Frame, client: ControlClient) {
        let r = frame.renderer
        frame.open(.look, "Everything repair can fix on this Mac, and what applies right now.")

        let width = repairs.map(\.title.count).max() ?? 0
        for item in repairs {
            print(r.row(state: item.applies ? .needed : .satisfied,
                        label: item.title, detail: item.id, labelWidth: width, indent: 2))
            print(r.style.ink(.dim, r.prose(item.now, indent: 6)))
        }
        print("")

        let applicable = repairs.filter(\.applies)
        guard !applicable.isEmpty else {
            frame.open(.prove)
            print(r.prose("Nothing to do here. Every repair this Mac has is already "
                          + "satisfied, so --all wrote nothing."))
            leave(Self.close(stuck: 0, unfixable, frame: frame))
        }

        // THE ORDER IS STATED, not left to be inferred from the output. Somebody reading a
        // transcript of this afterwards has to be able to tell a deliberate sequence from
        // whatever order a dictionary happened to iterate in.
        print(r.prose("\(applicable.count) of \(repairs.count) apply. They run one at a "
                      + "time, in the order printed above, which is the order this command "
                      + "always lists them: by id, case insensitively."))

        frame.open(.prove, "One at a time, each one read back before the next one starts.")
        var fixed = 0
        var stuck = 0
        for item in applicable {
            let outcome = perform(item.id, frame: frame, client: client, done: fixed + stuck,
                                  outOf: applicable.count)
            report(outcome, frame: frame)
            print("")
            if outcome.needsAPerson || !outcome.verified { stuck += 1 } else { fixed += 1 }
        }

        print(r.rule())
        // Counts that add up to the list above them, and the no-op case said in words rather
        // than reported as a success it was not.
        print(r.prose("\(applicable.count) repair\(applicable.count == 1 ? "" : "s") run. "
                      + (stuck == 0
                         ? "\(fixed == 1 ? "It is" : "All \(fixed) are") fixed and read back."
                         : "\(fixed) fixed, \(stuck) still needing you.")))
        leave(Self.close(stuck: stuck, unfixable, frame: frame))
    }

    /// How a run ends, once what needs a PERSON is counted alongside what got repaired.
    ///
    /// Repairing everything repairable does not make the rest go away. Both run paths ended
    /// at 0 whenever nothing they touched got stuck, on a Mac where `doctor` had already
    /// found something only a person can fix, and neither printed a word about it. An agent
    /// reads 0 as "report done" and the thing nobody can automate is never surfaced.
    ///
    /// It is PRINTED as well as counted. An exit code carries one bit to a script and
    /// nothing at all to a person reading the screen, so the rows go on screen too.
    private static func close(stuck: Int, _ unfixable: [Unfixable], frame: Frame) -> Exit {
        guard !unfixable.isEmpty else {
            return Exit.forRepair(stuck: stuck, unfixable: 0)
        }
        let r = frame.renderer
        print("")
        print("  " + r.heading("WHAT NEEDS YOU INSTEAD"))
        // The same two fields the listing draws, so one thing does not have two shapes.
        let width = unfixable.map { $0.label.count }.max() ?? 0
        for item in unfixable {
            print(r.row(state: .needed, label: item.label, detail: item.what,
                        labelWidth: width, indent: 2, detailIsTheAnswer: true))
        }
        print("")
        print(r.style.ink(.dim, r.prose("\(unfixable.count) thing"
            + "\(unfixable.count == 1 ? "" : "s") repair cannot touch, so this leaves with "
            + "2 rather than 0. Nothing above was undone by saying so.", indent: 2)))
        return Exit.forRepair(stuck: stuck, unfixable: unfixable.count)
    }

    // MARK: - The call, and what came back

    /// The caller has already opened PROVE. Nothing here opens a beat, so a call that fails
    /// mid sweep prints under the rail that was already up rather than raising a second one.
    private func perform(_ id: String, frame: Frame, client: ControlClient,
                         done: Int = 0, outOf: Int = 1) -> Outcome {
        let r = frame.renderer
        switch client.call(tool: "grux_repair", arguments: ["what": id]) {
        case .failure(let why):
            print(r.prose(frame.explain(why)))
            if outOf > 1 {
                print("")
                // NEVER "NOTHING HAPPENED" IN THE MIDDLE OF A SWEEP. Some of them ran, and a
                // sentence that was true of the whole run would be false about the part of
                // it that already landed.
                print(r.prose("\(done) of \(outOf) had already run. The rest did not.",
                              indent: 2))
            }
            leave(.failed)
        case .success(let text):
            guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8))
                    as? [String: Any],
                  let title = obj["title"] as? String else {
                print(r.prose(frame.explain(
                    ControlClient.Failure.badAnswer("the repair result was not JSON"))))
                leave(.failed)
            }
            return Outcome(
                title: title,
                path: (obj["path"] as? String) ?? "",
                wasWrong: (obj["wasWrong"] as? Bool) ?? false,
                verified: (obj["verified"] as? Bool) ?? false,
                needsAPerson: (obj["needsAPerson"] as? Bool) ?? false,
                before: (obj["before"] as? String) ?? "",
                after: (obj["after"] as? String) ?? "")
        }
    }

    private func report(_ outcome: Outcome, frame: Frame) {
        let r = frame.renderer
        let state: RowState = outcome.needsAPerson || !outcome.verified ? .needed : .satisfied
        print(r.row(state: state, label: outcome.title, detail: clip(outcome.path, r),
                    labelWidth: outcome.title.count))
        // BEFORE AND AFTER BOTH, and labelled. "It is fine now" alone is true and useless:
        // running this twice is normal, and without the before nothing on screen tells the
        // second run apart from the first.
        //
        // NOTHING RAN MEANS NO BEFORE AND NO AFTER. Labelling one state as an "after" when
        // no write happened would claim work that did not occur, which is the exact wording
        // mistake the rail exists to stop.
        guard outcome.wasWrong else {
            print(r.style.ink(.dim, r.prose(outcome.after, indent: 6)))
            return
        }
        print(r.style.ink(.dim, r.prose("Before this ran. " + outcome.before, indent: 6)))
        print(r.prose("After, read back off the disk. " + outcome.after, indent: 6))
    }

    // MARK: - Fetching the set

    private func fetchSet(_ frame: Frame,
                          _ client: ControlClient) -> ([Repairable], [Unfixable]) {
        let r = frame.renderer
        switch client.call(tool: "grux_repair") {
        case .failure(let why):
            frame.open(.look)
            print(r.prose(frame.explain(why)))
            print("")
            print(r.style.ink(.dim, r.prose(
                "Every repair runs inside Grux, because the app is the only thing that can "
                + "measure this Mac under its own signature. Nothing was changed.", indent: 2)))
            leave(.failed)
        case .success(let text):
            guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8))
                    as? [String: Any],
                  let rows = obj["repairs"] as? [[String: Any]] else {
                frame.open(.look)
                print(r.prose(frame.explain(
                    ControlClient.Failure.badAnswer("the repair list was not JSON"))))
                leave(.failed)
            }
            // Sorted case insensitively, here and nowhere else, so the list screen, the
            // stated --all order and the did-you-mean all read from one ordering. A plain
            // `<` on a String is an ASCII sort and files a lowercase id last.
            let repairs = rows.compactMap(Repair.repairable(from:))
                .sorted { $0.id.lowercased() < $1.id.lowercased() }
            let unfixable = ((obj["needsAPerson"] as? [[String: Any]]) ?? [])
                .compactMap(Repair.unfixable(from:))
                .sorted { $0.label.lowercased() < $1.label.lowercased() }
            return (repairs, unfixable)
        }
    }

    private static func repairable(from any: [String: Any]) -> Repairable? {
        guard let id = any["id"] as? String, let title = any["title"] as? String else {
            return nil
        }
        return Repairable(id: id, title: title,
                          path: (any["path"] as? String) ?? "",
                          applies: (any["applies"] as? Bool) ?? false,
                          now: (any["now"] as? String) ?? "",
                          fix: (any["fix"] as? String) ?? "")
    }

    private static func unfixable(from any: [String: Any]) -> Unfixable? {
        guard let id = any["id"] as? String, let label = any["label"] as? String else {
            return nil
        }
        return Unfixable(id: id, label: label,
                         what: (any["what"] as? String) ?? "",
                         why: (any["why"] as? String) ?? "")
    }

    /// Clip a PATH on a terminal, keep it whole in a pipe. Data, not prose: something
    /// reading this is going to open the path, and half a path opens nothing.
    private func clip(_ path: String, _ r: Renderer) -> String {
        let room = max(20, r.style.width - 8)
        guard r.style.isTTY, path.count > room else { return path }
        return String(path.prefix(room - 1)) + "\u{2026}"
    }
}
