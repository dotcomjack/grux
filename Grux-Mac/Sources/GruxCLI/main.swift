import ArgumentParser
import Foundation
import GruxSetupCore

// The grux binary.
//
// Thin on purpose. Everything it knows comes from ~/.grux/setup-status.json, which the app
// writes, and everything it changes goes through the app's control socket. It carries no
// copy of the capability contract, because the app already resolved all of it and a second
// copy would be a second thing to keep in step.
//
// One command per file under Commands/. This file holds the ROOT and nothing else:
// the subcommand array below is the registration site, it is what `grux --help`
// prints, and CommandSurfaceTests parses THIS file and requires it to match the
// shipped/planned table in docs/cli-grammar.md exactly, both ways.

// MARK: - Root

struct Grux: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "grux",
        abstract: "Set up and drive Grux from the terminal.",
        discussion: """
            Every command runs the same six steps in the same order, so the twentieth reads \
            like the first:

              LOOK      what is already true on this Mac. Asks for nothing.
              CHOOSE    the features you want. Still asks for nothing.
              COST      exactly what that will ask for, and what it never will.
              GRANT     the asks, cheapest to refuse first. All skippable.
              HAND OFF  a prompt for your own coding agent, for the dull half.
              PROVE     what is set up, what is not, and how to check it yourself.

            Exit codes: 0 done, 1 failed, 2 waiting on you, 3 run grux doctor.
            """,
        subcommands: [Setup.self, Status.self, Doctor.self, List.self,
                      Enable.self, Disable.self, Cost.self, Handoff.self,
                      Why.self, Which.self, Next.self, Explain.self,
                      Permissions.self, Completion.self, Undo.self,
                      History.self, Spend.self, Journal.self, Logs.self,
                      Export.self,
                      Keys.self,
                      Connect.self, Disconnect.self,
                      Config.self,
                      Note.self, Use.self,
                      Add.self, Remove.self,
                      Approvals.self, Model.self,
                      Repair.self, Reset.self, Import.self,
                      SupportBundle.self, Intro.self,
                      Run.self, Ask.self, AgentCommand.self, Open.self,
                      Meeting.self, Transcribe.self, Shell.self,
                      Watch.self, Serve.self,
                      Version.self],
        defaultSubcommand: Status.self)
}

Grux.main()
