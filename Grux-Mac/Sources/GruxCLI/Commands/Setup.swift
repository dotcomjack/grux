import ArgumentParser
import Foundation
import GruxSetupCore

// MARK: - grux setup

/// The whole flow, six beats in the order the grammar fixes them.
///
/// LOOK asks for nothing. CHOOSE asks for nothing. COST shows the entire bill BEFORE a
/// single dialog, including by name the things that will never be requested. Only then does
/// GRANT ask, and everything it asks is skippable. That ordering is the promise; a command
/// that asked first and explained afterwards would have broken it however good each screen
/// was on its own.
struct Setup: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Set Grux up: look, choose, see the cost, then grant.")

    @Option(name: .long, help: "Comma separated feature ids. Skips the picker.")
    var features: String?

    @Option(name: .long, help: "A starting point: minimal, workday, or everything.")
    var preset: String?

    @Flag(name: .long, help: "Never prompt. Requires --features or --preset.")
    var noInput = false

    @Flag(name: .long, help: "Show what would change and write nothing.")
    var dryRun = false

    static let presets: [String: (name: String, ids: [String])] = [
        "minimal": ("Just enough to have a Grux",
                    ["home", "chat", "approvals", "settings"]),
        "workday": ("A working day",
                    ["home", "chat", "approvals", "settings", "mailbox", "calendar", "notes",
                     "contacts", "tasks", "meetings", "focus", "research", "documents"]),
        "everything": ("Everything, including the labs surfaces", []),
    ]

    func run() throws {
        let frame = Frame()
        let r = frame.renderer
        let client = ControlClient()

        let status: SetupStatus
        switch SetupStatusReader.read() {
        case .success(let s): status = s
        case .failure(let e): leave(frame.explain(e))
        }

        // ---- LOOK ------------------------------------------------------------------
        frame.open(.look, "Nothing on this screen asks you for anything.")
        print(r.row(state: .satisfied, label: "Grux", detail: status.appVersion, labelWidth: 22))
        print(r.row(state: client.isAvailable ? .satisfied : .needed,
                    label: "Grux is running", detail: client.socketPath, labelWidth: 22))
        print(r.row(state: .satisfied, label: "Features available",
                    detail: "\(status.features.count)", labelWidth: 22))
        print(r.row(state: .satisfied, label: "Things it can use",
                    detail: "\(status.capabilities.count)", labelWidth: 22))
        if !client.isAvailable {
            print("")
            print(r.prose("Grux is not running, and it owns every setting this command "
                          + "writes. Open it and run this again."))
            leave(.waitingOnYou)
        }

        // ---- CHOOSE ----------------------------------------------------------------
        let chosen: Set<String>
        switch try choose(status: status, frame: frame) {
        case .some(let ids): chosen = ids
        case .none:
            print("")
            print(r.prose("Left without changing anything."))
            leave(.done)
        }

        // ---- COST ------------------------------------------------------------------
        let byID = Dictionary(uniqueKeysWithValues: status.features.map { ($0.id, $0) })
        let bill = GruxSetupCore.Cost.of(features: chosen.compactMap { byID[$0] },
                                         allCapabilities: status.capabilities.map(\.id),
                                         allFeatures: status.features)
        frame.open(.cost)
        // ONE renderer, shared with `grux cost`. These two answered the same question with
        // two different screens: this one printed nineteen rows flat, mixing permissions,
        // keys, mail servers and one-time jobs as one undifferentiated errand.
        let view = BillView(renderer: r, capabilities: status.capabilities)
        let labels = Dictionary(uniqueKeysWithValues: status.capabilities.map { ($0.id, $0.label) })
        if chosen.isEmpty {
            print(r.row(state: .satisfied,
                        label: "You picked nothing, so nothing will be asked for.",
                        labelWidth: 0))
        } else {
            print(view.summary(for: bill, selectionCount: chosen.count,
                               totalCapabilities: status.capabilities.count))
            view.lines(for: bill, selectionCount: chosen.count,
                       totalCapabilities: status.capabilities.count).forEach { print($0) }
        }
        // NOT the selection echoed back as thirty nine ids. That printed a nine line wall of
        // machine names ending in "any time", which is unreadable and, worse, unusable: it
        // is a command nobody would retype. `grux cost` with no arguments prices whatever is
        // currently chosen, so the useful suggestion is the short one.
        print(r.style.ink(.dim, r.prose("Run grux cost to see this again at any time, "
                                        + "including the full never-asked-for list.")))

        if dryRun {
            print("")
            print(r.rule())
            print(r.prose("Dry run. Nothing was written."))
            leave(.done)
        }

        // ---- GRANT -----------------------------------------------------------------
        frame.open(.grant)
        switch client.call(tool: "grux_set_features",
                           arguments: ["features": Array(chosen)]) {
        case .success(let text):
            print(r.row(state: .satisfied, label: text, labelWidth: 0))
        case .failure(let why):
            print(r.prose("Could not save the selection. " + frame.explain(why)))
            leave(.failed)
        }

        // THE APP ASKS, NEVER THIS BINARY. A permission requested from a terminal is granted
        // to the terminal, measured on this machine, so the queue is handed over and Grux
        // raises each dialog under its own signature.
        let perms = bill.blocking.filter { labels[$0] != nil && $0.hasPrefix("perm.") }
        if perms.isEmpty {
            print("")
            print(r.row(state: .satisfied, label: "No macOS permission is needed.",
                        labelWidth: 0))
        } else if noInput {
            print("")
            print(r.prose("\(perms.count) macOS permission\(perms.count == 1 ? "" : "s") "
                          + "still needed. Run grux setup without --no-input, or grant them "
                          + "in Grux, because a dialog needs a person."))
            for id in perms { print(r.row(state: .needed, label: labels[id] ?? id, detail: id)) }
        } else {
            print("")
            print(r.prose("Grux will ask for \(perms.count) permission"
                          + "\(perms.count == 1 ? "" : "s"). Its name is on every dialog, "
                          + "because a request made from a terminal would grant the "
                          + "permission to your terminal instead."))
            for id in perms {
                print(r.row(state: .needed, label: labels[id] ?? id, detail: id))
                _ = client.call(tool: "grux_request_permission", arguments: ["id": id])
            }
        }

        // ---- HAND OFF --------------------------------------------------------------
        frame.open(.handOff)
        switch client.call(tool: "grux_handoff") {
        case .success(let text):
            print(r.style.ink(.dim, "  " + text.replacingOccurrences(of: "\n", with: "\n  ")))
        case .failure(let why):
            print(r.prose("Could not build the handoff. " + frame.explain(why)
                          + " Run grux handoff to try again."))
        }

        // ---- PROVE -----------------------------------------------------------------
        frame.open(.prove)
        _ = client.call(tool: "grux_refresh_status")
        if case .success(let after) = SetupStatusReader.read() {
            print(r.row(state: .satisfied,
                        label: "\(after.summary.featuresChosen) of \(after.features.count) features on",
                        labelWidth: 0))
            print(r.row(state: after.summary.featuresNeedingSetup == 0 ? .satisfied : .needed,
                        label: "\(after.summary.featuresNeedingSetup) still waiting on you",
                        labelWidth: 0))
        }
        print("")
        print(r.rule())
        print("  " + r.style.ink(.dim, "grux status") + "        what is still open, any time")
        print("  " + r.style.ink(.dim, "grux list") + "          every feature, on or off")
        print("  " + r.style.ink(.dim, "grux handoff") + "       the prompt above again")
        leave(.done)
    }

    /// Returns the chosen ids, or nil when the person left without deciding.
    private func choose(status: SetupStatus, frame: Frame) throws -> Set<String>? {
        let r = frame.renderer

        if let raw = features {
            let ids = raw.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
            let known = Set(status.features.map(\.id))
            let unknown = ids.filter { !known.contains($0) }
            guard unknown.isEmpty else {
                print("")
                print(r.prose("No feature called \(unknown.joined(separator: ", ")). "
                              + "Run grux list to see them all."))
                throw ExitCode(Exit.failed.rawValue)
            }
            return Set(ids)
        }

        if let name = preset {
            guard let p = Self.presets[name] else {
                print("")
                print(r.prose("No preset called \(name). Try "
                              + Self.presets.keys.sorted().joined(separator: ", ") + "."))
                throw ExitCode(Exit.failed.rawValue)
            }
            guard !p.ids.isEmpty else { return Set(status.features.map(\.id)) }
            // A PRESET NAMES REAL FEATURES OR IT IS A BUG IN THIS BINARY. These ids are
            // hardcoded here, which is a second copy of knowledge that lives in the
            // registry, so a rename elsewhere would silently shrink the preset: it would
            // still print "minimal" and quietly turn on three features instead of four.
            // Failing loudly is the only honest option, because the person running this
            // cannot tell the difference and has no way to fix it.
            let known = Set(status.features.map(\.id))
            let stale = p.ids.filter { !known.contains($0) }
            guard stale.isEmpty else {
                print("")
                print(r.prose("The \(name) preset names \(r.list(stale)), which this Grux "
                              + "does not have. That is a bug in this binary, not something "
                              + "you did. Pass --features instead, or run grux list."))
                throw ExitCode(Exit.failed.rawValue)
            }
            return Set(p.ids)
        }

        if noInput {
            print("")
            print(r.prose("--no-input needs --features or --preset, because there is nobody "
                          + "to ask. Nothing was changed."))
            throw ExitCode(Exit.failed.rawValue)
        }

        guard RawMode.isSupported else {
            // A non-TTY with no flags is a machine that forgot to say what it wanted. Saying
            // so beats silently choosing a default nobody asked for.
            print("")
            print(r.prose("Nothing is attached to this terminal, so there is nobody to ask. "
                          + "Pass --features or --preset."))
            throw ExitCode(Exit.failed.rawValue)
        }

        return interactiveChoose(status: status, frame: frame)
    }
}

