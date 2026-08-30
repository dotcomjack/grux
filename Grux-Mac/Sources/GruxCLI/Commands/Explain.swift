import ArgumentParser
import Foundation
import GruxSetupCore

// MARK: - grux explain

/// What a word means here, in the words the rest of the product already uses.
///
/// A CLI that invents vocabulary and then never defines it makes the person guess, and they
/// guess wrong in the direction that costs them: "optional" reads as "you can skip setup",
/// "self attested" reads as nothing at all. The rule this serves is that the same word means
/// the same thing in the CLI, the app and the handoff, and a word nobody can look up is a
/// word that has already started to drift.
struct Explain: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "explain",
        abstract: "What a word means here. Run with no topic to list them.")

    @Argument(help: "A topic. Run with nothing to see them all.")
    var topic: String?

    /// Written out rather than generated, because a definition is prose somebody wrote on
    /// purpose. Keyed by the word a person would actually type.
    static let topics: [(key: String, title: String, body: String)] = [
        ("beats", "The six beats", """
            Every command runs the same six steps in the same order, and prints a rail at \
            the top saying which one it is on, so the twentieth command reads like the first. \
            LOOK is what is already true and asks for nothing. CHOOSE is what you want, and \
            still asks for nothing. COST is exactly what that choice will request, and what \
            it never will. GRANT is the asking, cheapest to refuse first, and every ask is \
            skippable. HAND OFF is a prompt for your own coding agent covering the dull half. \
            PROVE is what is true afterwards and how to check it yourself. A command with \
            nothing to do in a beat still prints it, because a rail missing COST looks like a \
            command with something to hide.
            """),
        ("capability", "A capability", """
            One thing Grux might need: a macOS permission, a credential, an address of a \
            server, or a one-time job. There are 41 of them and they are the only things \
            Grux will ever ask you for. Every one has an id an agent can use and a label a \
            person can read, and they are the same thing under two names.
            """),
        ("feature", "A feature", """
            One surface of Grux, like Meetings or Chat. There are 39. A feature declares the \
            capabilities it cannot run without and the ones that merely make it better, and \
            that declaration is the ONLY reason Grux ever asks you for anything. Turn a \
            feature off and everything only it wanted stops being asked for.
            """),
        ("optional", "Optional", """
            The feature runs without it, on a lesser path. It is not a soft version of \
            required and skipping it does not leave you half set up: it leaves you with a \
            feature that works and does a bit less. Anything the feature genuinely cannot \
            run without is REQUIRED and is never described this way.
            """),
        ("any-of", "An any-of group", """
            Several capabilities where any one of them is enough. Chat needs a hosted key OR \
            a local model, not both. Reading the requirement list alone would tell you to go \
            and fetch two credentials for something that needs one, which is exactly the \
            over-asking this design exists to stop, so a grouped capability is shown as a \
            group and never as two separate demands.
            """),
        ("depends-on", "A dependency", """
            One feature needing another feature, rather than needing a capability. Speakers \
            needs Meetings running, and no permission or credential can express that. Grux \
            will not silently turn the other one on for you, and it will not stop you leaving \
            it half configured while you think about it. It will say so every time you ask.
            """),
        ("self-attested", "Self attested", """
            True because you said so, not because Grux went and looked. Six of the setup \
            steps are consent and settings decisions that nothing can detect: whether you \
            will tell people you are recording, what stays private. The other four ARE \
            detected, so ticking a box is not what makes them true. The status document \
            flags which is which so nothing has to guess.
            """),
        ("socket", "The control socket", """
            A Unix domain socket at ~/.grux/mcp.sock, mode 0600, speaking MCP. It is how this \
            binary asks the app to change something. Grux opens no network port, so nothing \
            off this Mac can reach it, and nothing running as another user can either. \
            Reads do not use it at all: they come from a file, so they work with Grux closed.
            """),
        ("permissions", "Why a permission needs the app", """
            macOS attaches a permission to the exact program that asked for it. A permission \
            granted to your terminal is granted to your terminal, and Grux still would not \
            have it. So no command here can grant one, ever. The app asks, and this binary \
            can only tell you what is still outstanding.
            """),
        ("exit-codes", "Exit codes", """
            0 done. 1 the command was wrong, fix the invocation and try again. 2 waiting on \
            you, meaning no invocation of this command can succeed until a person does \
            something on this Mac. 3 run grux doctor. The gap between 1 and 2 is the useful \
            part: 2 is the only one that means stop and go and find a human.
            """),
        ("handoff", "The handoff", """
            A prompt you paste into your own coding agent. It names only the work an agent \
            may actually do and says plainly what it must not touch, which is every \
            credential and every consent decision. It is scoped to the features you chose, \
            so it never sends your agent off to fetch a token for something you turned off.
            """),
    ]

    /// Accepted by every command, and it means one thing on all of
    /// them. See InputPolicy.
    @OptionGroup var input: InputPolicy

    func run() throws {
        let frame = Frame()
        let r = frame.renderer
        frame.open(.look)

        guard let topic else {
            print(r.prose("Words this product uses on purpose. Run grux explain <topic>."))
            print("")
            let width = Self.topics.map(\.key.count).max() ?? 12
            for t in Self.topics {
                print("    " + r.style.ink(.accent, t.key.padding(toLength: width,
                                                                  withPad: " ", startingAt: 0))
                      + "  " + r.style.ink(.dim, t.title))
            }
            leave(.done)
        }

        let lowered = topic.lowercased()
        guard let hit = Self.topics.first(where: { $0.key == lowered })
                     ?? Self.topics.first(where: { $0.key.contains(lowered) })
                     ?? Self.topics.first(where: { $0.title.lowercased().contains(lowered) })
        else {
            print(r.prose("Nothing here explains \(topic)."))
            print("")
            print(r.style.ink(.dim, r.prose("Run grux explain with no topic to see the list.",
                                            indent: 2)))
            leave(.failed)
        }

        print("  " + r.heading(hit.title))
        print("")
        print(r.prose(hit.body, indent: 2))
        leave(.done)
    }
}
