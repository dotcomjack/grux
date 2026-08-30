import ArgumentParser
import Foundation
import GruxSetupCore

// MARK: - grux doctor

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "What this Mac has. Asks for nothing and changes nothing.")

    /// Accepted by every command, and it means one thing on all of
    /// them. See InputPolicy.
    @OptionGroup var input: InputPolicy

    func run() throws {
        let frame = Frame()
        let r = frame.renderer
        let client = ControlClient()
        frame.open(.look, "Nothing on this screen asks you for anything.")

        let app = FileManager.default.fileExists(atPath: "/Applications/Grux.app")
        print(r.row(state: app ? .satisfied : .needed,
                    label: "Grux.app", detail: "/Applications/Grux.app", labelWidth: 22))

        let running = client.isAvailable
        print(r.row(state: running ? .satisfied : .optional,
                    label: "Control socket", detail: client.socketPath, labelWidth: 22))

        let statusResult = SetupStatusReader.read()
        switch statusResult {
        case .success(let s):
            let age = SetupStatusReader.age(of: s).map(Status.ago) ?? "unknown age"
            print(r.row(state: .satisfied, label: "Setup status",
                        detail: "schema \(s.schema), \(age)", labelWidth: 22))
            print(r.row(state: .satisfied, label: "Grux version",
                        detail: s.appVersion, labelWidth: 22))
        case .failure:
            print(r.row(state: .needed, label: "Setup status",
                        detail: SetupStatusReader.defaultURL.path, labelWidth: 22))
        }

        print("")
        print(r.legend([.satisfied, .needed, .optional]))
        print("")

        // Doctor's whole job is to name the next action, so it ends by naming one.
        if !app {
            print(r.prose("Grux is not installed at /Applications/Grux.app. Nothing else here "
                          + "can be true until it is."))
            leave(.waitingOnYou)
        }
        if !running {
            print(r.prose("Grux is not running, so nothing can recompute the setup status or "
                          + "act on your behalf. Open it and run this again."))
            leave(.waitingOnYou)
        }
        if case .failure(let e) = statusResult {
            leave(frame.explain(e))
        }
        print(r.prose("Everything this command can check is in order."))
        leave(.done)
    }
}
