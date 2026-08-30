import ArgumentParser
import Foundation
import GruxSetupCore

// MARK: - grux logs

/// Grux's own log, tailed or dumped.
///
/// There are several, and which one somebody wants depends on what they are chasing, so this
/// names them rather than picking one and hiding the rest. The default is the app log,
/// because "what is Grux doing" is the question somebody has when they run this at all.
///
/// It reads files and never the socket, so it works when the app has crashed, which is
/// exactly when a log is worth having.
struct Logs: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "logs",
        abstract: "Grux's own log. Reads files, so it works when Grux is not running.")

    /// Named, so somebody can ask for the one they want without knowing a path.
    struct Source {
        let key: String
        let file: String
        let what: String
    }

    static let sources: [Source] = [
        Source(key: "app", file: "wake.log",
               what: "what Grux itself is doing, moment to moment"),
        Source(key: "security", file: "security-audit.log",
               what: "every permission check and its verdict"),
        Source(key: "files", file: "fs-audit.log",
               what: "every file Grux touched. grux history reads this one too"),
    ]

    @Argument(help: "Which log: app, security or files. Default app.")
    var which: String?

    @Option(name: .long, help: "How many lines. Default 40.")
    var limit: Int = 40

    @Flag(name: .long, help: "Keep printing as it grows. Ctrl-C to stop.")
    var follow = false

    static var dir: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Grux")
    }

    /// Accepted by every command, and it means one thing on all of
    /// them. See InputPolicy.
    @OptionGroup var input: InputPolicy

    func run() throws {
        let frame = Frame()
        let r = frame.renderer

        let wanted = which ?? "app"
        guard let source = Self.sources.first(where: { $0.key == wanted }) else {
            frame.open(.look)
            print(r.prose("No log called \(wanted)."))
            print("")
            let width = Self.sources.map(\.key.count).max() ?? 8
            for s in Self.sources {
                print("    " + r.style.ink(.accent,
                        s.key.padding(toLength: width, withPad: " ", startingAt: 0))
                      + "  " + r.style.ink(.dim, s.what))
            }
            leave(.failed)
        }

        let url = Self.dir.appendingPathComponent(source.file)
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            frame.open(.look)
            // NOT AN ERROR. A log Grux has never had reason to write is an absent file, and
            // on a fresh install that is every one of them.
            print(r.prose("Nothing in the \(source.key) log yet. Grux writes it when there "
                          + "is something to write, so an empty one is the normal state on a "
                          + "Mac that has just been set up."))
            leave(.done)
        }
        defer { try? handle.close() }

        if !follow {
            frame.open(.look, source.what + ".")
        }

        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init).filter { !$0.isEmpty }
        for line in lines.suffix(max(1, limit)) { print(render(line, r)) }

        guard follow else {
            print("")
            print(r.rule())
            print(r.prose("\(lines.count) line\(lines.count == 1 ? "" : "s") in "
                          + "\(source.file). Showing \(min(lines.count, max(1, limit)))."))
            leave(.done)
        }

        // FOLLOW. Seek to the end and poll, rather than re-reading the file: wake.log is
        // over twenty thousand lines here, and re-reading it every second to find the tail
        // would burn a core to print nothing.
        var offset = (try? handle.seekToEnd()) ?? 0
        var carry = ""
        while true {
            try? handle.seek(toOffset: offset)
            let chunk = handle.readDataToEndOfFile()
            if !chunk.isEmpty {
                offset += UInt64(chunk.count)
                carry += String(decoding: chunk, as: UTF8.self)
                // Hold an incomplete last line rather than printing half of it. A writer
                // appending is not atomic, so a read can land mid-line.
                while let nl = carry.firstIndex(of: "\n") {
                    let line = String(carry[carry.startIndex..<nl])
                    carry = String(carry[carry.index(after: nl)...])
                    if !line.isEmpty { print(render(line, r)) }
                }
            }
            Thread.sleep(forTimeInterval: 0.4)
        }
    }

    /// An NDJSON line is a record, not a sentence. The audit logs write JSON and the app log
    /// writes text, and printing raw JSON at somebody reading a log is making them do the
    /// parsing.
    private func render(_ line: String, _ r: Renderer) -> String {
        guard line.hasPrefix("{"),
              let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8))
                as? [String: Any] else {
            return "  " + clip(line, r)
        }
        let verdict = (obj["verdict"] as? String) ?? (obj["outcome"] as? String) ?? ""
        let ok = verdict == "ok"
        let what = (obj["kind"] as? String) ?? (obj["tool"] as? String) ?? ""
        let detail = (obj["detail"] as? String) ?? (obj["path"] as? String) ?? ""
        let glyph = verdict.isEmpty ? "." : (ok ? "+" : "!")
        return "  " + r.style.ink(verdict.isEmpty ? .dim : (ok ? .ok : .attention), glyph)
            + " " + what
            + (detail.isEmpty ? "" : "  " + r.style.ink(.dim, clip(detail, r, used: 6 + what.count)))
    }

    /// CLIPPED ON A TERMINAL, NEVER IN A PIPE, and the asymmetry is deliberate.
    ///
    /// Everywhere else in this CLI one width governs the whole screen. A log line is the
    /// exception, because it is DATA rather than prose: somebody runs `grux logs | grep` and
    /// a truncated line silently loses the match. The app log here has single lines over 250
    /// characters carrying a whole API error in them.
    ///
    /// So a person reading a terminal gets a screen that lines up, and a pipe gets the bytes
    /// intact. Those are different readers wanting opposite things, and picking one for both
    /// would be wrong for somebody either way.
    private func clip(_ text: String, _ r: Renderer, used: Int = 2) -> String {
        guard r.style.isTTY else { return text }
        let room = max(20, r.style.width - used)
        guard text.count > room else { return text }
        return String(text.prefix(room - 1)) + "\u{2026}"
    }
}
