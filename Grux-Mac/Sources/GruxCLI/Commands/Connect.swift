import ArgumentParser
import Foundation
import GruxSetupCore

// MARK: - grux connect / grux disconnect

/// Store one credential, read from the terminal with the echo off.
///
/// ## The one rule this command exists to hold
///
/// A SECRET NEVER ARRIVES AS AN ARGUMENT. There is no `--value` flag and no environment
/// variable, and adding either would be the bug rather than a convenience. A flag lands in
/// shell history and in `ps` output visible to every process on the machine. An environment
/// variable is inherited by every child process. Neither can be taken back afterwards, and
/// somebody pasting a key has no reason to expect either.
///
/// So this refuses to run without a terminal rather than reading from a pipe. A piped secret
/// came from a file, a history entry, or another process's arguments, which are the three
/// places this is trying to keep it out of.
struct Connect: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "connect",
        abstract: "Store one credential. Prompts with the echo off, never takes a flag.",
        discussion: """
            There is deliberately no way to pass the value as an argument. Run this in a \
            terminal and paste when it asks.

            Run with no argument to see what can be connected.
            """)

    @Argument(help: "A key.* capability id, or its label. Omit to list them.")
    var service: String?

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

        guard let service else { listConnectable(status, frame); leave(.done) }

        guard let cap = Lookup.resolve(service, in: status) else {
            frame.open(.look)
            print(r.prose("No credential called \(service)."))
            let near = Lookup.nearest(service, in: status).filter { id in
                status.capabilities.first { $0.id == id }?.kind == "key"
            }
            if !near.isEmpty {
                print(r.prose("Did you mean " + r.list(near) + "?", indent: 2))
            }
            leave(.failed)
        }

        guard cap.kind == "key" else {
            frame.open(.look)
            // Each wrong kind gets its own sentence, because each needs a different action.
            switch cap.kind {
            case "perm":
                print(r.prose("\(cap.label) is a macOS permission, not a credential. No "
                              + "terminal command can grant one: macOS keys a permission to "
                              + "the app that asks, so opening Grux is the only way."))
            case "endpoint":
                print(r.prose("\(cap.label) is an address rather than a secret, so it is set "
                              + "in Settings where you can see it and correct a typo."))
            default:
                print(r.prose("\(cap.label) is a setup step, not something to paste."))
            }
            leave(.failed)
        }

        frame.open(.grant, cap.satisfied
            ? "\(cap.label) is already stored. Entering one replaces it."
            : "\(cap.label). Nothing you type is shown, and nothing is written to your shell "
              + "history.")

        if let why = cap.remediation, !cap.satisfied {
            print(r.prose(why, indent: 2))
            print("")
        }

        let secret: String
        do {
            guard input.canAsk else {
                print("")
                print(r.prose("A credential is only ever read from a terminal with the "
                    + "echo off, and --no-input says there is nobody at one. Run this "
                    + "without --no-input, or paste it into Grux itself."))
                leave(.failed)
            }
            secret = try SecretPrompt.read("  paste it, then press return: ")
        } catch SecretPrompt.Failure.notATerminal {
            print(r.prose("Nothing is attached to this terminal. A credential is only ever "
                          + "read from a real terminal with the echo off, so there is no "
                          + "flag and no environment variable that would work here either."))
            leave(.failed)
        } catch SecretPrompt.Failure.empty {
            print(r.prose("Nothing entered, so nothing was stored."))
            leave(.done)
        } catch {
            print(r.prose("Left without storing anything."))
            leave(.done)
        }

        let client = ControlClient()
        switch client.call(tool: "grux_connect",
                           arguments: ["capability": cap.id, "value": secret]) {
        case .success(let message):
            print("")
            print(r.row(state: .satisfied, label: message, labelWidth: 0))
            print("")
            let wants = Lookup.wanters(of: cap.id, in: status).map(\.feature.label)
            if !wants.isEmpty {
                print(r.style.ink(.dim, r.prose("That unblocks " + r.list(wants) + ".",
                                                indent: 2)))
            }
            leave(.done)
        case .failure(let why):
            print("")
            print(r.prose(frame.explain(why)))
            leave(.failed)
        }
    }

    private func listConnectable(_ status: SetupStatus, _ frame: Frame) {
        let r = frame.renderer
        frame.open(.look, "Credentials you can connect. Run grux connect <id>.")
        let keys = status.capabilities.filter { $0.kind == "key" }
            .sorted { $0.label.lowercased() < $1.label.lowercased() }
        let width = keys.map(\.label.count).max() ?? 20
        for k in keys {
            print(r.row(state: k.satisfied ? .satisfied : .needed, label: k.label,
                        detail: k.id, labelWidth: width, indent: 4))
        }
        print("")
        print(r.prose("\(keys.filter(\.satisfied).count) of \(keys.count) are stored."))
    }
}

