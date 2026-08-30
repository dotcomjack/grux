import ArgumentParser
import Foundation
import GruxSetupCore

// MARK: - grux permissions

/// The macOS grants, alone, with who is asking for each.
///
/// Separated from `status` because a permission is the only kind of ask a person cannot
/// delegate, cannot script and cannot undo from a terminal. Mixed into a list of forty one
/// rows they are easy to miss; on their own they are a short, finite list of dialogs.
///
/// THIS COMMAND CANNOT GRANT ANYTHING and says so. TCC keys a grant to the requesting
/// client's bundle id, so a permission approved for this binary would be a permission the
/// app still does not have. Measured directly in the TCC database, where `com.dcj.grux` and
/// `com.gruxai.grux` hold entirely separate rows.
struct Permissions: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "permissions",
        abstract: "The macOS permissions only, their state, and which features want them.")

    @Flag(name: .long, help: "Machine readable.")
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

        let perms = status.capabilities.filter { $0.kind == "perm" }
            // Case insensitive, for the reason spelled out in Keys.swift. The example
            // there ("fal.ai API key") no longer exists and no label starts lowercase today,
            // which is exactly when a sort like this quietly stops being exercised.
            .sorted { $0.label.lowercased() < $1.label.lowercased() }

        if json {
            let out = perms.map { cap -> [String: Any] in
                let wants = Lookup.wanters(of: cap.id, in: status)
                return ["id": cap.id, "label": cap.label, "satisfied": cap.satisfied,
                        "state": Lookup.state(of: cap, in: status).word,
                        "wantedBy": wants.map(\.feature.id).sorted()]
            }
            if let d = try? JSONSerialization.data(withJSONObject: out,
                                                  options: [.prettyPrinted, .sortedKeys]),
               let t = String(data: d, encoding: .utf8) { print(t) }
            leave(.done)
        }

        frame.open(.look, "Grux asks for these. This command cannot grant them and neither "
                          + "can any other terminal command.")

        var needed = 0, optional = 0, unused = 0
        for cap in perms {
            let state = Lookup.state(of: cap, in: status)
            switch state {
            case .needed:   needed += 1
            case .optional: optional += 1
            case .skipped:  unused += 1
            default: break
            }
            print(r.row(state: state, label: cap.label, detail: cap.id, labelWidth: 22))
            let wants = Lookup.wanters(of: cap.id, in: status)
            if wants.isEmpty {
                print("      " + r.style.ink(.dim, "nothing you chose uses it"))
            } else {
                let blocking = wants.filter { $0.want == .blocking }.map(\.feature.label)
                let soft = wants.filter { $0.want != .blocking }.map(\.feature.label)
                if !blocking.isEmpty {
                    print("      " + r.style.ink(.dim, "needed by " + r.list(blocking)))
                }
                if !soft.isEmpty {
                    print("      " + r.style.ink(.dim, "better for " + r.list(soft)))
                }
            }
        }

        print("")
        print(r.legend([.satisfied, .needed, .optional, .skipped]))
        print("")
        // COUNTS MATCH THE LIST ABOVE, derived from the same array rather than recounted,
        // and EVERY row is accounted for. The first version said "6 granted, 1 waiting on"
        // over a list of nine and left the reader to work out where the other two went.
        let granted = perms.filter(\.satisfied).count
        var parts = ["\(granted) granted"]
        if needed > 0 { parts.append("\(needed) something you chose is waiting on") }
        if optional > 0 { parts.append("\(optional) that would only make things better") }
        if unused > 0 { parts.append("\(unused) nothing you chose uses") }
        assert(granted + needed + optional + unused == perms.count)
        print(r.prose("\(perms.count) permissions. " + r.list(parts) + "."))
        print("")
        print(r.style.ink(.dim, r.prose(
            "macOS keys a permission to the app that asks for it, so granting one to a "
            + "terminal would not give it to Grux. Open Grux and it will ask.", indent: 2)))

        // A PERMISSION IS NEVER AN AGENT'S JOB, and this command says so at the top: no
        // terminal command can grant one. So the scope is the features BLOCKED by a missing
        // grant, which is what an agent can usefully prepare around.
        frame.handOff(perms.filter { !$0.satisfied }
            .flatMap { Lookup.wanters(of: $0.id, in: status).map(\.feature.id) })
        leave(needed == 0 ? .done : .waitingOnYou)
    }
}
