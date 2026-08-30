import ArgumentParser
import Foundation
import GruxSetupCore

// MARK: - Shared frame

struct Frame {
    let renderer: Renderer
    let style: TerminalStyle

    init() {
        let style = TerminalStyle.detect()
        self.style = style
        self.renderer = Renderer(style: style)
    }

    func open(_ beat: Beat, _ subtitle: String? = nil) {
        let rail = renderer.rail(current: beat)
        if !rail.isEmpty { print("\n  " + rail) }
        if let subtitle {
            print("\n" + renderer.prose(subtitle))
        }
        print("")
    }

    /// One sentence for a control-socket failure, with a REFUSAL unwrapped.
    ///
    /// `MCPWire.textFailure` arrives as `.toolFailed(message)`, and three call sites printed
    /// it through string interpolation, so a refusal rendered as:
    ///
    ///     Could not reach Grux: toolFailed("No feature called nonesuch.")
    ///
    /// Grux was reached. It answered. It said no, and the answer sat inside a wrapper nobody
    /// opened, while the sentence in front of it sent the reader off to check whether the app
    /// was running. The distinction matters because the two have opposite fixes.
    func explain(_ failure: ControlClient.Failure) -> String {
        switch failure {
        case .toolFailed(let message):
            // VERSION SKEW HAS ITS OWN SENTENCE. "Unknown tool: grux_config" is the app
            // telling the truth and telling it uselessly: the reader has a newer binary than
            // the Grux that is running, which happens to anybody who installs an update
            // while the old app is still up. The fix is restarting Grux, and nothing in the
            // raw message says so.
            if message.hasPrefix("Unknown tool:") {
                let tool = message.dropFirst("Unknown tool:".count)
                    .trimmingCharacters(in: .whitespaces)
                return "The Grux that is running does not have \(tool). This binary is newer "
                     + "than the app it is talking to, which happens when an update installs "
                     + "while Grux is still open. Quit Grux and open it again."
            }
            return message

        case .notRunning:
            return "Grux is not running, and it owns this. Open it and run this again."

        case .couldNotConnect(_, let errno):
            switch errno {
            case ECONNREFUSED:
                // THE COMMON ONE, AND IT USED TO PRINT AN ERRNO. Quitting Grux leaves the
                // socket file behind, so "no socket file" is false and this fires instead.
                // From where the reader sits those are the same fact. Measured: with Grux
                // quit, `grux handoff` printed
                // `Could not reach Grux: couldNotConnect(path:` and stopped mid-word.
                return "Grux is not running. The socket file it left behind is still there, "
                     + "which is normal. Open Grux and run this again."
            case EACCES, EPERM:
                return "That socket belongs to another user account. Grux talks only to the "
                     + "person running it, so run this as the account Grux is running under."
            case ENOENT:
                return "Grux is not running. Open it and run this again."
            default:
                return "Grux left a socket open but will not talk to it (error \(errno)). "
                     + "Quitting Grux and opening it again clears this."
            }

        case .noAnswer(let seconds):
            // RUNNING BUT NOT ANSWERING is a different problem from not running, and it
            // wants a different action: waiting, not launching.
            return "Grux is running but did not answer within \(Int(seconds)) seconds. It is "
                 + "probably busy starting up, which takes a while on a cold launch."

        case .badAnswer:
            return "Grux answered something this command could not read. The two came from "
                 + "different builds. The grux inside Grux.app always matches the app it "
                 + "shipped with."
        }
    }

    /// The HAND OFF beat, naming the exact command that renders a prompt for what was just
    /// shown.
    ///
    /// ## Why this is a line and not a prompt
    ///
    /// The literal reading of "every command emits a handoff" was rejected on inspection:
    /// sixty lines of agent prompt after `grux which perm.microphone` is noise, and it would
    /// make the one command written to be grepped unusable. The settled shape is
    /// `grux handoff [features...]`, and what the other commands owe is the SCOPE: an answer
    /// about two features should hand you the command that writes the prompt for those two,
    /// already typed.
    ///
    /// So the beat is printed by every command that has a scope, and it is one line somebody
    /// can copy. A command with nothing to scope prints the beat and passes through, which
    /// is the same rule the rail follows: a beat that is missing looks like a beat with
    /// something to hide.
    ///
    /// Nothing here re-derives what a handoff says. `AgentHandoff` in the app is the single
    /// renderer and this only ever names the way to reach it.
    func handOff(_ features: [String], because reason: String? = nil) {
        let rail = renderer.rail(current: .handOff)
        if !rail.isEmpty { print("\n  " + rail) }
        print("")
        // SORTED AND DEDUPED, so the same answer produces the same line twice running. The
        // callers build these from set operations and a set has no order, which would
        // otherwise make this command fail its own idempotence check on the text alone.
        let scope = Array(Set(features)).sorted { $0.lowercased() < $1.lowercased() }
        if scope.isEmpty {
            print(renderer.prose(reason ?? "Nothing here needs an agent. Everything this "
                + "command found is either done or yours to do."))
            return
        }
        if let reason { print(renderer.prose(reason)) ; print("") }
        // WRAPPED AS A SHELL CONTINUATION, not left to run off the edge. Measured:
        // `grux why key.anthropic` scopes to fifteen features and printed a 150 character
        // line into an 80 column terminal. Clipping it would be worse than wrapping, because
        // this line exists to be pasted and a clipped command is a broken one.
        for line in renderer.wrapCommand("grux handoff " + scope.joined(separator: " "),
                                         width: style.width - 4) {
            print("    " + style.ink(.accent, line))
        }
        print("")
        print(style.ink(.dim, renderer.prose("That writes a prompt for your own coding "
            + "agent, covering only the parts an agent may do.", indent: 2)))
    }

    /// Every designed failure state for reading the status document.
    ///
    /// Each of these gets its own words because they need different things from a person.
    /// "Grux has never run" is not an error, it is the expected state of a fresh install and
    /// the answer is to open the app once.
    func explain(_ error: SetupStatusReadError) -> Exit {
        switch error {
        case .neverWritten(let path):
            print(renderer.prose("Grux has not written its setup status yet, which almost "
                + "always means the app has not been opened on this Mac."))
            print("")
            print(renderer.prose("Open Grux once and run this again. It writes "
                + "\(path) at launch.", indent: 2))
            return .waitingOnYou
        case .unreadable(let path):
            print(renderer.prose("The setup status at \(path) will not parse."))
            print("")
            print(renderer.prose("Grux writes it atomically, so a half-written file should "
                + "not be possible. Something else has edited it. Run grux doctor.", indent: 2))
            return .selfRepairAvailable
        case .unsupportedSchema(let found, let supported):
            print(renderer.prose("This grux speaks setup schema \(supported) and the Grux on "
                + "this Mac wrote schema \(found)."))
            print("")
            print(renderer.prose("They came from different builds. The binary in "
                + "Grux.app/Contents/MacOS always matches the app it shipped with.", indent: 2))
            return .failed
        }
    }
}