/// Forget one credential.
///
/// Naming what stops working is the whole design. "Removed" tells somebody nothing about
/// whether they have just broken their morning.
struct Disconnect: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "disconnect",
        abstract: "Forget one credential, and say what stops working.")

    @Argument(help: "A key.* capability id, or its label. Omit to list them.")
    var service: String?

    @Flag(name: .long, help: "Do not ask. For a script that has already asked.")
    var yes = false

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
        guard let service, !service.isEmpty else {
            frame.open(.look)
            let stored = status.capabilities.filter { $0.kind == "key" && $0.satisfied }
                .sorted { $0.label.lowercased() < $1.label.lowercased() }
            print(r.prose("Name the credential to forget. Forgetting one removes it from "
                + "the Keychain and never touches the account it belongs to."))
            print("")
            if stored.isEmpty {
                print(r.row(state: .skipped, label: "Nothing is stored", labelWidth: 0))
            } else {
                let w = stored.map { $0.label.count }.max() ?? 12
                for c in stored {
                    print(r.row(state: .satisfied, label: c.label, detail: c.id,
                                labelWidth: w, indent: 4))
                }
                print("")
                print(r.style.ink(.dim, r.prose("\(stored.count) stored. grux keys shows "
                    + "every credential, stored or not.", indent: 2)))
            }
            leave(.failed)
        }

        guard let cap = Lookup.resolve(service, in: status), cap.kind == "key" else {
            frame.open(.look)
            print(r.prose("No credential called \(service). Run grux keys to see them."))
            leave(.failed)
        }
        guard cap.satisfied else {
            frame.open(.look)
            print(r.prose("\(cap.label) is not stored, so there is nothing to forget."))
            leave(.done)
        }

        frame.open(.cost, "This is what stops working.")
        let blocking = Lookup.wanters(of: cap.id, in: status)
            .filter { $0.want == .blocking }.map(\.feature.label)
        let degrading = Lookup.wanters(of: cap.id, in: status)
            .filter { $0.want != .blocking }.map(\.feature.label)

        if blocking.isEmpty && degrading.isEmpty {
            print(r.prose("Nothing you chose uses \(cap.label), so forgetting it changes "
                          + "nothing you would notice."))
        } else {
            if !blocking.isEmpty {
                print(r.row(state: .needed, label: "Stops working",
                            detail: r.list(blocking), labelWidth: 16))
            }
            if !degrading.isEmpty {
                print(r.row(state: .optional, label: "Gets worse",
                            detail: r.list(degrading), labelWidth: 16))
            }
        }

        if !yes {
            guard input.canAsk else {
                print("")
                print(r.prose("Nothing is attached to this terminal, so there is nobody to "
                              + "ask. Pass --yes if you are sure."))
                leave(.failed)
            }
            let typed = InputPolicy.ask([
                "",
                "  Type the credential's id to confirm, or anything else to stop.",
                "  " + r.style.ink(.accent, cap.id),
                "",
            ])
            guard typed == cap.id else {
                print("")
                print(r.prose("Left it alone."))
                leave(.done)
            }
        }

        let client = ControlClient()
        switch client.call(tool: "grux_disconnect", arguments: ["capability": cap.id]) {
        case .success(let message):
            frame.open(.prove)
            print(r.row(state: .satisfied, label: message, labelWidth: 0))
            leave(.done)
        case .failure(let why):
            print("")
            print(r.prose(frame.explain(why)))
            leave(.failed)
        }
    }
}
