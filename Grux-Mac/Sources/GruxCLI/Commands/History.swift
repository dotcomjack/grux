import ArgumentParser
import Foundation
import GruxSetupCore

// MARK: - grux history

/// What Grux has actually done to files on this Mac, newest first.
///
/// The audit log exists because the shell tool can write, and a thing that can write to
/// somebody's folders has to be able to show them what it wrote. This is the read side of
/// that promise, and it deliberately shows BLOCKED attempts as prominently as successful
/// ones: what an agent tried to do and was stopped from doing is the more interesting half.
struct History: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "history",
        abstract: "What Grux has changed on this Mac, newest first.")

    @Option(name: .long, help: "How many to show. Default 20.")
    var limit: Int = 20

    @Flag(name: .long, help: "Only the things that were refused.")
    var blocked = false

    @Flag(name: .long, help: "Machine readable.")
    var json = false

    struct Entry: Decodable {
        var ts: String
        var tool: String
        var path: String
        var outcome: String
        var reason: String?
        var bytes: Int?
    }

    static var auditURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Grux/fs-audit.log")
    }

    /// Accepted by every command, and it means one thing on all of
    /// them. See InputPolicy.
    @OptionGroup var input: InputPolicy

    func run() throws {
        let frame = Frame()
        let r = frame.renderer

        guard let text = try? String(contentsOf: Self.auditURL, encoding: .utf8) else {
            if json { print("[]"); leave(.done) }
            frame.open(.look)
            // The expected state for most people. Grux only writes this when something it
            // runs touches a file, so an empty history means it has not, not that it failed.
            print(r.prose("Grux has not changed anything on this Mac. It writes this log "
                          + "whenever something it runs touches a file."))
            leave(.done)
        }

        let decoder = JSONDecoder()
        // A LINE THAT WILL NOT PARSE IS SKIPPED, NOT FATAL. The log is append-only and a
        // process killed mid-write leaves a torn last line. Refusing to show ten months of
        // history over one truncated record would be the wrong trade.
        var all = text.split(separator: "\n").compactMap {
            try? decoder.decode(Entry.self, from: Data($0.utf8))
        }
        let torn = text.split(separator: "\n").count - all.count
        all.reverse()

        let shown = (blocked ? all.filter { $0.outcome != "ok" } : all).prefix(max(1, limit))

        if json {
            let out = shown.map { ["ts": $0.ts, "tool": $0.tool, "path": $0.path,
                                   "outcome": $0.outcome, "reason": $0.reason ?? ""] }
            if let d = try? JSONSerialization.data(withJSONObject: Array(out),
                                                   options: [.prettyPrinted, .sortedKeys]),
               let t = String(data: d, encoding: .utf8) { print(t) }
            leave(.done)
        }

        frame.open(.look, blocked ? "Things Grux tried to do and was stopped from doing."
                                  : "Everything Grux has done to a file on this Mac.")

        guard !shown.isEmpty else {
            print(r.prose(blocked ? "Nothing has ever been refused."
                                  : "Nothing recorded yet."))
            leave(.done)
        }

        for e in shown {
            let ok = e.outcome == "ok"
            // Clipped to the width. A path here is often a whole shell command, and one of
            // the real ones on this machine is 90 characters of `mkdir -p ... && cat > ...`.
            let stamp = shortTime(e.ts)
            let room = max(16, r.style.width - stamp.count - e.tool.count - 10)
            let what = e.path.count > room
                ? String(e.path.prefix(room - 1)) + "\u{2026}" : e.path
            print("  " + r.style.ink(ok ? .ok : .attention, ok ? "+" : "!")
                  + " " + r.style.ink(.dim, stamp)
                  + "  " + what)
            // THE CONTINUATION LINE NEEDS CLIPPING TOO. The path above it was clipped and
            // this one was not, so at 60 columns the reason ran four characters past the
            // edge. A refusal reason is free text written by whatever refused, so it has no
            // length anybody controls.
            let detail = e.tool + (ok ? "" : "  " + (e.reason ?? "refused"))
            let detailRoom = max(12, r.style.width - 6)
            print("      " + r.style.ink(.dim, detail.count > detailRoom
                ? String(detail.prefix(detailRoom - 1)) + "\u{2026}"
                : detail))
        }

        print("")
        let refused = all.filter { $0.outcome != "ok" }.count
        print(r.rule())
        print(r.prose("\(all.count) recorded, \(all.count - refused) done and \(refused) "
                      + "refused. Showing \(shown.count)."))
        if torn > 0 {
            print(r.style.ink(.dim, r.prose(
                "\(torn) line\(torn == 1 ? "" : "s") could not be read, which is what a "
                + "process killed mid-write leaves behind.", indent: 2)))
        }
        if !blocked && refused > 0 {
            print("")
            print(r.style.ink(.dim, r.prose("grux history --blocked for just the refusals.",
                                            indent: 2)))
        }
        leave(.done)
    }

    /// Plain LOCAL time, because an ISO timestamp is for a machine and this column is for a
    /// person.
    ///
    /// FRACTIONAL SECONDS. The audit log writes `2026-08-28T19:33:09.596Z`, and
    /// `ISO8601DateFormatter` does not parse that without being asked to, so every row fell
    /// through to the raw string. Which meant the column showed UTC: `19:33` on a Mac where
    /// the clock said 15:33. Nobody would have read that as a bug, they would have read it
    /// as Grux having done something four hours in the future.
    private static let isoParsers: [ISO8601DateFormatter] = {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return [withFraction, ISO8601DateFormatter()]
    }()

    private func shortTime(_ iso: String) -> String {
        guard let d = Self.isoParsers.lazy.compactMap({ $0.date(from: iso) }).first else {
            return iso
        }
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(d) ? "h:mm a" : "d MMM h:mm a"
        f.amSymbol = "AM"; f.pmSymbol = "PM"
        return f.string(from: d)
    }
}
