import ArgumentParser
import Foundation
import GruxSetupCore

// MARK: - grux enable / disable

/// Shared body. Both commands are the same operation with a different boolean, and writing
/// them twice is how the two drift into disagreeing about what a warning looks like.
private func toggle(_ id: String?, on: Bool) -> Never {
    let frame = Frame()
    let r = frame.renderer

    // A DESIGNED EMPTY STATE, NOT A USAGE DUMP AND NOT EXIT 64. Somebody who typed
    // `grux enable` knows what a feature is; they have not named one yet. ArgumentParser
    // would have exited 64 here, which is not one of the four codes this surface documents
    // and which an agent reading 0, 1, 2, 3 cannot interpret.
    guard let id, !id.trimmingCharacters(in: .whitespaces).isEmpty else {
        let verb = on ? "on" : "off"
        frame.open(.look)
        print(r.prose("Name the feature to turn \(verb)."))
        print("")
        print("    " + r.style.ink(.accent, "grux \(on ? "enable" : "disable") <feature>"))
        print("")
        print(r.style.ink(.dim, r.prose("grux list shows every feature and its id, whether "
            + "or not you chose it.", indent: 2)))
        leave(.failed)
    }
    let client = ControlClient()

    switch client.call(tool: "grux_toggle_feature", arguments: ["id": id, "on": on]) {
    case .success(let text):
        // THE RAIL ON THE SUCCESS PATH TOO. It was opened only on the empty state, so the
        // one screen somebody actually sees when this works had no rail at all.
        frame.open(.prove)
        print(r.row(state: on ? .satisfied : .skipped, label: text, labelWidth: 0))
        // THE SCOPE IS THE FEATURE THAT WAS JUST TURNED ON. Turning something on is exactly
        // the moment its asks appear, so the prompt for them is the next thing somebody
        // wants. On a disable there is nothing to prepare, so the beat passes through.
        if on {
            frame.handOff([id])
        } else {
            frame.handOff([], because: "Turning something off asks for nothing, so there is "
                + "nothing here for an agent to do.")
        }
        if text.contains("Warning:") {
            print("")
            print(r.style.ink(.dim, r.prose(
                "Nothing was corrected for you. A selection that cannot do what you asked "
                + "is allowed to exist while you think about it.")))
            leave(.waitingOnYou)
        }
        leave(.done)
    case .failure(let why):
        frame.open(.look)
        switch why {
        case .notRunning:
            print(r.prose("Grux is not running, and it owns this setting. Open it and try "
                          + "again."))
            leave(.waitingOnYou)
        case .toolFailed(let message):
            print(r.prose(message))
            leave(.failed)
        default:
            print(r.prose(frame.explain(why)))
            leave(.failed)
        }
    }
}

struct Enable: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Turn one feature on.")
    @Argument(help: "A feature id. Run grux list to see them.") var id: String?
    /// Accepted by every command, and it means one thing on all of
    /// them. See InputPolicy.
    @OptionGroup var input: InputPolicy

    func run() throws { toggle(id, on: true) }
}

struct Disable: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Turn one feature off. It stays listed and can be turned back on.")
    @Argument(help: "A feature id. Run grux list to see them.") var id: String?
    /// Accepted by every command, and it means one thing on all of
    /// them. See InputPolicy.
    @OptionGroup var input: InputPolicy

    func run() throws { toggle(id, on: false) }
}
