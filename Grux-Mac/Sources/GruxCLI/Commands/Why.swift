import ArgumentParser
import Foundation
import GruxSetupCore

// MARK: - grux why

/// Why Grux wants a thing, answered by naming who asked for it.
///
/// This is the command that makes a permission dialog defensible. "Grux wants your
/// microphone" is a demand. "Meetings and Voice cannot run without it, and you turned both
/// on" is a reason, and the difference is whether the person can act on it: they can turn
/// the feature off instead.
struct Why: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "why",
        abstract: "Which of your features want this, and what happens without it.")

    @Argument(help: "A capability id or its label.")
    var capability: String?

    /// Accepted by every command, and it means one thing on all of
    /// them. See InputPolicy.
    @OptionGroup var input: InputPolicy

    func run() throws {
        let frame = Frame()
        let r = frame.renderer
        let status: SetupStatus
        switch SetupStatusReader.read() {
        case .success(let s): status = s
        case .failure(let e): leave(frame.explain(e))
        }

        // NOT EXIT 64. ArgumentParser's own missing-argument code is EX_USAGE, and this
        // surface documents 0, 1, 2 and 3, so an agent reading those four has nothing to do
        // with a fifth.
        guard let capability, !capability.isEmpty else {
            frame.open(.look)
            print(r.prose("Name a capability. This answers which of the features you chose "
                + "want it, and what stops working without it."))
            print("")
            print("    " + r.style.ink(.accent, "grux why perm.microphone"))
            print("")
            print(r.style.ink(.dim, r.prose("grux status lists all "
                + "\(status.capabilities.count) of them.", indent: 2)))
            leave(.failed)
        }

        guard let cap = Lookup.resolve(capability, in: status) else {
            frame.open(.look)
            print(r.prose("No capability called \(capability)."))
            let near = Lookup.nearest(capability, in: status)
            if !near.isEmpty { print(r.prose("Did you mean " + r.list(near) + "?", indent: 2)) }
            leave(.failed)
        }

        frame.open(.look)
        let state = Lookup.state(of: cap, in: status)
        print(r.row(state: state, label: cap.label, detail: cap.id, labelWidth: 30))
        print("")

        let wants = Lookup.wanters(of: cap.id, in: status)

        // NOBODY. The most interesting answer, and the one the product is built to be able
        // to give: this will never be requested, and here is the reason, by name.
        guard !wants.isEmpty else {
            let offWanters = status.features.filter {
                !$0.chosen && ($0.requires.contains(cap.id) || $0.optional.contains(cap.id)
                    || $0.steps.contains(cap.id) || $0.optionalSteps.contains(cap.id)
                    || $0.anyOf.contains { g in g.capabilities.contains(cap.id) })
            }
            print(r.prose("Nothing you chose uses this, so Grux will never ask you for it."))
            if !offWanters.isEmpty {
                print("")
                print(r.style.ink(.dim, r.prose(
                    "It would be wanted by " + r.list(offWanters.map(\.label))
                    + ", which " + (offWanters.count == 1 ? "is" : "are") + " turned off. "
                    + "Turn one on with grux enable <id> and it will be asked for then.",
                    indent: 2)))
            }
            // NOTHING WANTS IT, so there is nothing to scope a prompt to. The beat is
            // printed and passed through rather than skipped, like every other beat.
            frame.handOff([], because: "Nothing you chose uses \(cap.label), so there is "
                + "nothing here for an agent to do.")
            leave(.done)
        }

        // SORTED BY LABEL. Registry order is an implementation detail and a reader scanning
        // ten feature names is looking one up, not reading a sequence.
        let byLabel: (Lookup.Wanter, Lookup.Wanter) -> Bool = {
            $0.feature.label.lowercased() < $1.feature.label.lowercased()
        }
        let blocking = wants.filter { $0.want == .blocking }.sorted(by: byLabel)
        let optional = wants.filter { $0.want == .optional }.sorted(by: byLabel)
        let grouped  = wants.filter { $0.want == .grouped }.sorted(by: byLabel)

        // THE GLYPH DESCRIBES THE FEATURE, NOT THE RELATIONSHIP. The first draft drew every
        // blocking wanter with the "needed" glyph, so `grux why perm.microphone` printed
        // "! Meetings" on a Mac where the microphone is already granted and Meetings is
        // perfectly fine. The exclamation mark means somebody has work to do, and next to a
        // feature that has everything it needs it is simply false.
        let featureState: RowState = cap.satisfied ? .satisfied : .needed

        if !blocking.isEmpty {
            print("  " + r.heading(cap.satisfied ? "COULD NOT RUN WITHOUT IT"
                                                 : "CANNOT RUN WITHOUT IT"))
            for w in blocking { print(r.row(state: featureState, label: w.feature.label,
                                            detail: w.feature.id, labelWidth: 26, indent: 4)) }
            print("")
        }
        if !grouped.isEmpty {
            print("  " + r.heading("WANTS IT, OR SOMETHING ELSE LIKE IT"))
            for w in grouped {
                print(r.row(state: cap.satisfied ? .satisfied : .optional, label: w.feature.label,
                            detail: w.feature.id, labelWidth: 26, indent: 4))
                for g in w.feature.anyOf where g.capabilities.contains(cap.id) {
                    let others = g.capabilities.filter { $0 != cap.id }
                        .map { Lookup.capability($0, in: status)?.label ?? $0 }
                    print("      " + r.style.ink(.dim,
                        others.isEmpty ? "no alternative" : "or " + r.list(others)))
                }
            }
            print("")
        }
        if !optional.isEmpty {
            print("  " + r.heading("BETTER WITH IT, FINE WITHOUT"))
            for w in optional { print(r.row(state: .optional, label: w.feature.label,
                                            detail: w.feature.id, labelWidth: 26, indent: 4)) }
            print("")
        }

        if let fix = cap.remediation, !cap.satisfied {
            print("  " + r.heading("HOW TO SATISFY IT"))
            print(r.prose(fix, indent: 4))
            print("")
        }

        if cap.selfAttested && cap.satisfied {
            print(r.style.ink(.dim, r.prose(
                "This one is true because you said so, not because Grux went and looked.",
                indent: 2)))
        }

        // THE SCOPE IS THE ANSWER THIS COMMAND JUST GAVE: the features that want this
        // capability. Handing back `grux handoff` unscoped would ask for a prompt about the
        // whole Mac when the question was about one thing.
        frame.handOff(wants.map(\.feature.id))
        leave(blocking.isEmpty || cap.satisfied ? .done : .waitingOnYou)
    }
}
