import ArgumentParser
import Foundation
import GruxSetupCore

// MARK: - grux handoff

/// The prompt to paste into your own coding agent.
///
/// Built by the app, not by this binary, because the app is the only thing that knows what
/// is actually missing and its `AgentHandoff` already carries a boundary that was corrected
/// once after review. A second renderer here would be a second place to get that wrong.
struct Handoff: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "A prompt for your own coding agent, covering only what an agent may do.",
        discussion: """
            With no arguments it covers everything still outstanding on this Mac.

            Name features to scope it: `grux handoff meetings chat` answers "what would it \
            take to get these two working", which is the question you have when you are \
            adding one thing rather than setting up from scratch.
            """)

    @Argument(help: "Feature ids to scope the prompt to. Omit for everything outstanding.")
    var features: [String] = []

    /// Accepted by every command, and it means one thing on all of
    /// them. See InputPolicy.
    @OptionGroup var input: InputPolicy

    func run() throws {
        let frame = Frame()
        let r = frame.renderer
        let client = ControlClient()
        let arguments: [String: Any] = features.isEmpty ? [:] : ["features": features]
        switch client.call(tool: "grux_handoff", arguments: arguments) {
        case .success(let text):
            // Plain, unindented, unstyled. This is going into somebody's clipboard and then
            // into an agent, and a rail or an escape sequence in the middle of it is noise
            // the agent has to be told to ignore.
            print(text)
            leave(.done)
        case .failure(.notRunning):
            print("")
            print(r.prose("Grux is not running, and it builds this from what is actually "
                          + "missing. Open it and run this again."))
            leave(.waitingOnYou)
        case .failure(.toolFailed(let message)):
            // A REFUSAL IS NOT A CONNECTION FAILURE, and reporting it as one sends somebody
            // to check whether Grux is running. Driven on the shipped binary,
            // `grux handoff nonesuch` printed:
            //     Could not reach Grux: toolFailed("No feature called nonesuch.")
            // Grux was reached. It answered. It said no, and the answer is right there
            // inside the wrapper nobody unwrapped.
            print("")
            print(r.prose(message))
            print("")
            print(r.style.ink(.dim, r.prose("Run grux list to see every feature.", indent: 2)))
            leave(.failed)
        case .failure(let why):
            print("")
            print(r.prose(frame.explain(why)))
            leave(.failed)
        }
    }
}
