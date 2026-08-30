import ArgumentParser
import Foundation
import GruxSetupCore

// MARK: - grux ask

/// One question, one answer, and the only command on this surface that spends money.
///
/// The output is shaped for two readers at once and they want opposite things. A person
/// wants the answer on the grid with the model and the clock under it; a pipe wants the
/// answer and not one byte else, because the second most likely thing anybody does with this
/// command is send it straight to `pbcopy`. So the frame, the rule and the machine detail are
/// all conditioned on `isTTY`, and a pipe gets the model's own bytes back unaltered.
struct Ask: ParsableCommand {

    /// How long to give the socket.
    ///
    /// Ten seconds is the default everywhere else and it is right everywhere else, because
    /// every other tool reads a file or flips a switch. This one waits on a model, which
    /// takes tens of seconds on a long answer and longer again when the turn calls a tool
    /// and goes back for a second hop. Three minutes sits deliberately OUTSIDE the handler's
    /// own 150 second deadline, so the app is the side that gets to describe a slow turn.
    /// The client's own timeout sentence talks about an app busy starting up, which would be
    /// exactly wrong here.
    static let waitSeconds: TimeInterval = 180

    static let configuration = CommandConfiguration(
        commandName: "ask",
        abstract: "One question to the chat surface. This one spends money.",
        discussion: """
            Everything after the command is the question. Quote it if it contains anything \
            your shell would eat.

              grux ask "what did I decide about the Meta ads"
              grux ask "summarise what I wrote today" | pbcopy

            IT SPENDS MONEY, and it is the only command here that does. One turn goes to \
            whichever model chat is routed to, and the ledger records the charge, so grux \
            spend shows it afterwards. A turn served by a local model costs nothing, and the \
            line under the answer names which one served this one.

            The answer prints first and on its own, so a pipe gets the text and nothing \
            else. On a terminal the model, the time it took and the thread print under it, \
            dimmed. It waits up to three minutes rather than the ten seconds every other \
            command uses, because ten is the wrong deadline for a model.
            """)

    @Argument(parsing: .remaining, help: "The question. Everything after the command.")
    var words: [String] = []

    /// Accepted by every command, and it means one thing on all of
    /// them. See InputPolicy.
    @OptionGroup var input: InputPolicy

    func run() throws {
        let frame = Frame()
        let r = frame.renderer

        let question = words.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else {
            frame.open(.look)
            // A designed empty state, not a usage dump. Somebody who typed `grux ask` and
            // stopped knows what a question is; they have just not typed one yet. The second
            // line is here because this is the command that costs, and the first thing worth
            // knowing about a mistyped one is that it did not.
            print(r.prose("Nothing to ask. Everything after the command becomes the question."))
            print("")
            print("    " + r.style.ink(.accent, "grux ask \"what did I decide about the ads\""))
            print("")
            print(r.style.ink(.dim, r.prose("This is the one command that spends money. "
                + "Nothing was spent.", indent: 4)))
            leave(.failed)
        }

        let client = ControlClient(timeout: Self.waitSeconds)
        switch client.call(tool: "grux_ask", arguments: ["text": question]) {
        case .failure(let why):
            frame.open(.look)
            print(r.prose(frame.explain(why)))
            // THE ONE FAILURE WHOSE SHARED SENTENCE IS INCOMPLETE HERE. `explain` says Grux
            // is running and did not answer, and offers starting up as the reason, which is
            // true for every other command and only half true for this one: a model that
            // took longer than three minutes is still going, and its answer is not lost.
            if case .noAnswer = why {
                print("")
                print(r.prose("Nothing was cancelled. If the model was simply slow, the "
                    + "answer lands in the Grux chat window.", indent: 2))
            }
            leave(.failed)

        case .success(let text):
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(text.utf8)))
                    as? [String: Any],
                  let state = obj["state"] as? String else {
                // A reply this cannot read is still something somebody paid for, so it is
                // printed rather than swallowed behind a complaint about parsing.
                print(text)
                leave(.failed)
            }
            let message = (obj["message"] as? String)
                ?? "Grux did not say what happened, which is itself the problem. Run grux doctor."

