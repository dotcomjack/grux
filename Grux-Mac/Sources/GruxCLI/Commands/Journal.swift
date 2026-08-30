import ArgumentParser
import Foundation
import GruxSetupCore

// MARK: - grux journal

/// The workday log, read only, from the files the app already writes.
///
/// READ ONLY IS THE WHOLE DESIGN. This is the most personal thing Grux holds: what somebody
/// worked on, who they met, what they said they would do. A terminal command that could edit
/// it would be a way to quietly rewrite somebody's own record of their week, so there is no
/// flag here that writes, and the command works with Grux closed because it only opens files.
struct Journal: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "journal",
        abstract: "Your workday log. Reads only, and never writes.",
        discussion: """
            With no argument it lists the days Grux has recorded, newest first. Name a day \
            to read it: `grux journal 2026-08-27`.
            """)

    @Argument(help: "A day, as YYYY-MM-DD. Omit to list them.")
    var day: String?

    @Option(name: .long, help: "How many days to list. Default 14.")
    var limit: Int = 14

    @Flag(name: .long, help: "Machine readable.")
    var json = false

    struct Entry: Decodable {
        var dayKey: String
        var generatedAt: String?
        var narrativeSnippet: String?
    }

    static var dir: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Grux/workday-logs")
    }

    /// Accepted by every command, and it means one thing on all of
    /// them. See InputPolicy.
    @OptionGroup var input: InputPolicy

    func run() throws {
        let frame = Frame()
        let r = frame.renderer

        guard let indexData = try? Data(contentsOf: dirIndex()),
              let index = try? JSONDecoder().decode([Entry].self, from: indexData),
              !index.isEmpty else {
            if json { print("[]"); leave(.done) }
            frame.open(.look)
            // The expected state for anybody who has not left Grux running through a day.
            print(r.prose("No workday logs yet. Grux writes one at the end of each day it "
                          + "has been running for, so the first appears tomorrow."))
            leave(.done)
        }

        let sorted = index.sorted { $0.dayKey > $1.dayKey }

        if let day {
            try readOne(day, frame: frame, known: sorted.map(\.dayKey))
            return
        }

        if json {
            if let d = try? JSONEncoder().encode(sorted.prefix(max(1, limit)).map { $0.dayKey }),
               let t = String(data: d, encoding: .utf8) { print(t) }
            leave(.done)
        }

        frame.open(.look)
        let shown = sorted.prefix(max(1, limit))
        for e in shown {
            let snippet = e.narrativeSnippet ?? ""
            // Clipped to the width. A narrative is a paragraph, and this is an index.
            let room = max(20, r.style.width - 16)
            let line = snippet.count > room
                ? String(snippet.prefix(room - 1)).trimmingCharacters(in: .whitespaces)
                    + "\u{2026}"
                : snippet
            print("  " + r.style.ink(.ok, "+") + " "
                  + r.style.ink(.accent, pretty(e.dayKey)) + "  "
                  + (line.isEmpty ? r.style.ink(.dim, "no narrative") : line))
        }
        print("")
        print(r.prose("\(index.count) day\(index.count == 1 ? "" : "s") recorded, "
                      + "showing \(shown.count)."))
        print("")
        print(r.style.ink(.dim, r.prose("grux journal \(sorted[0].dayKey) to read one.",
                                        indent: 2)))
        leave(.done)
    }

    private func dirIndex() -> URL { Self.dir.appendingPathComponent("index.json") }

    /// One day, in the order somebody reads it: the sentence, then where the time went, then
    /// what was promised.
    private func readOne(_ key: String, frame: Frame, known: [String]) throws {
        let r = frame.renderer
        let url = Self.dir.appendingPathComponent("\(key).json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            frame.open(.look)
            print(r.prose("No log for \(key)."))
            let near = known.filter { $0.hasPrefix(String(key.prefix(7))) }.prefix(3)
            if !near.isEmpty {
                print("")
                print(r.style.ink(.dim, r.prose("That month has "
                    + r.list(Array(near)) + ".", indent: 2)))
            }
            leave(.failed)
        }

        if json { print(String(decoding: data, as: UTF8.self)); leave(.done) }

        frame.open(.look)
        if let summary = obj["executiveSummary"] as? String, !summary.isEmpty {
            print(r.prose(summary))
        }
        if let narrative = obj["narrative"] as? String, !narrative.isEmpty,
           narrative != obj["executiveSummary"] as? String {
            print("")
            print(r.style.ink(.dim, r.prose(narrative, indent: 2)))
        }

        if let time = obj["timeAllocation"] as? [String: Any] {
            let rows = time.compactMap { k, v -> (String, Int)? in
                guard let m = (v as? NSNumber)?.intValue, m > 0 else { return nil }
                return (label(k), m)
            }.sorted { $0.1 > $1.1 }
            if !rows.isEmpty {
                print("")
                print("  " + r.heading("WHERE THE TIME WENT"))
                let width = rows.map(\.0.count).max() ?? 10
                for (name, minutes) in rows {
                    print("    " + r.style.ink(.ok, "+") + " "
                          + name.padding(toLength: width, withPad: " ", startingAt: 0)
                          + "  " + r.style.ink(.dim, duration(minutes)))
                }
            }
        }

        if let commitments = obj["commitments"] as? [String: Any] {
            let open = (commitments["stillOpen"] as? [Any])?.count ?? 0
            let kept = (commitments["kept"] as? [Any])?.count ?? 0
            let made = (commitments["made"] as? [Any])?.count ?? 0
            if open + kept + made > 0 {
                print("")
                print("  " + r.heading("WHAT YOU SAID YOU WOULD DO"))
                print(r.prose("\(made) made, \(kept) kept, \(open) still open.", indent: 4))
            }
        }

        if let meetings = obj["meetingsAttended"] as? [[String: Any]], !meetings.isEmpty {
            print("")
            print("  " + r.heading("MEETINGS"))
            for m in meetings.prefix(8) {
                let title = (m["eventTitle"] as? String) ?? "untitled"
                print("    " + r.style.ink(.ok, "+") + " " + title)
            }
            if meetings.count > 8 {
                print("    " + r.style.ink(.dim, "and \(meetings.count - 8) more"))
            }
        }
        leave(.done)
    }

    /// `codingMinutes` is a key. "Coding" is a word.
    private func label(_ key: String) -> String {
        let stripped = key.replacingOccurrences(of: "Minutes", with: "")
        return stripped.prefix(1).uppercased() + stripped.dropFirst()
    }

    /// Minutes are a unit a machine likes. "2h 15m" is what somebody reads.
    private func duration(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m"
    }

    private func pretty(_ dayKey: String) -> String {
        let inFmt = DateFormatter(); inFmt.dateFormat = "yyyy-MM-dd"
        guard let d = inFmt.date(from: dayKey) else { return dayKey }
        let out = DateFormatter(); out.dateFormat = "d MMM"
        return out.string(from: d).padding(toLength: 6, withPad: " ", startingAt: 0)
    }
}
