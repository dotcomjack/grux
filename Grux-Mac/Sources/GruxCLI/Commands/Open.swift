import ArgumentParser
import Foundation
import GruxSetupCore

// MARK: - grux open

/// The one command here that is worthless unless somebody is sitting at this Mac.
///
/// Every other command answers a question, and an answer is worth the same whether a person
/// or an agent reads it. This moves a WINDOW. A window nobody is in front of has not been
/// opened in any sense that matters, so the command says so rather than leaving an agent to
/// discover it by calling this in a loop from somewhere else.
///
/// It also never claims the window arrived. `AppDelegate.openLaunchWindow` orders the window
/// front and calls `NSApp.activate`, and the measurement recorded beside that code is that
/// neither is enough from a background app: the window is created and never becomes visible.
/// This process cannot see a screen, so "asked" is the strongest true word available.
struct Open: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "open",
        abstract: "Bring a Grux window forward.",
        discussion: """
            With no surface it names every one there is, grouped the way the window's own \
            sidebar groups them.

              grux open
              grux open mailbox
              grux open "Local Models"

            Needs Grux to already be running, because there is no window to bring forward \
            otherwise, and needs somebody at this Mac, because moving a window nobody can \
            see achieves nothing.
            """)

    @Argument(help: "Which surface. Omit to see them all.")
    var surface: String?

    /// Accepted by every command, and it means one thing on all of
    /// them. See InputPolicy.
    @OptionGroup var input: InputPolicy

    func run() throws {
        let frame = Frame()
        let r = frame.renderer
        let client = ControlClient()
        let typed = (surface ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        var arguments: [String: Any] = [:]
        if !typed.isEmpty { arguments["surface"] = typed }

        switch client.call(tool: "grux_open", arguments: arguments) {
        case .failure(let why):
            frame.open(.look)
            // A REFUSAL FOR A NAME THAT DOES NOT EXIST can be answered here and the app's
            // one sentence cannot, so this takes the headline over. The names live in the
            // app, which is the whole reason this binary carries no copy of them, so a
            // second call fetches them and the reader gets the nearest match and the real
            // list instead of being told to go and run something else, immediately above
            // the list they were told to go and run.
            //
            // The catalogue is what decides, not the wording of the refusal. Grux can refuse
            // for other reasons, and a screen headed "no surface called mailbox" over a list
            // containing mailbox would be the exact failure this command exists to fix.
            if case .toolFailed = why, !typed.isEmpty,
               let catalogue = Catalogue.fetch(client), !catalogue.knows(typed) {
                print(r.prose("Grux has no surface called \(typed), so nothing was opened."))
                suggest(typed, in: catalogue, r)
                print("")
                render(catalogue, r)
                leave(.failed)
            }
            print(r.prose(frame.explain(why)))
            sayGruxIsClosed(why, listing: typed.isEmpty, r)
            leave(.failed)

        case .success(let text):
            guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8)))
                    as? [String: Any] else {
                frame.open(.prove)
                print(r.prose(text))
                leave(.failed)
            }
            guard !typed.isEmpty else {
                guard let catalogue = Catalogue(object) else {
                    frame.open(.prove)
                    print(r.prose(text))
                    leave(.failed)
                }
                frame.open(.look, "Every surface this Grux has, grouped and ordered the way "
                    + "the window's own sidebar does.")
                render(catalogue, r)
                leave(.done)
            }
            report(object, typed: typed, frame: frame)
            leave(.done)
        }
    }

    // MARK: - What the app sent

    /// The surfaces, as the app describes them.
    ///
    /// PARSED, NEVER DECLARED. The names, the grouping, the order and the aliases all arrive
    /// over the socket, because `LaunchRootView.Tab` inside the app is the only thing
    /// entitled to say what a surface is called. A list written here instead would be a
    /// second thing to keep in step with it, and this repo's own documentation has already
    /// drifted from that enum once, by a whole tab.
    struct Catalogue {
        struct Surface { let key: String; let label: String }
        struct Group { let title: String; let surfaces: [Surface] }

        let groups: [Group]
        /// The surface Grux lands on when it opens on its own. Empty if the app did not say.
        let landsOn: String
        let aliases: [String: String]

        var keys: [String] { groups.flatMap { $0.surfaces.map(\.key) } }
        var labels: [String] { groups.flatMap { $0.surfaces.map(\.label) } }

        /// Whether a typed name is one of these, by key, by sidebar label or by alias.
        ///
        /// Deliberately generous and deliberately NOT authoritative. The app decides what
        /// opens; this only decides which of two refusal screens to draw, and being generous
        /// means a name Grux would have accepted never gets a "no such surface" headline.
        func knows(_ typed: String) -> Bool {
            let lowered = typed.lowercased()
            return keys.contains { $0.lowercased() == lowered }
                || labels.contains { $0.lowercased() == lowered }
                || aliases.keys.contains { $0.lowercased() == lowered }
        }

        init?(_ object: [String: Any]) {
            guard let raw = object["groups"] as? [[String: Any]] else { return nil }
            groups = raw.compactMap { group -> Group? in
                guard let title = group["title"] as? String,
                      let items = group["surfaces"] as? [[String: Any]] else { return nil }
                let surfaces = items.compactMap { item -> Surface? in
                    guard let key = item["key"] as? String,
                          let label = item["label"] as? String else { return nil }
                    return Surface(key: key, label: label)
                }
                return surfaces.isEmpty ? nil : Group(title: title, surfaces: surfaces)
            }
            guard !groups.isEmpty else { return nil }
            landsOn = (object["default"] as? String) ?? ""
            aliases = (object["aliases"] as? [String: String]) ?? [:]
        }

        static func fetch(_ client: ControlClient) -> Catalogue? {
            guard case .success(let text) = client.call(tool: "grux_open"),
                  let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8)))
                    as? [String: Any] else { return nil }
            return Catalogue(object)
        }
    }

    // MARK: - Screens

    private func render(_ catalogue: Catalogue, _ r: Renderer) {
        // Sized from the WIDEST KEY PRESENT, never a fixed guess: terminalFocus is thirteen
        // characters and home is four, so a guessed gutter either wraps the long ones or
        // pushes the short ones halfway across the terminal.
        let width = catalogue.keys.map(\.count).max() ?? 4
        // The key is the loud column here and the label is the dim one, which is the reverse
        // of a capability row elsewhere in this binary. It is the right way round for this
        // command: the key is the thing you type, and nobody would guess `cookbook` from a
        // window whose sidebar says "Local Models".
        let showsLabel = !r.style.isNarrow

        for group in catalogue.groups {
            print("  " + r.heading(group.title.uppercased()))
            for surface in group.surfaces {
                // PAD ONLY WHEN SOMETHING FOLLOWS, or every row on a narrow terminal ends in
                // nine spaces and a newline.
                var line = "    " + surface.key
                if showsLabel {
                    let padded = surface.key.padding(toLength: width, withPad: " ",
                                                     startingAt: 0)
                    line = "    " + padded + "  " + r.style.ink(.dim, surface.label)
                }
                if surface.key == catalogue.landsOn {
                    line += r.style.ink(.dim, "   opens by default")
                }
                print(line)
            }
            print("")
        }

        // Counted from the rows actually printed above, not from a number the app sent, so
        // the total cannot disagree with the list it sits under.
        let count = catalogue.keys.count
        print(r.rule())
        print(r.prose("\(count) surfaces in \(catalogue.groups.count) groups. "
            + (catalogue.landsOn.isEmpty
                ? "Naming one brings that window forward."
                : "Grux lands on \(catalogue.landsOn) when it opens on its own.")))

        if !catalogue.aliases.isEmpty {
            let pairs = catalogue.aliases
                .sorted { $0.key.lowercased() < $1.key.lowercased() }
                .map { "\($0.key) for \($0.value)" }
            print("")
            print(r.style.ink(.dim, r.prose(r.list(pairs) + " work too.", indent: 2)))
        }

        // The example is drawn from the list rather than typed in, so it cannot outlive the
        // surface it names.
        let example = catalogue.keys.contains("mailbox")
            ? "mailbox" : (catalogue.keys.first ?? "chat")
        print("")
        print(r.style.ink(.dim, r.prose("grux open \(example) brings that window forward, "
            + "for whoever is at this Mac to see it.", indent: 2)))
    }

    /// What Grux was asked to do, in the strongest words that are true.
    private func report(_ object: [String: Any], typed: String, frame: Frame) {
        let r = frame.renderer
        let key = (object["surface"] as? String) ?? typed
        let label = (object["label"] as? String) ?? key

        frame.open(.prove)
        // No glyph. Every state this command has is the same state, so a `+` would mean
        // nothing except "a line was printed", and the one it most resembles reads "ready",
        // which is a stronger claim than anything below supports. The accent marks where you
        // are, which is exactly what this row is for.
        print("  " + r.style.ink(.accent, label) + "  " + r.style.ink(.dim, key))
        print("")
        print(r.prose("Grux has been asked to bring that window forward. It is only worth "
            + "anything with somebody at this Mac to look at the result, and this command "
            + "cannot see your screen, so the ask is all it can report."))
        print("")
        print(r.style.ink(.dim, r.prose("Give it a moment. A surface that has not been "
            + "opened before is built the first time you ask for it, and Grux lives in the "
            + "menu bar, so it cannot always put itself in front of whatever you are "
            + "looking at. If no window arrives, click the Grux icon up there.", indent: 2)))

        // SAY WHAT IT RESOLVED TO. Accepting `design` and then reporting `designStudio` as
        // though that is what was typed teaches the reader nothing and quietly hides the
        // fact that two names reach the same window.
        if key.caseInsensitiveCompare(typed) != .orderedSame {
            print("")
            print(r.style.ink(.dim, r.prose("You typed \(typed). \(key) is the name Grux "
                + "knows it by.", indent: 2)))
        }
    }

    /// The nearest real names to something that is not one.
    ///
    /// `Lookup.edits` rather than a second Levenshtein: it is already in this target for
    /// `grux which`, and the cutoff is the same length-scaled one `Lookup.nearest` uses, so a
    /// four letter typo does not answer with three unrelated surfaces.
    private func suggest(_ typed: String, in catalogue: Catalogue, _ r: Renderer) {
        let lowered = typed.lowercased()
        let cutoff = max(2, lowered.count / 3)
        let near = catalogue.keys
            .map { (key: $0, distance: Lookup.edits(lowered, $0.lowercased())) }
            .filter { $0.distance <= cutoff }
            // Case insensitively on the tie break. A plain `<` on a String is an ASCII sort,
            // which files every lowercase key after every capital one.
            .sorted { ($0.distance, $0.key.lowercased()) < ($1.distance, $1.key.lowercased()) }
            .prefix(3).map { $0.key }
        guard !near.isEmpty else { return }

        print("")
        print(r.prose(near.count == 1
            ? "Did you mean \(near[0])?"
            : "The nearest names are " + r.list(near) + "."))
    }

    /// The failure that is special to this command, and it is special in both directions.
    ///
    /// `frame.explain` already says Grux is not running and to open it, which is enough for
    /// every other command, because every other command reads files and would have worked
    /// with the app closed. This one had nothing to do either way: a closed app has no window
    /// to bring forward, and it does not even hold the list of surfaces where this binary can
    /// reach it.
    private func sayGruxIsClosed(_ why: ControlClient.Failure, listing: Bool, _ r: Renderer) {
        let closed: Bool
        switch why {
        case .notRunning:
            closed = true
        case .couldNotConnect(_, let code):
            // NOT every connect failure. EACCES is the socket belonging to another user
            // account, which explain() already answers correctly and which would be made
            // worse by telling somebody to launch a second copy.
            closed = (code == ECONNREFUSED || code == ENOENT)
        default:
            closed = false
        }
        guard closed else { return }

        print("")
        print(r.prose(listing
            ? "The surfaces live inside Grux, so with the app closed this cannot name them, "
              + "let alone bring one forward."
            : "There is no window to bring forward while Grux is closed, and this command "
              + "will not start the app behind your back.", indent: 2))
        print("")
        print(r.style.ink(.dim, r.prose("open -b com.gruxai.grux", indent: 4)))
    }
}
