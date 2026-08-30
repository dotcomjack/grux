import ArgumentParser
import Foundation
import GruxSetupCore

// MARK: - grux note

/// One note, straight in.
///
/// Written for the moment somebody is already in a terminal and does not want to leave it.
/// That is the whole design constraint, so it takes the note as arguments and prints one
/// line back rather than opening anything.
struct Note: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "note",
        abstract: "Write a note without leaving the terminal.",
        discussion: """
            Everything after the command is the note. Quote it if it contains anything your \
            shell would eat.

              grux note "ollama keeps dropping the first token"
              grux note --title "Meta Ads" "CPA doubled after the creative swap"
            """)

    @Argument(parsing: .remaining, help: "The note. Everything after the command.")
    var words: [String] = []

    @Option(name: .long, help: "A title. Optional, and the note works without one.")
    var title: String?

    @Option(name: .long, help: "Comma separated tags.")
    var tags: String?

    /// Accepted by every command, and it means one thing on all of
    /// them. See InputPolicy.
    @OptionGroup var input: InputPolicy

    func run() throws {
        let frame = Frame()
        let r = frame.renderer

        let body = words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            frame.open(.look)
            // A designed empty state rather than a usage dump: somebody who typed `grux note`
            // and nothing else knows what a note is, they just have not typed one yet.
            print(r.prose("Nothing to write. Everything after the command becomes the note."))
            print("")
            print("    " + r.style.ink(.accent, "grux note \"the thing you want to remember\""))
            leave(.failed)
        }

        let client = ControlClient()
        var arguments: [String: Any] = ["body": body]
        if let title, !title.isEmpty { arguments["title"] = title }
        if let tags {
            let list = tags.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty }
            if !list.isEmpty { arguments["tags"] = list }
        }

        switch client.call(tool: "grux_note", arguments: arguments) {
        case .failure(let why):
            frame.open(.look)
            print(r.prose(frame.explain(why)))
            leave(.failed)
        case .success(let text):
            let obj = (try? JSONSerialization.jsonObject(with: Data(text.utf8)))
                as? [String: Any]
            frame.open(.prove)
            // The note back, clipped, so somebody can see it landed as they meant it. A note
            // is short by nature, and showing it is cheaper than making them go and look.
            let room = max(20, r.style.width - 12)
            let shown = body.count > room
                ? String(body.prefix(room - 1)) + "\u{2026}" : body
            print(r.row(state: .satisfied, label: "Noted", detail: shown, labelWidth: 8))
            if let id = obj?["id"] as? String {
                print("")
                print(r.style.ink(.dim, r.prose(id, indent: 2)))
            }
            leave(.done)
        }
    }
}

// MARK: - grux use

/// Which brand the next command is about.
///
/// The brand LIST comes from `brand-attribution.json`, the file the empire dashboard already
/// reads, rather than a second list that would drift from it inside a week. The SELECTION
/// lives in the app's own defaults, so the app and this binary cannot disagree about it.
struct Use: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "use",
        abstract: "Set which brand later commands are about.",
        discussion: """
            Run with no argument to see the brands and which one is current. \
            `grux use none` clears it.
            """)

    @Argument(help: "A brand name, or `none` to clear. Omit to list them.")
    var brand: String?

    /// Accepted by every command, and it means one thing on all of
    /// them. See InputPolicy.
    @OptionGroup var input: InputPolicy

    func run() throws {
        let frame = Frame()
        let r = frame.renderer
        let client = ControlClient()

        var arguments: [String: Any] = [:]
        if let brand { arguments["use"] = brand }

        switch client.call(tool: "grux_brands", arguments: arguments) {
        case .failure(let why):
            frame.open(.look)
            print(r.prose(frame.explain(why)))
            leave(.failed)
        case .success(let text):
            guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8))
                    as? [String: Any] else {
                print(r.prose(text)); leave(.failed)
            }
            let known = (obj["brands"] as? [String] ?? [])
                .sorted { $0.lowercased() < $1.lowercased() }
            let current = (obj["current"] as? String) ?? ""

            guard brand == nil else {
                frame.open(.prove)
                if current.isEmpty {
                    print(r.row(state: .skipped, label: "No brand set", labelWidth: 0))
                    print("")
                    print(r.style.ink(.dim, r.prose("Commands that can be about a brand will "
                        + "ask, or act across all of them.", indent: 2)))
                } else {
                    print(r.row(state: .satisfied, label: "Now working on", detail: current,
                                labelWidth: 16))
                }
                leave(.done)
            }

            frame.open(.look, "Brands Grux knows about, from your brand ledger.")
            guard !known.isEmpty else {
                print(r.prose("No brands configured yet. Grux reads these from "
                              + "brand-attribution.json, which the empire dashboard writes."))
                leave(.done)
            }
            let width = known.map(\.count).max() ?? 12
            for b in known {
                let isCurrent = b == current
                print(r.row(state: isCurrent ? .satisfied : .skipped, label: b,
                            detail: isCurrent ? "current" : nil,
                            labelWidth: width, indent: 4))
            }
            print("")
            print(r.rule())
            print(r.prose(current.isEmpty
                ? "\(known.count) brands, none selected."
                : "\(known.count) brands, working on \(current)."))
            leave(.done)
        }
    }
}