// MARK: - the interactive picker

/// CHOOSE, drawn.
///
/// The state machine is `MultiSelect` in GruxSetupCore and is fully tested without a
/// terminal; this function only draws it and feeds it keys. That split is deliberate: a
/// selection that can only be exercised by a human finger is a selection nobody has tested.
private func interactiveChoose(status: SetupStatus, frame: Frame) -> Set<String>? {
    let r = frame.renderer
    let presets = Setup.presets.map { name, p in
        MultiSelect.Preset(key: name.first ?? "?", name: p.name,
                           ids: p.ids.isEmpty ? status.features.map(\.id) : p.ids)
    }.sorted { $0.name.lowercased() < $1.name.lowercased() }

    let items = status.features.map {
        MultiSelect.Item(id: $0.id, label: $0.label, group: $0.tier,
                         badge: $0.tier == "labs" ? "BETA" : nil)
    }
    // Start from what is already on, so re-running is not a fresh interrogation. The settled
    // decision is that a second run restarts the walk without redoing completed work.
    var picker = MultiSelect(items: items, presets: presets,
                             chosen: Set(status.features.filter(\.chosen).map(\.id)))

    let rows = max(6, min(16, frame.style.width / 4))

    func draw() {
        // Clear and home, so the list updates in place instead of scrolling forever.
        print("\u{1B}[2J\u{1B}[H", terminator: "")
        print("  " + r.rail(current: .choose))
        print("")
        print(r.prose("Space toggles. Enter confirms. Nothing is asked for on this screen."))
        print("")
        let keys = presets.map { "\(r.style.ink(.accent, String($0.key))) \($0.name)" }
        print("  " + r.style.ink(.dim, "presets  ") + keys.joined(separator: r.style.ink(.dim, "   ")))
        print("")
        let w = picker.window(height: rows)
        if w.above > 0 { print("  " + r.style.ink(.dim, "  \(w.above) more above")) }
        for i in w.range {
            let item = picker.items[i]
            let on = picker.chosen.contains(item.id)
            let here = i == picker.cursor
            let pointer = here ? r.style.ink(.accent, ">") : " "
            let box = on ? r.style.ink(.ok, "[x]") : r.style.ink(.dim, "[ ]")
            let badge = item.badge.map { " " + r.style.ink(.attention, $0) } ?? ""
            print("  \(pointer) \(box) \(item.label)\(badge)")
        }
        if w.below > 0 { print("  " + r.style.ink(.dim, "  \(w.below) more below")) }
        print("")
        print(r.rule())
        let n = picker.chosen.count
        print("  " + r.style.ink(.dim,
            "\(n) of \(picker.items.count) chosen. Nothing you leave out will ever be "
            + "asked about."))
    }

    return RawMode.withRawMode { () -> Set<String>? in
        draw()
        while picker.outcome == .running {
            guard let key = RawMode.readKey() else { break }
            picker.apply(key)
            draw()
        }
        print("")
        return picker.outcome == .confirmed ? picker.chosen : nil
    }
}
