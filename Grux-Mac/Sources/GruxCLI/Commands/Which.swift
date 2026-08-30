import ArgumentParser
import Foundation
import GruxSetupCore

// MARK: - grux which

/// One line, for an agent that is about to decide whether to do something.
///
/// Every other command here is written for a person and prints paragraphs. This one is
/// written for a script: one line, a stable shape, and an exit code that carries the answer
/// so the text never has to be parsed at all.
struct Which: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "which",
        abstract: "One line: is this capability ready, needed, or never going to be asked for.",
        discussion: """
            Exit code carries the answer, so a script never has to parse the text:
              0  ready, or nothing you chose uses it
              2  needed, and something you chose is blocked without it
              1  no capability by that name
            """)

    @Argument(help: "A capability id or its label. `perm.microphone` or `Microphone`.")
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
        // with a fifth. A designed empty state costs four lines and answers the question
        // somebody actually has, which is what to type next.
        guard let capability, !capability.isEmpty else {
            print(r.prose("Name a capability. This answers one thing about one of them: "
                + "satisfied, needed, or never asked for."))
            print("")
            print("    " + r.style.ink(.accent, "grux which perm.microphone"))
            print("")
            print(r.style.ink(.dim, r.prose("grux status lists all "
                + "\(status.capabilities.count) of them.", indent: 2)))
            leave(.failed)
        }

        guard let cap = Lookup.resolve(capability, in: status) else {
            print(r.prose("No capability called \(capability)."))
            let near = Lookup.nearest(capability, in: status)
            if !near.isEmpty {
                print(r.prose("Did you mean " + r.list(near) + "?", indent: 2))
            }
            leave(.failed)
        }

        let state = Lookup.state(of: cap, in: status)
        // ANSWER, then subject, then machine detail. The first draft printed
        // "+ Microphone  perm.microphone  ready", which puts the one word somebody ran this
        // command to get at the far right of the line, past the id they already knew.
        print("  " + r.style.ink(state.ink, state.glyph + " " + state.word)
              + "  " + cap.label
              + "  " + r.style.ink(.dim, cap.id))
        // THE SCOPE, ON STDERR. This command is one line for a script to grep and its exit
        // code carries the answer, so anything else on stdout breaks the one promise it
        // makes. A person still gets the handoff; `grux which x | read` still gets one line.
        let wanters = Lookup.wanters(of: cap.id, in: status).map(\.feature.id)
        if !wanters.isEmpty, state != .satisfied, state != .attested {
            let scope = Array(Set(wanters)).sorted { $0.lowercased() < $1.lowercased() }
            FileHandle.standardError.write(Data(
                ("grux handoff " + scope.joined(separator: " ") + "\n").utf8))
        }
        leave(state == .needed ? .waitingOnYou : .done)
    }
}
