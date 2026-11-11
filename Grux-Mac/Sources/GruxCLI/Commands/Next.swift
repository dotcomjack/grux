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

        // LOOK, NOT PROVE. This command reads the status and changes nothing, and it ends on
        // the HAND OFF beat: opening at PROVE marked a later step at the top and an earlier
        // one at the bottom of the same answer.
        frame.open(.look)

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

        // ONE DECISION, shared with `grux doctor` through NextStep, so the two cannot tell a
        // person opposite things about the same Mac.
        switch NextStep.pick(status, signInExpired: ClaudeSignIn.expired()) {
        case .chooseFeatures:
            say("Choose which features you want.", "grux setup",
                "Nothing is turned on, so Grux has nothing to ask for and nothing to do. "
                + "Setup takes a minute and asks for no permission until you have picked.",
                .waitingOnYou)

        case .unblock(let cap, let blocking, let orUnblocks):
            say(cap.remediation ?? "Set up \(cap.label).",
                "grux why \(cap.id)",
                "Of everything missing, \(cap.label) unblocks the most: "
                + NextStep.unblockClauses(blocking: blocking.map(\.label),
                                          orUnblocks: orUnblocks.map(\.label), list: r.list)
                + ".",
                .waitingOnYou,
                // WHAT THIS ONE STEP UNBLOCKS, to match the sentence directly above it.
                // Every wanter would be a defensible scope and it read as a contradiction on
                // screen: the prose named three features and the command under it listed
                // seven. A reader who spots that stops trusting both numbers.
                scope: (blocking + orUnblocks).map(\.id))

        case .chooseOne(let options, let needed, let blocking):
            let n = blocking.count
            let some = needed == 1 ? "one of" : "\(needed) of"
            say("Set up \(some) \(r.either(options.map(\.label))).",
                options.first.map { "grux why \($0.id)" },
                "\(n) feature\(n == 1 ? "" : "s") you turned on cannot run until \(some) "
                + "these " + (needed == 1 ? "is" : "are") + " set up, namely " + r.list(blocking.map(\.label)) + ". "
                + options.map { "\($0.label): " + ($0.remediation ?? "Set up \($0.label).") }
                    .joined(separator: " "),
                .waitingOnYou,
                scope: blocking.map(\.id))

        case .turnOn(let needs, let feature):
            let names = needs.map { id in status.features.first { $0.id == id }?.label ?? id }
            say("Turn on \(r.list(names)), or turn off \(feature.label).",
                "grux enable \(needs.joined(separator: " "))",
                "\(feature.label) is on and needs \(r.list(names)), which "
                + (names.count == 1 ? "is" : "are") + " off. No permission expresses that, "
                + "so nothing will prompt you for it.",
                .waitingOnYou,
                scope: needs + [feature.id])

        case .signIn(let blocking):
            let a = ClaudeSignIn.nextAnswer(blocking: blocking.map(\.label), list: r.list)
            say(a.answer, a.command, a.why, .waitingOnYou)

        case .nothingRequired(let optionalMissing):
            // THE EMPTY STATE, designed rather than left blank. "Nothing to do here" is a
            // real answer and it deserves the same frame as the others.
            let chosen = Lookup.chosen(status)
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
}