            switch state {
            case "answered":
                let answer = (obj["answer"] as? String) ?? ""
                guard !answer.isEmpty else {
                    // Reachable only if the app wrote an empty assistant turn. Reporting an
                    // empty string as an answer is the exact defect this command is built
                    // not to have, so it is named instead of printed.
                    frame.open(.look)
                    print(r.prose("Grux finished the turn and wrote nothing in it. Ask again, "
                        + "and read the thread in Grux if it happens twice."))
                    leave(.failed)
                }

                // A PIPE GETS THE BYTES AND NOTHING ELSE. `grux ask "..." | pbcopy` is the
                // reason this is worth having in a terminal at all, and a rail, a rule and a
                // model id in the paste would ruin it.
                guard r.style.isTTY else {
                    print(answer)
                    leave(.done)
                }

                frame.open(.prove)
                print(Self.laidOut(answer, r))
                print("")
                print(r.rule())
                print(Self.machineDetail(obj, r))
                leave(.done)

            case "not_ready":
                // A REAL EXIT 2. Nothing is attached to chat, so no invocation of this
                // command can succeed until somebody sits at this Mac and attaches one. Both
                // routes get named, because the free one needs no key and no account and is
                // otherwise invisible next to the one that does.
                frame.open(.look)
                print(r.prose(message))
                print("")
                print(r.prose("grux which key.anthropic says whether a missing key is the "
                    + "whole of it, and grux connect key.anthropic stores one. A local model "
                    + "needs neither.", indent: 2))
                leave(.waitingOnYou)

            case "blocked":
                frame.open(.look)
                print(r.prose(message))
                print("")
                print(r.prose("grux connect key.anthropic stores a different one. Nothing "
                    + "here is fixed by running it again.", indent: 2))
                leave(.waitingOnYou)

            case "failed", "still_working", "repeat", "unanswered":
                // Exit 1 rather than 2 for all four. A different question, or the same one a
                // moment later, can succeed, and exit 2 means the opposite of that: that
                // every invocation is blocked until a person acts.
                frame.open(.look)
                print(r.prose(message))
                leave(.failed)

            default:
                frame.open(.look)
                print(r.prose("Grux answered with an outcome this binary does not know "
                    + "about (\(state)). The two came from different builds, and the grux "
                    + "inside Grux.app always matches the app it shipped with."))
                print("")
                print(r.prose(message, indent: 2))
                leave(.failed)
            }
        }
    }

    /// The answer on the grid, with everything a paste would notice left alone.
    ///
    /// `prose` is the wrong tool for this one string in the whole CLI. It splits on the
    /// space character and rejoins on a single space, so it eats the indentation of a code
    /// block, and it never sees a newline, so three paragraphs come back as one. Lines are
    /// therefore wrapped only when they are BOTH too long for this terminal and plainly
    /// prose: a line that arrived with its own leading whitespace is somebody's code or a
    /// list that was already laid out, and rewrapping it destroys the only thing it had.
    private static func laidOut(_ answer: String, _ r: Renderer) -> String {
        answer.split(separator: "\n", omittingEmptySubsequences: false).map { raw -> String in
            let line = String(raw)
            if line.trimmingCharacters(in: .whitespaces).isEmpty { return "" }
            if line.first?.isWhitespace == true { return "  " + line }
            if line.count <= r.style.width - 2 { return "  " + line }
            return r.prose(line)
        }.joined(separator: "\n")
    }

    /// Model, backend, clock and thread, last and dimmed, on a grid sized from the widest
    /// label actually present rather than from a guess at what might be.
    private static func machineDetail(_ obj: [String: Any], _ r: Renderer) -> String {
        var rows: [(String, String)] = []
        if let model = obj["model"] as? String { rows.append(("Model", model)) }
        if let provider = obj["provider"] as? String { rows.append(("Served by", provider)) }
        if let seconds = obj["seconds"] as? Double {
            rows.append(("Took", String(format: "%.1f seconds", seconds)))
        }
        if let thread = obj["thread"] as? String { rows.append(("Thread", thread)) }
        let width = rows.map { $0.0.count }.max() ?? 0
        return rows.map { label, value in
            let padded = label + String(repeating: " ", count: width - label.count)
            return "  " + r.style.ink(.dim, padded + "  " + value)
        }.joined(separator: "\n")
    }
}
