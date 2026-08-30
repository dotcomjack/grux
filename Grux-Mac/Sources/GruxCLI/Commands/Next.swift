import ArgumentParser
import Foundation
import GruxSetupCore

// MARK: - grux next

/// One thing to do, and the command that does it.
///
/// Every other read here answers "what is the state". This one answers "what should I do",
/// which is the question somebody actually has, and it answers with exactly ONE thing. A
/// list of nine outstanding items is a state dump wearing a verb: it moves the work of
/// choosing back onto the person, which is the work this command exists to do for them.
struct Next: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "next",
        abstract: "The single most useful thing to do now, and the command that does it.")

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

        frame.open(.prove)

        // EVERY EXIT GOES THROUGH HERE, which is why the beat lives inside it. This
        // command has eight answers and wiring the handoff at each one would be eight
        // chances to forget it.
        func say(_ answer: String, _ command: String?, _ why: String, _ code: Exit,
                 scope: [String] = []) -> Never {
            // THE ANSWER FIRST, the command under it, the reasoning last and dimmed.
            print(r.prose(answer))
            if let command {
                print("")
                print("      " + r.style.ink(.accent, command))
            }
            print("")
            print(r.style.ink(.dim, r.prose(why, indent: 2)))
            // SCOPED TO WHAT THIS ONE THING UNBLOCKS, which is the whole point of the
            // command: it already narrowed the Mac down to a single next action, so handing
            // back a prompt about everything would throw that away.
            frame.handOff(scope, because: scope.isEmpty
                ? "There is nothing here for an agent to do."
                : nil)
            leave(code)
        }

        let chosen = Lookup.chosen(status)
        if chosen.isEmpty {
            say("Choose which features you want.", "grux setup",
                "Nothing is turned on, so Grux has nothing to ask for and nothing to do. "
                + "Setup takes a minute and asks for no permission until you have picked.",
                .waitingOnYou)
        }

        // Blocking first, and among blocking, the capability that unblocks the MOST chosen
        // features. Ties broken by effort: a job you can run beats a dialog you must click,
        // which beats a credential you have to go and sign up for.
        let effort = ["step": 0, "perm": 1, "endpoint": 2, "key": 3]
        struct Candidate { let cap: SetupStatus.Capability; let blocks: [String] }
        let candidates: [Candidate] = status.capabilities.compactMap { cap in
            guard !cap.satisfied else { return nil }
            let blocking = Lookup.wanters(of: cap.id, in: status)
                .filter { $0.want == .blocking }.map(\.feature.label)
            guard !blocking.isEmpty else { return nil }
            return Candidate(cap: cap, blocks: blocking)
        }

        if let best = candidates.max(by: { a, b in
            if a.blocks.count != b.blocks.count { return a.blocks.count < b.blocks.count }
            let ea = effort[a.cap.kind] ?? 9, eb = effort[b.cap.kind] ?? 9
            if ea != eb { return ea > eb }
            return a.cap.label > b.cap.label
        }) {
            let n = best.blocks.count
            say(best.cap.remediation ?? "Set up \(best.cap.label).",
                "grux why \(best.cap.id)",
                "\(best.cap.label) is the one thing blocking the most: \(n) "
                + "feature\(n == 1 ? "" : "s") you turned on cannot run without it, namely "
                + r.list(best.blocks) + ".",
                .waitingOnYou,
                // BLOCKING ONLY, to match the sentence directly above it. Every wanter
                // would be a defensible scope and it read as a contradiction on screen: the
                // prose named three features that cannot run without this and the command
                // under it listed seven. A reader who spots that stops trusting both numbers.
                scope: Lookup.wanters(of: best.cap.id, in: status)
                    .filter { $0.want == .blocking }.map(\.feature.id))
        }

        let unmet = chosen.compactMap { f -> (String, [String])? in
            let missing = f.dependsOn.filter { id in !chosen.contains { $0.id == id } }
            return missing.isEmpty ? nil : (f.label, missing)
        }
        if let (feature, needs) = unmet.first {
            let names = needs.map { id in status.features.first { $0.id == id }?.label ?? id }
            say("Turn on \(r.list(names)), or turn off \(feature).",
                "grux enable \(needs.joined(separator: " "))",
                "\(feature) is on and needs \(r.list(names)), which "
                + (names.count == 1 ? "is" : "are") + " off. No permission expresses that, "
                + "so nothing will prompt you for it.",
                .waitingOnYou,
                scope: needs + chosen.filter { $0.label == feature }.map(\.id))
        }

        // THE EMPTY STATE, designed rather than left blank. "Nothing to do here" is a real
        // answer and it deserves the same frame as the others.
        let optionalMissing = status.capabilities.filter {
            !$0.satisfied && !Lookup.wanters(of: $0.id, in: status).isEmpty
        }
        if optionalMissing.isEmpty {
            say("Nothing. Everything you chose is set up.", nil,
                "\(chosen.count) of \(status.features.count) features are on and all of "
                + "them have what they need.", .done)
        }
        say("Nothing you have to do.", "grux status",
            "Everything blocking is done. \(optionalMissing.count) optional "
            + "thing\(optionalMissing.count == 1 ? "" : "s") would make features better, "
            + "and none of them stops anything working.", .done,
            scope: optionalMissing
                .flatMap { Lookup.wanters(of: $0.id, in: status).map(\.feature.id) })
    }
}
