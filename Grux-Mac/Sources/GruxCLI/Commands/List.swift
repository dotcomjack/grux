import ArgumentParser
import Foundation
import GruxSetupCore

// MARK: - grux list

/// EVERY feature, chosen or not.
///
/// This is what makes an off switch honest. `CLAUDE.md` locks that nothing ships off and
/// undiscoverable, and the hardest of its three conditions is the permanent home: first run
/// happens once, and a person who declined something in month one has to be able to find it
/// in month six. Listing only what is on would fail that by construction.
struct List: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "The inventory: features, capabilities, brands or projects.",
        discussion: """
            With no noun it lists features, which is what it has always done.

              grux list                 every feature, chosen or not
              grux list capabilities    every id Grux can use, and its state
              grux list brands          the brand ledger, and which one is current
              grux list projects        the code roots Grux is tracking

            features, capabilities and projects are read from files, so they answer with \
            Grux closed. brands lives inside the app and needs it running, and this says so \
            rather than reporting an empty ledger.
            """)

    /// The nouns, in one place, so the refusal and the help cannot disagree.
    ///
    /// The doc's surface table has listed all four since before any of them worked, and
    /// `CommandSurfaceTests` compares COMMAND NAMES only, so `grux list capabilities` exited
    /// 64 with "Unexpected argument" while the file said it was shipped. A test that reads
    /// the name and not the arguments cannot see that, which is why this was found by
    /// running the binary rather than by the suite.
    static let nouns = ["features", "capabilities", "brands", "projects"]

    @Argument(help: "features, capabilities, brands or projects. Default features.")
    var noun: String?

    @Flag(name: .long, help: "Only the ones that are on.")
    var on = false

    @Flag(name: .long, help: "Only the ones that are off.")
    var off = false

    @Flag(name: .long, help: "Emit ids and states as JSON. For an agent.")
    var json = false

    /// Accepted by every command, and it means one thing on all of
    /// them. See InputPolicy.
    @OptionGroup var input: InputPolicy

    func run() throws {
        let frame = Frame()
        let r = frame.renderer

        let which = (noun ?? "features").lowercased()
        guard Self.nouns.contains(which) else {
            frame.open(.look)
            print(r.prose("No inventory called \(which)."))
            print("")
            // Edit distance rather than a bare refusal, like every other miss in this
            // binary. "capabilites" neither contains nor is contained by "capabilities".
            let near = Self.nouns
                .map { ($0, Lookup.edits(which, $0)) }
                .filter { $0.1 <= max(2, which.count / 3) }
                .sorted { ($0.1, $0.0) < ($1.1, $1.0) }
                .map(\.0)
            if !near.isEmpty { print(r.prose("Did you mean " + r.list(near) + "?", indent: 2)) }
            else { print(r.prose(r.list(Self.nouns) + ".", indent: 2)) }
            leave(.failed)
        }

        // brands is the one noun that lives in the app rather than in a file, so it takes
        // its own path and answers honestly when Grux is closed.
        if which == "brands" { listBrands(frame) }

        let status: SetupStatus
        switch SetupStatusReader.read() {
        case .success(let s): status = s
        case .failure(let e): leave(frame.explain(e))
        }

        if which == "capabilities" { listCapabilities(status, frame) }
        if which == "projects" { listProjects(frame) }

        var rows = status.features
        if on { rows = rows.filter(\.chosen) }
        if off { rows = rows.filter { !$0.chosen } }

        if json {
            let payload = rows.map { ["id": $0.id, "label": $0.label, "tier": $0.tier,
                                      "state": $0.state, "chosen": $0.chosen] as [String: Any] }
            if let d = try? JSONSerialization.data(withJSONObject: payload,
                                                  options: [.prettyPrinted, .sortedKeys]),
               let t = String(data: d, encoding: .utf8) { print(t) }
            leave(.done)
        }

        frame.open(.look)
        print(r.legend([.satisfied, .needed, .skipped]))
        print("")
        // Case insensitive, for the same reason every other list here is.
        for f in rows.sorted(by: { $0.label.lowercased() < $1.label.lowercased() }) {
            let state: RowState = !f.chosen ? .skipped
                : (f.state == "needsSetup" ? .needed : .satisfied)
            let badge = f.tier == "labs" ? " BETA" : ""
            print(r.row(state: state, label: f.label + badge, detail: f.id, labelWidth: 26))
        }
        print("")
        let onCount = status.features.filter(\.chosen).count
        print(r.style.ink(.dim, r.prose(
            "\(onCount) of \(status.features.count) features are on. "
            + "Turn one on with grux enable <id>, off with grux disable <id>.")))
        leave(.done)
    }

    // MARK: - The other three nouns

    /// Every capability id and the state it is in for THIS selection.
    ///
    /// The same five states `grux status` uses, through the same `Lookup.state`, because the
    /// product rule is that a word means one thing on every surface. "skipped" here is the
    /// interesting one: nothing you chose uses it, so Grux will never ask.
    private func listCapabilities(_ status: SetupStatus, _ frame: Frame) -> Never {
        let r = frame.renderer
        var caps = status.capabilities
        if on { caps = caps.filter(\.satisfied) }
        if off { caps = caps.filter { !$0.satisfied } }

        if json {
            let payload = caps.map { ["id": $0.id, "label": $0.label, "kind": $0.kind,
                                      "satisfied": $0.satisfied,
                                      "selfAttested": $0.selfAttested,
                                      "state": Lookup.state(of: $0, in: status).word]
                                     as [String: Any] }
            if let d = try? JSONSerialization.data(withJSONObject: payload,
                                                   options: [.prettyPrinted, .sortedKeys]),
               let t = String(data: d, encoding: .utf8) { print(t) }
            leave(.done)
        }

        frame.open(.look)
        print(r.legend([.satisfied, .needed, .optional, .skipped, .attested]))
        print("")
        let width = caps.map { $0.label.count }.max() ?? 20
        for c in caps.sorted(by: { $0.label.lowercased() < $1.label.lowercased() }) {
            print(r.row(state: Lookup.state(of: c, in: status), label: c.label,
                        detail: c.id, labelWidth: min(width, 30)))
        }
        print("")
        // EVERY ROW ACCOUNTED FOR. Counting only the satisfied ones would leave a reader
        // holding a total they cannot reach from the summary.
        let ready = caps.filter(\.satisfied).count
        let never = caps.filter { Lookup.state(of: $0, in: status) == .skipped }.count
        print(r.style.ink(.dim, r.prose(
            "\(caps.count) of \(status.capabilities.count) shown. \(ready) already set up, "
            + "\(never) that nothing you chose uses, "
            + "\(caps.count - ready - never) still wanted. "
            + "grux why <id> says who wants one.")))
        leave(.done)
    }

    /// The code roots Grux is tracking.
    ///
    /// Read straight from `~/.grux/projects.json`, which the app deliberately keeps beside
    /// wake.log and the fire triggers rather than inside Application Support, precisely so a
    /// shell can read it. So this answers with Grux closed like every other read here.
    private func listProjects(_ frame: Frame) -> Never {
        let r = frame.renderer
        struct Entry: Decodable {
            let name: String
            let root: String
            var displayName: String?
            var bundleId: String?
            var createdByGrux: Bool?
        }
        struct Doc: Decodable { let entries: [Entry] }

        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".grux/projects.json")
        let doc = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Doc.self, from: $0) }

        // NEVER WRITTEN and EMPTY are different answers with different next actions, and
        // collapsing them would tell somebody who has added projects that they have none.
        guard let doc else {
            frame.open(.look)
            print(r.prose("Grux has not written a project registry yet, which means no "
                + "project has been added on this Mac."))
            print("")
            print("    " + r.style.ink(.accent, "grux add project ~/src/thing"))
            leave(.done)
        }
        if json {
            let payload = doc.entries.map { ["name": $0.name, "root": $0.root,
                                             "displayName": $0.displayName ?? $0.name,
                                             "createdByGrux": $0.createdByGrux ?? false]
                                            as [String: Any] }
            if let d = try? JSONSerialization.data(withJSONObject: payload,
                                                   options: [.prettyPrinted, .sortedKeys]),
               let t = String(data: d, encoding: .utf8) { print(t) }
            leave(.done)
        }

        frame.open(.look, "Read from ~/.grux/projects.json, so this answers with Grux closed.")
        guard !doc.entries.isEmpty else {
            print(r.row(state: .skipped, label: "No projects yet", labelWidth: 0))
            print("")
            print("    " + r.style.ink(.accent, "grux add project ~/src/thing"))
            leave(.done)
        }
        let fm = FileManager.default
        let sorted = doc.entries.sorted { $0.name.lowercased() < $1.name.lowercased() }
        let width = sorted.map { ($0.displayName ?? $0.name).count }.max() ?? 12
        var missing = 0
        for e in sorted {
            // THE GLYPH DESCRIBES THE ROW'S SUBJECT. A registered project whose folder has
            // been moved or deleted is still registered, and saying "ready" about a path
            // that is not there would be false for exactly the case worth surfacing.
            let there = fm.fileExists(atPath: (e.root as NSString).expandingTildeInPath)
            if !there { missing += 1 }
            print(r.row(state: there ? .satisfied : .needed,
                        label: e.displayName ?? e.name, detail: e.root,
                        labelWidth: width, indent: 4))
        }
        print("")
        print(r.style.ink(.dim, r.prose(missing == 0
            ? "\(sorted.count) project\(sorted.count == 1 ? "" : "s"), every folder present."
            : "\(sorted.count) project\(sorted.count == 1 ? "" : "s"), \(missing) whose "
            + "folder is not there any more. grux remove project <name> stops tracking one "
            + "without touching any files.")))
        leave(.done)
    }

    /// The brand ledger, through the app, because that is where it is read from.
    ///
    /// `grux use` already goes through `grux_brands`, and a second reader here would be a
    /// second thing to keep in step with `brand-attribution.json`.
    private func listBrands(_ frame: Frame) -> Never {
        let r = frame.renderer
        switch ControlClient().call(tool: "grux_brands", arguments: [:]) {
        case .failure(let why):
            frame.open(.look)
            print(r.prose(frame.explain(why)))
            print("")
            print(r.style.ink(.dim, r.prose("Brands are the one inventory that lives inside "
                + "the app. grux list features, capabilities and projects all answer with "
                + "Grux closed.", indent: 2)))
            leave(.failed)
        case .success(let text):
            let obj = (try? JSONSerialization.jsonObject(with: Data(text.utf8)))
                as? [String: Any]
            let known = (obj?["brands"] as? [String] ?? [])
                .sorted { $0.lowercased() < $1.lowercased() }
            let current = (obj?["current"] as? String) ?? ""
            if json {
                let payload = known.map { ["name": $0, "current": $0 == current]
                                          as [String: Any] }
                if let d = try? JSONSerialization.data(withJSONObject: payload,
                                                       options: [.prettyPrinted, .sortedKeys]),
                   let t = String(data: d, encoding: .utf8) { print(t) }
                leave(.done)
            }
            frame.open(.look, "From your brand ledger, which the app reads.")
            guard !known.isEmpty else {
                print(r.row(state: .skipped, label: "No brands configured", labelWidth: 0))
                leave(.done)
            }
            let width = known.map(\.count).max() ?? 12
            for b in known {
                print(r.row(state: b == current ? .satisfied : .skipped, label: b,
                            detail: b == current ? "current" : nil,
                            labelWidth: width, indent: 4))
            }
            print("")
            print(r.style.ink(.dim, r.prose(current.isEmpty
                ? "\(known.count) brands, none selected. grux use <brand> picks one."
                : "\(known.count) brands, working on \(current).")))
            leave(.done)
        }
    }
}
