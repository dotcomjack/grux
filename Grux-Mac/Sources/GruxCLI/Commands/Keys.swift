import ArgumentParser
import Foundation
import GruxSetupCore

// MARK: - grux keys

/// Which credentials Grux holds, by NAME, and never a value.
///
/// ## Why this reads the status document rather than the Keychain
///
/// It could ask the Keychain directly: `KeychainStore.exists` is a presence check that never
/// returns data. But the status document already carries every credential Grux ASKS FOR,
/// with whether it is satisfied, so going to the Keychain would be a second source for a
/// question already answered, and it would need the app running for no gain.
///
/// It also draws a better line. The Keychain holds nineteen entries and several are internal:
/// the phone pairing secret, a Notion database id, a Telegram chat id. Those are not
/// credentials somebody manages, and listing them here would invite somebody to go looking
/// for a rotation flow that should not exist.
///
/// THIS COMMAND CANNOT PRINT A SECRET. Not "does not": cannot. It reads a file that records
/// presence and has no value in it, which is the same property that makes `grux export` safe.
struct Keys: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "keys",
        abstract: "Which credentials Grux holds, by name. Never shows a value.",
        discussion: """
            There is no flag that prints a secret, and there is no code path that could. \
            This reads Grux's status file, which records that a credential is present and \
            never records what it is.

            To add or replace one, use `grux connect <service>`, which prompts with the \
            echo off and hands it straight to the Keychain.
            """)

    @Flag(name: .long, help: "Machine readable. Names and presence only.")
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

        // CASE INSENSITIVE. A plain `<` is an ASCII comparison, so "fal.ai API key" sorted
        // after "Web search API key" purely because lowercase f is 0x66 and uppercase W is
        // 0x57. A person scanning an alphabetical list does not know that and reads it as
        // unsorted.
        //
        // That capability is gone (fal.ai was replaced by Replicate) and as of this commit
        // NO label starts lowercase, so nothing in the contract exercises this today. It
        // stays because the rule is right and the next lowercase label will arrive without
        // anybody remembering this; a sort that is only correct for the labels that happen
        // to exist is a sort that breaks silently.
        let keys = status.capabilities.filter { $0.kind == "key" }
            .sorted { $0.label.lowercased() < $1.label.lowercased() }

        if json {
            let out = keys.map { ["id": $0.id, "label": $0.label, "present": $0.satisfied] }
            if let d = try? JSONSerialization.data(withJSONObject: out,
                                                  options: [.prettyPrinted, .sortedKeys]),
               let t = String(data: d, encoding: .utf8) { print(t) }
            leave(.done)
        }

        frame.open(.look, "Names only. This command cannot read a value, and no flag makes it.")

        guard !keys.isEmpty else {
            print(r.prose("Grux asks for no credentials at all, which should not be "
                          + "possible. Run grux doctor."))
            leave(.selfRepairAvailable)
        }

        let held = keys.filter(\.satisfied)
        let missing = keys.filter { !$0.satisfied }
        let width = keys.map(\.label.count).max() ?? 20

        if !held.isEmpty {
            print("  " + r.heading("HELD"))
            for k in held {
                print(r.row(state: .satisfied, label: k.label, detail: k.id,
                            labelWidth: width, indent: 4))
            }
            print("")
        }

        if !missing.isEmpty {
            // WANTED and NOT WANTED are different, and lumping them together is how somebody
            // goes off to sign up for a service nothing they chose will ever use.
            let wanted = missing.filter { !Lookup.wanters(of: $0.id, in: status).isEmpty }
            let unwanted = missing.filter { Lookup.wanters(of: $0.id, in: status).isEmpty }

            if !wanted.isEmpty {
                print("  " + r.heading("NOT SET, and something you chose wants one"))
                for k in wanted {
                    let who = Lookup.wanters(of: k.id, in: status).map(\.feature.label)
                    print(r.row(state: .needed, label: k.label, detail: k.id,
                                labelWidth: width, indent: 4))
                    print("        " + r.style.ink(.dim, "for " + r.list(who)))
                }
                print("")
            }
            if !unwanted.isEmpty {
                print("  " + r.heading("NOT SET, and nothing you chose uses one"))
                for k in unwanted {
                    print(r.row(state: .skipped, label: k.label, detail: k.id,
                                labelWidth: width, indent: 4))
                }
                print("")
            }
        }

        print(r.rule())
        // EVERY ROW ACCOUNTED FOR.
        let wantedCount = missing.filter { !Lookup.wanters(of: $0.id, in: status).isEmpty }.count
        var parts = ["\(held.count) held"]
        if wantedCount > 0 { parts.append("\(wantedCount) something you chose wants") }
        let unwantedCount = missing.count - wantedCount
        if unwantedCount > 0 { parts.append("\(unwantedCount) nothing you chose uses") }
        print(r.prose("\(keys.count) credentials Grux can ask for. " + r.list(parts) + "."))
        print("")
        print(r.style.ink(.dim, r.prose(
            "grux connect <service> to add one. It prompts with the echo off and hands it "
            + "straight to the Keychain, so it never appears on screen or in your shell "
            + "history.", indent: 2)))

        // SCOPED TO WHAT IS MISSING. A credential that is already held needs nobody, and a
        // prompt naming every feature would ask an agent to work on things that are done.
        // The features are the scope rather than the key ids, because that is the shape
        // `grux handoff` takes.
        frame.handOff(missing.flatMap { Lookup.wanters(of: $0.id, in: status).map(\.feature.id) })
        leave(wantedCount > 0 ? .waitingOnYou : .done)
    }
}
