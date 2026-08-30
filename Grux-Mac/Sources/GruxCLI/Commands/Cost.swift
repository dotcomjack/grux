import ArgumentParser
import Foundation
import GruxSetupCore

// MARK: - grux cost

/// THE PRODUCT CLAIM, AS A COMMAND.
///
/// gruxai.com says a permission is only ever requested because a feature you picked needs
/// it. That is either true of a given selection or it is not, so this prints the whole bill
/// for a selection before anything is asked for, including the list of things that will
/// never be asked for because nothing chosen uses them.
///
/// Read-only and asks for nothing. Somebody can price every combination they are curious
/// about before committing to any of them.
struct Cost: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cost",
        abstract: "What a set of features would ask for, and what it never would.")

    @Argument(help: "Feature ids. Run grux status --json to see them all.")
    var features: [String] = []

    @Flag(name: .long, help: "Emit the bill as JSON. For an agent.")
    var json = false

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

        let byID = Dictionary(uniqueKeysWithValues: status.features.map { ($0.id, $0) })
        let unknown = features.filter { byID[$0] == nil }
        if !unknown.isEmpty {
            // NAMED, not swallowed. Silently dropping a misspelled id would price a
            // selection the person did not ask for and report it as theirs.
            print("")
            print(r.prose("No feature called \(unknown.joined(separator: ", ")). "
                          + "Run grux status --json to see every id."))
            leave(.failed)
        }
        let chosen = features.compactMap { byID[$0] }

        let bill = GruxSetupCore.Cost.of(features: chosen,
                                         allCapabilities: status.capabilities.map(\.id),
                                         allFeatures: status.features)

        if json {
            var out: [String: Any] = [
                "features": chosen.map(\.id),
                "blocking": bill.blocking,
                "degrading": bill.degrading,
                "never": bill.never,
                "choices": bill.choices.map {
                    ["feature": $0.feature, "capabilities": $0.capabilities, "min": $0.min]
                },
                "unmetDependencies": bill.unmetDependencies.map {
                    ["feature": $0.feature, "needs": $0.needs]
                },
            ]
            out["summary"] = ["required": bill.blocking.count,
                              "optional": bill.degrading.count,
                              "never": bill.never.count]
            if let data = try? JSONSerialization.data(withJSONObject: out,
                                                     options: [.prettyPrinted, .sortedKeys]),
               let text = String(data: data, encoding: .utf8) { print(text) }
            leave(bill.unmetDependencies.isEmpty ? .done : .waitingOnYou)
        }

        frame.open(.cost)
        let labels = Dictionary(uniqueKeysWithValues: status.capabilities.map { ($0.id, $0.label) })

        if chosen.isEmpty {
            print(r.row(state: .satisfied, label: "You picked nothing, so nothing is asked for.",
                        labelWidth: 0))
            print("")
            print(r.style.ink(.dim, r.prose(
                "Grux would start with an empty sidebar. Every feature is one command away "
                + "later, and each one asks for its own things at the moment you add it.")))
            frame.handOff([], because: "An empty selection asks for nothing, so there is "
                + "nothing here for an agent to do.")
            leave(.done)
        }

        let subject = chosen.count == 1 ? "it" : "they"
        print(r.prose("If you picked \(r.list(chosen.map(\.label))), this is everything "
                      + "\(subject) would ever ask you for."))

        // THE SAME RENDERER `grux setup` uses. These two commands answer the same question
        // and had two separate copies of this screen, which is how they drifted: one grouped
        // its asks by kind and the other printed a flat list of nineteen.
        let view = BillView(renderer: r, capabilities: status.capabilities)
        view.lines(for: bill, selectionCount: chosen.count,
                   totalCapabilities: status.capabilities.count).forEach { print($0) }

        print(r.rule())
        print(r.style.ink(.dim, view.summary(for: bill, selectionCount: chosen.count,
                                             totalCapabilities: status.capabilities.count)))
        // SCOPED TO WHAT WAS JUST PRICED. `grux cost meetings chat` answers a question
        // about two features, so the prompt it hands back is about those two.
        frame.handOff(chosen.map(\.id))
        leave(bill.unmetDependencies.isEmpty ? .done : .waitingOnYou)
    }
}
