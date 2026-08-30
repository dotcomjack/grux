import ArgumentParser
import Foundation
import GruxSetupCore

// MARK: - grux serve

/// The MCP control plane on stdio, bridged to the app's unix socket.
///
/// For an agent that speaks MCP over stdio and cannot open a unix socket of its own. Every
/// line of stdin is handed to `~/.grux/mcp.sock` UNREAD and the app's answer comes back on
/// stdout as one line. That is the whole design: this file parses no methods, keeps no
/// session state, and never has to be taught a tool the app adds tomorrow.
/// `ControlClient.request` exists for exactly this and is the only call it makes.
///
/// ONE DIRECTION, BECAUSE THE APP NEVER SPEAKS FIRST. The socket server writes only inside
/// its response pump, so there is nothing to carry the other way and no reverse loop here.
/// The day it gains a server-initiated notification this needs a second reader, and a bridge
/// that silently dropped those would look like an app that had stopped emitting them.
struct Serve: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "The MCP control plane on stdio.",
        discussion: """
            Normally spawned by an MCP client rather than typed. It reads newline delimited \
            JSON-RPC on stdin, forwards each message to the running Grux, writes each reply \
            on stdout as one line, and ends when stdin closes.

            Nothing but protocol goes to stdout, so the rail and every diagnostic are on \
            stderr. Keep them: grux serve 2>~/grux-serve.log
            """)

    /// A forwarded tool call can transcribe a file, wake a model, or drive the app, so the
    /// client's ten second default is the wrong deadline for a carrier. Two minutes is long
    /// enough for the slowest tool the control plane exposes and short enough that a wedged
    /// app still produces a designed error instead of a client that waits forever.
    /// How long the bridge waits for the app, and it has to be the LONGEST any tool it
    /// carries can legitimately take.
    ///
    /// It was 120 seconds while `grux transcribe` allows 1800 and `grux run` allows 300, so
    /// a client calling `grux_transcribe` through this bridge got a timeout while the app was
    /// still working, and a real answer was reported as a failure. That is the worse
    /// direction of the two errors available here: waiting too long is visible and a client
    /// can give up, while giving up too early manufactures a failure out of a success.
    ///
    /// A BRIDGE MUST NOT IMPOSE A DEADLINE SHORTER THAN THE WORK. This one carries messages
    /// closed, so it cannot know which method is slow, which leaves one honest choice: the
    /// ceiling of the slowest. `ServeDeadlineTests` reads every `ControlClient(timeout:)` in
    /// the command surface and fails if any exceeds this, so adding a slower command without
    /// raising it is caught rather than remembered.
    ///
    /// Nothing is desynchronised by a late reply, and that half of the report was wrong:
    /// `ControlClient.request` opens its own socket per call and closes it on the way out,
    /// so a reply that arrives after a timeout lands on a closed descriptor rather than in
    /// front of the next request.
    static let deadline: TimeInterval = 1800

    /// Accepted by every command, and it means one thing on all of
    /// them. See InputPolicy.
    @OptionGroup var input: InputPolicy

    func run() throws {
        // A reader that has gone must surface as EPIPE on the write, never as a signal that
        // kills the process halfway through a reply. Same defence and the same fcntl as the
        // standalone stdio server in GruxMCPServer.
        _ = fcntl(STDOUT_FILENO, F_SETNOSIGPIPE, 1)

        let frame = Frame()
        let r = frame.renderer
        let client = ControlClient(timeout: Self.deadline)
        announce(frame: frame, client: client)

        // Five buckets that partition every message, so the count at the end can name each
        // one rather than reporting a total nobody can reconcile.
        var answered = 0, notified = 0, refused = 0, dropped = 0, unreadable = 0
        var unreachable = false

        while let line = readLine(strippingNewline: true) {
            // A blank line is not a message. The shared MCPLineSplitter drops an empty frame
            // for the same reason, and answering one with an unsolicited error would put
            // noise on a wire the client parses strictly. Trimming also takes the CR a
            // client writing CRLF leaves behind, which is not part of the JSON.
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }

            guard let any = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else {
                // ONE BAD LINE IS NOT THE END OF A SESSION. Exiting here would kill a
                // working client over a stray character, so it gets the parse error the
                // specification defines and the loop carries on.
                unreadable += 1
                send(Self.errorFrame(id: NSNull(), code: -32700,
                                     message: "That line was not JSON, so nothing was "
                                            + "forwarded to Grux. This bridge is still "
                                            + "reading."))
                continue
            }
            guard let message = any as? [String: Any] else {
                unreadable += 1
                send(Self.errorFrame(id: NSNull(), code: -32600,
                                     message: "That line was JSON but not a JSON-RPC "
                                            + "message, so it named no method to forward."))
                continue
            }

            // NO id MEMBER IS A NOTIFICATION, and the specification says a notification gets
            // no response. Waiting for one would stall this loop for the whole deadline on
            // every notifications/initialized, which is the first thing an MCP client sends
            // after initialize, so the bridge would look hung before it carried a call.
            guard let id = message["id"] else {
                switch client.request(message, waitForReply: false) {
                case .success:
                    notified += 1
                case .failure(let why):
                    dropped += 1
                    unreachable = true
                    // Nothing goes back: there is no id to answer to. Stderr is the only
                    // honest place to record that Grux never heard it.
                    note(r.prose("A notification did not reach Grux. It carries no id, so "
                                 + "there is nothing to answer and the client cannot be "
                                 + "told. " + frame.explain(why)))
                }
                continue
            }

            switch client.request(message) {
            case .success(let reply):
                // RE-ENCODED RATHER THAN PASSED THROUGH, and that is what guarantees one
                // line. A reply carrying a newline would reach the client as two frames,
                // neither of them parseable.
                guard let data = try? JSONSerialization.data(withJSONObject: reply) else {
                    refused += 1
                    send(Self.errorFrame(id: id, code: -32603,
                                         message: "Grux answered something this bridge "
                                                + "could not put back on the wire."))
                    continue
                }
                answered += 1
                send(data)
            case .failure(let why):
                refused += 1
                unreachable = true
                // THE APP BEING CLOSED IS AN ANSWER, NOT A CRASH. The same id comes back, so
                // the client resolves its call and reads a designed sentence instead of
                // watching the connection die, and the loop keeps going because Grux may
                // open a second later.
                send(Self.errorFrame(id: id, code: -32603, message: frame.explain(why)))
            }
        }

        var parts: [String] = []
        if answered > 0 { parts.append("\(answered) answered by Grux") }
        if notified > 0 { parts.append("\(notified) passed on with no reply") }
        if refused > 0 { parts.append("\(refused) answered with an error from this bridge") }
        if dropped > 0 { parts.append("\(dropped) Grux never received") }
        if unreadable > 0 { parts.append("\(unreadable) unreadable") }
        let total = answered + notified + refused + dropped + unreadable

        note("")
        note("  " + r.rail(current: .prove))
        note("")
        if total == 0 {
            // The state a client in a restart loop produces, and it is not an error.
            note(r.prose("Stdin closed without a message, so nothing was forwarded."))
        } else {
            note(r.prose("Carried \(total) message\(total == 1 ? "" : "s"): "
                         + r.list(parts) + "."))
        }
        if unreachable {
            note("")
            note(r.style.ink(.dim, r.prose("Grux could not be reached for some of that. "
                + "Open Grux before the client connects again and those calls go straight "
                + "through: nothing here holds state that needs clearing.", indent: 2)))
        }

        // NOTHING GOT THROUGH is the only outcome worth an exit code. Carrying traffic is
        // the job, so a session that delivered anything ends 0 even if some of it was
        // refused. A session where every single call died against a closed app ends 1, which
        // is this CLI's code for "the app is not running" and is the fixable one.
        if answered == 0, notified == 0, refused + dropped > 0 { leave(.failed) }
        leave(.done)
    }

    // MARK: - LOOK, on stderr

    private func announce(frame: Frame, client: ControlClient) {
        let r = frame.renderer
        note("")
        note("  " + r.rail(current: .look))
        note("")
        note(r.prose("A bridge: it carries messages and answers none of them itself. Every "
                     + "line on stdin goes to Grux unread and its answer comes back on "
                     + "stdout as one line, which is why it carries any method the app has "
                     + "without being taught it."))
        note("")

        let up = client.isAvailable
        let label = up ? "Grux is running" : "Grux is not running"
        // One row, so the grid is sized from the only label present.
        note(r.row(state: up ? .satisfied : .needed, label: label,
                   detail: client.socketPath, labelWidth: label.count))
        note("")
        if !up {
            note(r.prose("Calls will come back as errors naming that until it opens, which "
                         + "is a real answer rather than a dropped connection. This keeps "
                         + "serving either way.", indent: 2))
            note("")
        }
        note(r.style.ink(.dim, r.prose("A call that has not answered in "
            + "\(Int(Self.deadline)) seconds comes back as an error instead of leaving the "
            + "client waiting. Diagnostics are here on stderr because stdout is the wire.",
            indent: 2)))
        note("")

        guard isatty(STDIN_FILENO) == 1 else { return }
        // A person typed this at a prompt. Without these two lines the command looks hung:
        // it is reading JSON-RPC from the keyboard, which is a legitimate way to poke at it
        // and is almost never what somebody meant.
        note(r.prose("Nothing is piped in, so this is reading from your keyboard. One "
                     + "message per line, Ctrl-D to end. An MCP client normally spawns this "
                     + "and speaks to it over pipes."))
        note("")
        note("    " + r.style.ink(.accent, #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#))
        note("")
    }

    // MARK: - The wire, and everything that is not the wire

    /// One frame to stdout, newline terminated, whole.
    ///
    /// STDOUT IS THE WIRE. A rail, a banner or one stray byte here is a corrupt frame and
    /// the client disconnects, which is why this one command breaks the six beat rule for
    /// stdout and prints its rail to stderr instead. Do not "fix" a diagnostic back onto
    /// stdout. `write(2)` rather than `print` for two reasons: there is no buffer to forget
    /// to flush, so a reply cannot sit in this process while the client waits on it, and a
    /// partial write is finished rather than silently truncating a frame.
    private func send(_ frame: Data) {
        var out = frame
        out.append(0x0A)
        writeAll(out, to: STDOUT_FILENO)
    }

    /// Anything a person reads. Never stdout.
    private func note(_ text: String) {
        writeAll(Data((text + "\n").utf8), to: STDERR_FILENO)
    }

    private func writeAll(_ data: Data, to fd: Int32) {
        data.withUnsafeBytes { raw in
            guard var base = raw.baseAddress else { return }
            var left = raw.count
            while left > 0 {
                let n = write(fd, base, left)
                if n > 0 {
                    base = base.advanced(by: n)
                    left -= n
                } else if errno == EINTR {
                    continue
                } else {
                    // The far end has gone. The read loop meets EOF next and leaves, and
                    // there is nowhere left to report this to.
                    return
                }
            }
        }
    }

    /// A JSON-RPC error the client can match to its own call.
    ///
    /// The id is carried back verbatim, including the null a parse error has to use when
    /// there was no id to read. Without a frame the client holds a request it will never
    /// resolve, which is the shape of a hang rather than of a failure.
    private static func errorFrame(id: Any, code: Int, message: String) -> Data {
        let object: [String: Any] = ["jsonrpc": "2.0", "id": id,
                                     "error": ["code": code, "message": message]]
        guard let data = try? JSONSerialization.data(withJSONObject: object) else {
            // Only reachable if an id arrived that JSON cannot represent, which a parsed
            // message cannot hold. A frame with no id still beats no frame at all.
            return Data((#"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"#
                         + #""message":"The reply could not be encoded."}}"#).utf8)
        }
        return data
    }
}
