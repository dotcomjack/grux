import AppKit
import ApplicationServices
import Foundation

// User-defined voice macros. A macro is a phrase ("open the dashboard")
// bound to a short sequence of actions the assistant will execute in order.
//
// Design:
//   - Claude calls `run_macro(name:)` when it hears a trigger. The list of
//     available macros is injected into the volatile system block so Claude
//     sees the possible names + trigger phrases + one-line descriptions.
//   - Macros persist at ~/Library/Application Support/Grux/macros.json.
//   - There are NO compiled-in macros. A fresh install owns an empty list
//     until you build one in the Commands tab, and load() never writes.
//     This file used to ship a seed, and a seed is two separate bugs: it put
//     one person's private wake ritual (its name, its spoken trigger phrases,
//     its song) on every stranger's machine, and load() called save()
//     immediately after seeding, so the compiled-in default landed in
//     macros.json indistinguishable from a macro you had authored yourself.
//     Anything added back here ships to every install with no macros.json,
//     so add nothing: an empty Commands tab is the correct fresh state.

enum MacroAction: Codable, Equatable, Hashable {
    case launchApp(name: String)
    case openURL(url: String)
    case spawnTerminalsToGrid(rows: Int, cols: Int)     // spawns fresh new windows + tiles
    case enableTerminalFocusOverlay
    case disableTerminalFocusOverlay                     // tear down the overlay; Terminal stays
    case playMusic(song: String, artist: String)
    case prepareCleanWorkspace                           // minimize existing terminals + hide other apps
    case runShell(command: String)                       // /bin/zsh -lc, captures stdout+stderr
    case runInTerminalCell(row: Int, col: Int, command: String) // types into the Terminal window at grid (row,col)
    case speakShellOutput(setup: String, template: String) // runs `setup` shell, then speaks `template` (with $var interpolation) through SpeechEngine
    case runAppleScript(source: String)                  // NSAppleScript, returns string result or error
    case speak(text: String)                             // route through SpeechEngine; blocks until done
    case delay(seconds: Double)                          // pause between steps
    case awaitSilence(milliseconds: Int)
    case openEmpireDashboard

    // Codable single-case enum support
    enum CodingKeys: String, CodingKey { case kind, name, url, rows, cols, row, col, song, artist, command, setup, template, source, text, seconds, milliseconds }
    enum Kind: String, Codable {
        case launchApp, openURL, spawnTerminalsToGrid, enableTerminalFocusOverlay, disableTerminalFocusOverlay,
             playMusic, prepareCleanWorkspace, runShell, runInTerminalCell, speakShellOutput, runAppleScript, speak, delay, awaitSilence,
             openEmpireDashboard
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .launchApp(let n):
            try c.encode(Kind.launchApp, forKey: .kind)
            try c.encode(n, forKey: .name)
        case .openURL(let u):
            try c.encode(Kind.openURL, forKey: .kind)
            try c.encode(u, forKey: .url)
        case .spawnTerminalsToGrid(let r, let cc):
            try c.encode(Kind.spawnTerminalsToGrid, forKey: .kind)
            try c.encode(r, forKey: .rows)
            try c.encode(cc, forKey: .cols)
        case .enableTerminalFocusOverlay:
            try c.encode(Kind.enableTerminalFocusOverlay, forKey: .kind)
        case .disableTerminalFocusOverlay:
            try c.encode(Kind.disableTerminalFocusOverlay, forKey: .kind)
        case .playMusic(let s, let a):
            try c.encode(Kind.playMusic, forKey: .kind)
            try c.encode(s, forKey: .song)
            try c.encode(a, forKey: .artist)
        case .prepareCleanWorkspace:
            try c.encode(Kind.prepareCleanWorkspace, forKey: .kind)
        case .runShell(let command):
            try c.encode(Kind.runShell, forKey: .kind)
            try c.encode(command, forKey: .command)
        case .runInTerminalCell(let row, let col, let command):
            try c.encode(Kind.runInTerminalCell, forKey: .kind)
            try c.encode(row, forKey: .row)
            try c.encode(col, forKey: .col)
            try c.encode(command, forKey: .command)
        case .speakShellOutput(let setup, let template):
            try c.encode(Kind.speakShellOutput, forKey: .kind)
            try c.encode(setup, forKey: .setup)
            try c.encode(template, forKey: .template)
        case .runAppleScript(let source):
            try c.encode(Kind.runAppleScript, forKey: .kind)
            try c.encode(source, forKey: .source)
        case .speak(let text):
            try c.encode(Kind.speak, forKey: .kind)
            try c.encode(text, forKey: .text)
        case .delay(let seconds):
            try c.encode(Kind.delay, forKey: .kind)
            try c.encode(seconds, forKey: .seconds)
        case .awaitSilence(let ms):
            try c.encode(Kind.awaitSilence, forKey: .kind)
            try c.encode(ms, forKey: .milliseconds)
        case .openEmpireDashboard:
            try c.encode(Kind.openEmpireDashboard, forKey: .kind)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .launchApp: self = .launchApp(name: try c.decode(String.self, forKey: .name))
        case .openURL: self = .openURL(url: try c.decode(String.self, forKey: .url))
        case .spawnTerminalsToGrid:
            self = .spawnTerminalsToGrid(
                rows: try c.decode(Int.self, forKey: .rows),
                cols: try c.decode(Int.self, forKey: .cols)
            )
        case .enableTerminalFocusOverlay: self = .enableTerminalFocusOverlay
        case .disableTerminalFocusOverlay: self = .disableTerminalFocusOverlay
        case .playMusic:
            self = .playMusic(
                song: try c.decode(String.self, forKey: .song),
                artist: try c.decode(String.self, forKey: .artist)
            )
        case .prepareCleanWorkspace:
            self = .prepareCleanWorkspace
        case .runShell:
            self = .runShell(command: try c.decode(String.self, forKey: .command))
        case .runInTerminalCell:
            self = .runInTerminalCell(
                row: try c.decode(Int.self, forKey: .row),
                col: try c.decode(Int.self, forKey: .col),
                command: try c.decode(String.self, forKey: .command)
            )
        case .speakShellOutput:
            // New format: explicit `setup` + `template`. Legacy: single `command`
            // string - gets decoded as `setup` only (template empty), and the
            // executor runs it as-is. Trailing `echo "…"` migration is handled
            // by macros.json migration; this is just the runtime fallback.
            if let setup = try c.decodeIfPresent(String.self, forKey: .setup) {
                let template = (try c.decodeIfPresent(String.self, forKey: .template)) ?? ""
                self = .speakShellOutput(setup: setup, template: template)
            } else {
                let legacy = try c.decode(String.self, forKey: .command)
                self = .speakShellOutput(setup: legacy, template: "")
            }
        case .runAppleScript:
            self = .runAppleScript(source: try c.decode(String.self, forKey: .source))
        case .speak:
            self = .speak(text: try c.decode(String.self, forKey: .text))
        case .delay:
            self = .delay(seconds: try c.decode(Double.self, forKey: .seconds))
        case .awaitSilence:
            self = .awaitSilence(milliseconds: try c.decode(Int.self, forKey: .milliseconds))
        case .openEmpireDashboard:
            self = .openEmpireDashboard
        }
    }

    // Stable identifier for picker selection in the editor.
    var kindID: Kind {
        switch self {
        case .launchApp: return .launchApp
        case .openURL: return .openURL
        case .spawnTerminalsToGrid: return .spawnTerminalsToGrid
        case .enableTerminalFocusOverlay: return .enableTerminalFocusOverlay
        case .disableTerminalFocusOverlay: return .disableTerminalFocusOverlay
        case .playMusic: return .playMusic
        case .prepareCleanWorkspace: return .prepareCleanWorkspace
        case .runShell: return .runShell
        case .runInTerminalCell: return .runInTerminalCell
        case .speakShellOutput: return .speakShellOutput
        case .runAppleScript: return .runAppleScript
        case .speak: return .speak
        case .delay: return .delay
        case .awaitSilence: return .awaitSilence
        case .openEmpireDashboard: return .openEmpireDashboard
        }
    }

    // Human-readable one-line summary used in the list view.
    var summary: String {
        switch self {
        case .launchApp(let n): return "Launch app → \(n)"
        case .openURL(let u): return "Open URL → \(u)"
        case .spawnTerminalsToGrid(let r, let c): return "Spawn Terminal grid \(r)×\(c)"
        case .enableTerminalFocusOverlay: return "Enable Terminal Focus overlay"
        case .disableTerminalFocusOverlay: return "Disable Terminal Focus overlay"
        case .playMusic(let s, let a): return "Play music → \(s) - \(a)"
        case .prepareCleanWorkspace: return "Prepare clean workspace"
        case .runShell(let c):
            let oneLine = c.split(separator: "\n").first.map(String.init) ?? c
            return "Run shell → \(oneLine)"
        case .runInTerminalCell(let row, let col, let c):
            let oneLine = c.split(separator: "\n").first.map(String.init) ?? c
            return "Run in Terminal cell (r\(row),c\(col)) → \(oneLine)"
        case .speakShellOutput(let setup, let template):
            let preview = template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? (setup.split(separator: "\n").first.map(String.init) ?? "")
                : template.trimmingCharacters(in: .whitespacesAndNewlines)
            return "Speak shell output → \(preview)"
        case .runAppleScript(let s):
            let oneLine = s.split(separator: "\n").first.map(String.init) ?? s
            return "Run AppleScript → \(oneLine)"
        case .speak(let t): return "Speak → \(t)"
        case .delay(let s): return "Wait \(String(format: "%.1f", s))s"
        case .awaitSilence(let ms): return "Wait for silence (\(ms)ms)"
        case .openEmpireDashboard: return "Open Empire Dashboard"
        }
    }

    static func defaultAction(for kind: Kind) -> MacroAction {
        switch kind {
        case .launchApp: return .launchApp(name: "")
        case .openURL: return .openURL(url: "https://")
        case .spawnTerminalsToGrid: return .spawnTerminalsToGrid(rows: 2, cols: 2)
        case .enableTerminalFocusOverlay: return .enableTerminalFocusOverlay
        case .disableTerminalFocusOverlay: return .disableTerminalFocusOverlay
        case .playMusic: return .playMusic(song: "", artist: "")
        case .prepareCleanWorkspace: return .prepareCleanWorkspace
        case .runShell: return .runShell(command: "")
        case .runInTerminalCell: return .runInTerminalCell(row: 0, col: 0, command: "")
        case .speakShellOutput: return .speakShellOutput(setup: "", template: "")
        case .runAppleScript: return .runAppleScript(source: "")
        case .speak: return .speak(text: "")
        case .delay: return .delay(seconds: 1.0)
        case .awaitSilence: return .awaitSilence(milliseconds: 500)
        case .openEmpireDashboard: return .openEmpireDashboard
        }
    }
}

extension MacroAction.Kind {
    var label: String {
        switch self {
        case .launchApp: return "Launch app"
        case .openURL: return "Open URL"
        case .spawnTerminalsToGrid: return "Spawn Terminal grid"
        case .enableTerminalFocusOverlay: return "Enable Terminal Focus overlay"
        case .disableTerminalFocusOverlay: return "Disable Terminal Focus overlay"
        case .playMusic: return "Play music"
        case .prepareCleanWorkspace: return "Prepare clean workspace"
        case .runShell: return "Run shell command"
        case .runInTerminalCell: return "Run in Terminal grid cell"
        case .speakShellOutput: return "Speak shell output"
        case .runAppleScript: return "Run AppleScript"
        case .speak: return "Speak text"
        case .delay: return "Wait / delay"
        case .awaitSilence: return "Wait for silence"
        case .openEmpireDashboard: return "Open Empire Dashboard"
        }
    }
    static var allCases: [MacroAction.Kind] {
        [.launchApp, .openURL, .runShell, .runInTerminalCell, .speakShellOutput, .runAppleScript,
         .playMusic, .spawnTerminalsToGrid,
         .enableTerminalFocusOverlay, .disableTerminalFocusOverlay, .prepareCleanWorkspace, .speak, .delay, .awaitSilence,
         .openEmpireDashboard]
    }
}

// A single step inside a macro. Wraps MacroAction with an `enabled` flag so
// users can toggle individual actions on/off without deleting them.
// Persisted as `{"action": {...}, "enabled": true}` but decodes legacy
// `{...MacroAction...}` entries transparently so macros.json written by
// pre-step versions keeps working.
struct MacroStep: Codable, Equatable, Hashable {
    var action: MacroAction
    var enabled: Bool
    var waitForCompletion: Bool

    init(action: MacroAction, enabled: Bool = true, waitForCompletion: Bool = true) {
        self.action = action
        self.enabled = enabled
        self.waitForCompletion = waitForCompletion
    }

    private enum WrappedKeys: String, CodingKey { case action, enabled, waitForCompletion }

    init(from decoder: Decoder) throws {
        // New schema: {"action": {...}, "enabled": Bool}. Detect by presence
        // of the "action" key - MacroAction's own keys never include "action".
        if let c = try? decoder.container(keyedBy: WrappedKeys.self),
           c.contains(.action) {
            self.action = try c.decode(MacroAction.self, forKey: .action)
            self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
            self.waitForCompletion = try c.decodeIfPresent(Bool.self, forKey: .waitForCompletion) ?? true
            return
        }
        // Legacy schema: the object IS a MacroAction. Decode in-place and
        // mark as enabled so old command files behave exactly as before.
        self.action = try MacroAction(from: decoder)
        self.enabled = true
        self.waitForCompletion = true
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: WrappedKeys.self)
        try c.encode(action, forKey: .action)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(waitForCompletion, forKey: .waitForCompletion)
    }
}

struct Macro: Codable, Identifiable, Equatable, Hashable {
    var id: String { name }
    var name: String           // stable machine id, e.g. "open_dashboard"
    var triggers: [String]     // spoken phrases the user might say
    var description: String    // one-line summary shown to Claude
    var actions: [MacroStep]
    var enabled: Bool

    init(name: String, triggers: [String], description: String, actions: [MacroStep], enabled: Bool = true) {
        self.name = name
        self.triggers = triggers
        self.description = description
        self.actions = actions
        self.enabled = enabled
    }

    // Convenience for seed data + callers that only care about the action.
    init(name: String, triggers: [String], description: String, rawActions: [MacroAction], enabled: Bool = true) {
        self.init(
            name: name,
            triggers: triggers,
            description: description,
            actions: rawActions.map { MacroStep(action: $0) },
            enabled: enabled
        )
    }

    // Explicit Codable so missing `enabled` decodes to true - synthesized
    // Codable would fail on legacy macros.json files written before the flag.
    private enum CodingKeys: String, CodingKey { case name, triggers, description, actions, enabled }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try c.decode(String.self, forKey: .name)
        self.triggers = try c.decode([String].self, forKey: .triggers)
        self.description = try c.decode(String.self, forKey: .description)
        self.actions = try c.decode([MacroStep].self, forKey: .actions)
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(triggers, forKey: .triggers)
        try c.encode(description, forKey: .description)
        try c.encode(actions, forKey: .actions)
        try c.encode(enabled, forKey: .enabled)
    }
}

extension Notification.Name {
    static let gruxMacrosChanged = Notification.Name("gruxMacrosChanged")
}

@MainActor
final class VoiceMacroRegistry: ObservableObject {
    static let shared = VoiceMacroRegistry()

    @Published private(set) var macros: [Macro] = []
    private var loaded = false

    private var url: URL { Persistence.supportDir.appendingPathComponent("macros.json") }

    func load() {
        guard !loaded else { return }
        loaded = true

        let fm = FileManager.default
        let fileExisted = fm.fileExists(atPath: url.path)
        var decodeFailed = false

        if let data = try? Data(contentsOf: url), !data.isEmpty {
            if let arr = try? JSONDecoder().decode([Macro].self, from: data) {
                macros = arr
            } else {
                // Full decode failed. Before we give up, try a per-item
                // partial decode so one bad entry can't cost you the rest.
                // If even that fails we keep the file exactly as it is and
                // start empty, because a decode failure is a parser problem,
                // never a licence to rewrite the only copy of your macros.
                decodeFailed = true
                if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                    var recovered: [Macro] = []
                    for obj in arr {
                        guard let itemData = try? JSONSerialization.data(withJSONObject: obj) else { continue }
                        if let m = try? JSONDecoder().decode(Macro.self, from: itemData) {
                            recovered.append(m)
                        }
                    }
                    if !recovered.isEmpty {
                        macros = recovered
                        WakeLog.shared.log("macros.json: partial recovery - \(recovered.count) of \(arr.count) items decoded")
                        // Quarantine the original so we can always roll back
                        // manually. A later save() replaces the file with the
                        // good subset; keep the raw for forensics either way.
                        quarantineCorruptFile(data: data, label: "partial")
                    }
                }
            }
        }

        // Nothing decoded. That is a SUPPORTED end state, not a failure to
        // paper over: the Commands tab renders its own "No commands yet" panel
        // telling you how to build one. load() deliberately writes nothing
        // here. It used to seed a default list and immediately save() it,
        // which is how a compiled-in default became a file on disk that looked
        // exactly like your own work, on a machine whose owner had never asked
        // for it. If you ever want a starter macro back, it belongs behind a
        // button you press, not behind the first launch.
        if macros.isEmpty, fileExisted, decodeFailed {
            // A file IS there, it just would not parse. Leave the original
            // untouched for you to inspect and quarantine a copy for history.
            // Starting empty beside a preserved file is recoverable; writing
            // over it is not.
            if let data = try? Data(contentsOf: url) {
                quarantineCorruptFile(data: data, label: "failed")
            }
            WakeLog.shared.log("macros.json: decode failed - existing file preserved, starting with no macros")
        }
    }

    private func quarantineCorruptFile(data: Data, label: String) {
        let ts = Int(Date().timeIntervalSince1970)
        let dir = url.deletingLastPathComponent()
        let quarantine = dir.appendingPathComponent("macros.\(label).\(ts).bak.json")
        try? data.write(to: quarantine, options: .atomic)
        WakeLog.shared.log("macros.json: quarantined to \(quarantine.lastPathComponent)")
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(macros) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func find(name: String) -> Macro? {
        let q = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return macros.first(where: { $0.name.lowercased() == q })
    }

    // MARK: - User editing API

    // Insert or update a macro. Identified by `name` (stable id).
    func upsert(_ macro: Macro) {
        if let idx = macros.firstIndex(where: { $0.name == macro.name }) {
            macros[idx] = macro
        } else {
            macros.append(macro)
        }
        save()
        NotificationCenter.default.post(name: .gruxMacrosChanged, object: nil)
    }

    // Rename a macro's stable id. No-op if `to` already exists and differs
    // from `from`. Returns true on success.
    @discardableResult
    func rename(from: String, to newName: String) -> Bool {
        let cleaned = Self.sanitize(name: newName)
        guard !cleaned.isEmpty, cleaned != from else { return false }
        if macros.contains(where: { $0.name == cleaned }) { return false }
        guard let idx = macros.firstIndex(where: { $0.name == from }) else { return false }
        macros[idx].name = cleaned
        save()
        NotificationCenter.default.post(name: .gruxMacrosChanged, object: nil)
        return true
    }

    func delete(name: String) {
        macros.removeAll(where: { $0.name == name })
        save()
        NotificationCenter.default.post(name: .gruxMacrosChanged, object: nil)
    }

    func duplicate(name: String) -> Macro? {
        guard let src = find(name: name) else { return nil }
        var copy = src
        copy.name = uniqueName(basedOn: src.name + "_copy")
        macros.append(copy)
        save()
        NotificationCenter.default.post(name: .gruxMacrosChanged, object: nil)
        return copy
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        macros.move(fromOffsets: source, toOffset: destination)
        save()
        NotificationCenter.default.post(name: .gruxMacrosChanged, object: nil)
    }

    // Generate a fresh snake_case name that doesn't collide.
    func newMacroTemplate() -> Macro {
        let baseName = uniqueName(basedOn: "new_command")
        return Macro(
            name: baseName,
            triggers: [],
            description: "",
            actions: []
        )
    }

    private func uniqueName(basedOn base: String) -> String {
        let cleaned = Self.sanitize(name: base)
        var candidate = cleaned
        var n = 2
        while macros.contains(where: { $0.name == candidate }) {
            candidate = "\(cleaned)_\(n)"
            n += 1
        }
        return candidate
    }

    // Lowercase, whitespace→underscore, strip non-[a-z0-9_]. Never empty.
    // nonisolated because it only does pure string work - safe to call from
    // any actor, including SwiftUI value-type bindings that don't inherit
    // @MainActor from the enclosing type.
    nonisolated static func sanitize(name: String) -> String {
        let lower = name.lowercased()
        var out = ""
        for ch in lower {
            if ch.isLetter || ch.isNumber { out.append(ch) }
            else if ch == " " || ch == "-" || ch == "_" { out.append("_") }
            // drop everything else
        }
        // Collapse multiple underscores and strip leading/trailing
        while out.contains("__") { out = out.replacingOccurrences(of: "__", with: "_") }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return out.isEmpty ? "command" : out
    }

    func systemPromptBlock() -> String {
        let active = macros.filter(\.enabled)
        guard !active.isEmpty else { return "(no macros registered)" }
        return active.map { m -> String in
            let triggers = m.triggers.map { "\"\($0)\"" }.joined(separator: ", ")
            return "  • name=\(m.name) - triggers: \(triggers) - \(m.description)"
        }.joined(separator: "\n")
    }

    // Execute a macro's actions in order. Returns a composed status string
    // suitable for a tool_result. Steps with `enabled == false` are logged
    // and skipped so the user can see which actions were off without losing
    // the run trace.
    func run(name: String) async -> String {
        guard let macro = find(name: name) else {
            return "error: no macro named '\(name)'. Known: \(macros.map(\.name).joined(separator: ", "))"
        }
        guard macro.enabled else {
            return "skipped: macro '\(macro.name)' is disabled"
        }
        var lines: [String] = ["running macro '\(macro.name)':"]
        for step in macro.actions {
            guard step.enabled else {
                lines.append("  - (disabled, skipped) \(step.action.summary)")
                continue
            }
            if step.waitForCompletion {
                let result = await execute(step.action)
                lines.append("  - \(result)")
            } else {
                lines.append("  - (detached) \(step.action.summary)")
                let macroName = macro.name
                let action = step.action
                Task.detached {
                    let r = await VoiceMacroRegistry.shared.execute(action)
                    WakeLog.shared.log("macro '\(macroName)' detached step → \(r)")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    func execute(_ action: MacroAction) async -> String {
        switch action {
        case .launchApp(let name):
            let r = await AppLauncherTool.open(name: name)
            if r.hasPrefix("ok:") {
                let deadline = Date().addingTimeInterval(8.0)
                while Date() < deadline {
                    let running = NSWorkspace.shared.runningApplications
                        .first(where: { $0.localizedName?.lowercased() == name.lowercased() })
                    if let app = running, app.isFinishedLaunching { break }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            return r
        case .openURL(let url):
            let r = BrowserTool.openURL(url)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            return r
        case .spawnTerminalsToGrid(let rows, let cols):
            return await TerminalGridTiler.spawnAndTile(rows: rows, cols: cols)
        case .enableTerminalFocusOverlay:
            // Route through showOverlay so the user-dismiss flag gets cleared -
            // otherwise "overlay on" after an explicit × click would be a no-op.
            TerminalFocusState.shared.showOverlay()
            return "ok: Terminal Focus overlay enabled"
        case .disableTerminalFocusOverlay:
            // hideOverlay() sets userHidden, which persists across launches.
            // Feature kill-switch (isEnabled) stays on so a future "overlay on"
            // is a single-gesture bring-back, not a full re-enable.
            TerminalFocusState.shared.hideOverlay()
            return "ok: Terminal Focus overlay dismissed"
        case .playMusic(let song, let artist):
            let r = await MusicTool.play(song: song, artist: artist)
            if r.hasPrefix("ok:") {
                await waitForMusicPlaying(song: song, timeoutSec: 8.0)
            }
            return r
        case .prepareCleanWorkspace:
            return WorkspacePreparer.makeCleanSlate()
        case .runShell(let command):
            return await ShellRunner.run(command: command)
        case .runInTerminalCell(let row, let col, let command):
            return await TerminalGridTiler.runInGridCell(row: row, col: col, command: command)
        case .speakShellOutput(let setup, let template):
            let setupTrim = setup.trimmingCharacters(in: .whitespacesAndNewlines)
            let tmplTrim = template.trimmingCharacters(in: .whitespacesAndNewlines)
            // Compose the real command. Template gets wrapped in `echo "…"` so
            // the user can author plain English with $VAR references and have
            // the shell interpolate them; only `"` and `\` need escaping. If
            // template is empty we run setup as-is (legacy / advanced path -
            // setup is expected to print the line itself).
            let combined: String
            if tmplTrim.isEmpty {
                guard !setupTrim.isEmpty else { return "ok: speak shell (empty, skipped)" }
                combined = setupTrim
            } else {
                let escaped = tmplTrim
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                if setupTrim.isEmpty {
                    combined = "echo \"\(escaped)\""
                } else {
                    combined = "\(setupTrim)\necho \"\(escaped)\""
                }
            }
            let r = await ShellRunner.runRaw(command: combined)
            let spoken = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !spoken.isEmpty else { return "ok: speak shell (no stdout to speak; exit \(r.status))" }
            await speakAndWait(spoken)
            return "ok: spoke shell stdout (\(spoken.count) chars; exit \(r.status))"
        case .runAppleScript(let source):
            return AppleScriptRunner.run(source: source)
        case .speak(let text):
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return "ok: speak (empty, skipped)" }
            await speakAndWait(t)
            return "ok: spoke \"\(t.prefix(80))\""
        case .delay(let seconds):
            let clamped = max(0.0, min(seconds, 60.0))
            try? await Task.sleep(nanoseconds: UInt64(clamped * 1_000_000_000))
            return "ok: waited \(String(format: "%.1f", clamped))s"
        case .awaitSilence(let ms):
            let clamped = max(0, min(ms, 10_000))
            try? await Task.sleep(nanoseconds: UInt64(clamped) * 1_000_000)
            return "ok: waited for silence (\(clamped)ms)"
        case .openEmpireDashboard:
            // Now a first-class tab in the main window - navigate to it
            // instead of spawning a separate floating window. Keeps the
            // workflow inside one app frame.
            AppDelegate.shared?.openLaunchWindow(tab: "empire")
            return "ok: switched to Empire tab"
        }
    }

    // Polls Apple Music until current track name fuzzy-matches the requested
    // song. Used after .playMusic so subsequent steps don't fire mid-spawn.
    private func waitForMusicPlaying(song: String, timeoutSec: Double = 8.0) async {
        let deadline = Date().addingTimeInterval(timeoutSec)
        let want = song.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        while Date() < deadline {
            let s = """
            tell application "Music"
                if it is not running then return "notrunning"
                if player state is not playing then return "notplaying"
                try
                    return name of current track
                on error
                    return "notrack"
                end try
            end tell
            """
            var err: NSDictionary?
            let raw = (NSAppleScript(source: s)?.executeAndReturnError(&err).stringValue ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if raw == "notrunning" || raw == "notplaying" || raw == "notrack" {
                try? await Task.sleep(nanoseconds: 100_000_000)
                continue
            }
            if !raw.isEmpty && (raw.contains(want) || want.contains(raw)) { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    // Routes text to SpeechEngine and blocks until the engine finishes the
    // line. Uses .gruxSpeechDidStop notification rather than polling so we
    // don't race a fast didStop. 300ms tail buffer accounts for AVAudio
    // drain latency after isSpeaking flips false.
    private func speakAndWait(_ text: String) async {
        let engine = SpeechEngine.shared

        // Subscribe BEFORE calling speak() so we don't miss a fast didStop.
        let stream = AsyncStream<Void> { continuation in
            let token = NotificationCenter.default.addObserver(
                forName: .gruxSpeechDidStop, object: nil, queue: .main
            ) { _ in continuation.yield() }
            continuation.onTermination = { _ in
                NotificationCenter.default.removeObserver(token)
            }
        }

        engine.speak(text)

        // Spawn-latency window: wait for the engine to actually start speaking.
        let startDeadline = Date().addingTimeInterval(1.5)
        while !engine.isSpeaking && Date() < startDeadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        // Wait for the real didStop signal, capped by a generous timeout (a wedged
        // audio pipeline shouldn't hang the macro forever). 12 chars/sec + 3s slack,
        // max 120s - same envelope as the old polling code.
        let timeout = min(120.0, max(3.0, Double(text.count) / 12.0 + 3.0))
        await withTaskGroup(of: Void.self) { group in
            group.addTask { for await _ in stream { return } }
            group.addTask { try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) }
            await group.next()
            group.cancelAll()
        }

        // 300ms tail buffer - AVAudio buffers drain ~200ms after isSpeaking flips
        // false. Without this, the next action clips the spoken tail.
        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    // MARK: - Defaults
    //
    // Intentionally none. Every macro in this registry came from the user.
    // The overlay macros that used to live here (overlay_on / overlay_off)
    // were generic enough to keep, but keeping them meant one of two things,
    // both wrong. Merged into `macros` they get persisted by the very next
    // save() from any edit, rename or reorder, so a compiled-in default turns
    // into user data the first time you touch the tab. Held in a parallel
    // built-in list they would need shadowing, dedupe and a non-deletable row
    // in CommandsView, which is a feature, not a de-personalization. No
    // capability was lost: `enableTerminalFocusOverlay` and
    // `disableTerminalFocusOverlay` are still first-class actions in the
    // Commands editor, and the overlay still has its menu bar toggle and its
    // × button, so anyone who wants those two macros can build them.
}

// Prepares a clean visual workspace without relying on private Spaces APIs:
//   1. Minimize every currently-visible Terminal window (preserves their
//      running processes/Claude sessions - restorable from the Dock).
//   2. Hide every regular-activationPolicy app except Terminal and Grux
//      itself. Finder stays hidden too; the result is a bare desktop.
// Visually indistinguishable from a fresh Space, no CGS private symbols.
@MainActor
enum WorkspacePreparer {
    private static let terminalBundleId = "com.apple.Terminal"

    static func makeCleanSlate() -> String {
        let gruxBundleId = Bundle.main.bundleIdentifier ?? "com.gruxai.grux"
        let keep: Set<String> = [terminalBundleId, gruxBundleId]

        // Scope everything to the CURRENT macOS Space via CGWindowList's
        // .optionOnScreenOnly filter. Windows on other Spaces stay untouched.
        let currentSpacePids = CurrentSpaceProbe.pidsOnCurrentSpace()
        let currentSpaceTerminals = CurrentSpaceProbe.terminalWindows()

        // 1. Hide apps that have a visible window on THIS Space (skip Terminal
        // + Grux). Apps sitting on other Spaces keep their windows intact -
        // when the user switches back to them later, nothing has been touched.
        var hidden = 0
        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular else { continue }
            guard let bid = app.bundleIdentifier, !keep.contains(bid) else { continue }
            guard currentSpacePids.contains(app.processIdentifier) else { continue }
            if app.isHidden { continue }
            if app.hide() { hidden += 1 }
        }

        // 2. Minimize only the Terminal windows on this Space. Match by
        // {left,top} integer bounds - CGWindowList's top-left origin matches
        // Terminal AppleScript's `bounds` first two components. Pass a list
        // of match keys into AppleScript so we only flip miniaturized on
        // windows whose bounds are in the allowlist.
        let keys = currentSpaceTerminals.map { w -> String in
            "\(Int(w.bounds.minX.rounded())),\(Int(w.bounds.minY.rounded()))"
        }
        var minimized = 0
        if !keys.isEmpty {
            let listLiteral = keys.map { "\"\($0)\"" }.joined(separator: ", ")
            let script = """
            tell application "Terminal"
                set targets to {\(listLiteral)}
                set n to 0
                repeat with w in windows
                    try
                        if miniaturized of w is false then
                            set b to bounds of w
                            set k to ((item 1 of b) as text) & "," & ((item 2 of b) as text)
                            if k is in targets then
                                set miniaturized of w to true
                                set n to n + 1
                            end if
                        end if
                    end try
                end repeat
                return n
            end tell
            """
            if let raw = runScript(script), let n = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
                minimized = n
            }
        }

        return "ok: current-Space cleanup (hid \(hidden) apps, minimized \(minimized) Terminal windows; other Spaces untouched)"
    }

    @discardableResult
    private static func runScript(_ source: String) -> String? {
        var err: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&err)
        if err != nil { return nil }
        return result?.stringValue
    }
}

// Tiles Terminal windows into an N×M grid on the main screen. Spawns missing
// windows via AppleScript (`do script ""`) and positions all N*M windows via
// the Accessibility API.
@MainActor
enum TerminalGridTiler {
    static let terminalBundleId = "com.apple.Terminal"

    // All operations go through AppleScript to Terminal.app. Current-Space
    // scoping comes from CGWindowList (see CurrentSpaceProbe). Spawn + tile
    // happens one window at a time: we create a new Terminal window (it
    // becomes window 1, frontmost on the current Space) and immediately set
    // its bounds, before the next spawn. That way each freshly-spawned window
    // is precisely-positionable without matching against any other window's
    // state.
    static func spawnAndTile(rows: Int, cols: Int) async -> String {
        let target = max(1, rows * cols)

        // 1. Launch Terminal in the background (NOT activate - activating
        // Terminal when it has zero visible windows triggers macOS's
        // "app reopen" behavior, which auto-opens a fresh window BEFORE
        // our deliberate `do script` calls fire. That gave us 5 windows
        // instead of 4. `launch` starts the app without the reopen hook.
        let launched = runScript("""
        launch application "Terminal"
        tell application "Terminal"
            set t0 to current date
            repeat until ((current date) - t0) > 2
                try
                    count of windows
                    return "ok"
                on error
                    delay 0.1
                end try
            end repeat
            return "timeout"
        end tell
        """)
        guard (launched ?? "") == "ok" else {
            return "error: Terminal didn't respond to scripting - grant Automation permission in System Settings → Privacy & Security → Automation → Grux → Terminal."
        }

        let quads = axQuadrants(rows: rows, cols: cols)
        guard quads.count == target else { return "error: computed \(quads.count) quadrants" }

        // 2. Spawn-then-position loop, one window per quadrant. Each freshly
        // spawned window is `window 1` until the next spawn - so we set its
        // bounds immediately after creation, no cross-referencing needed.
        var tiled = 0
        for q in quads {
            let left = Int(q.minX.rounded())
            let top = Int(q.minY.rounded())
            let right = Int(q.maxX.rounded())
            let bottom = Int(q.maxY.rounded())

            let spawnAndSet = """
            tell application "Terminal"
                do script ""
                delay 0.25
                try
                    set bounds of window 1 to {\(left), \(top), \(right), \(bottom)}
                    return "ok"
                on error errMsg
                    return "err:" & errMsg
                end try
            end tell
            """
            let r = runScript(spawnAndSet) ?? ""
            if r == "ok" { tiled += 1 }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }

        // 3. NOW bring Terminal to front. NSRunningApplication.activate()
        // doesn't trigger the reopen hook that `activate` AppleScript does,
        // so it won't spawn a phantom extra window.
        if let term = NSRunningApplication.runningApplications(withBundleIdentifier: terminalBundleId).first {
            term.activate()
        }

        if tiled < target {
            return "ok: tiled \(tiled)/\(target) - a window didn't accept bounds (non-fatal)"
        }
        return "ok: \(rows)×\(cols) Terminal grid live on current Space (\(tiled) windows)"
    }

    // Screen-coordinate quadrants for `set bounds`. Top-left origin of the
    // primary display. Matches AppleScript + AX convention.
    static func axQuadrants(rows: Int, cols: Int) -> [CGRect] {
        guard let screen = NSScreen.main, rows > 0, cols > 0 else { return [] }
        let full = screen.frame
        let visible = screen.visibleFrame
        let originX = visible.minX
        let originY = full.height - visible.maxY   // distance from top of screen to top of visible area
        let w = visible.width / CGFloat(cols)
        let h = visible.height / CGFloat(rows)
        var rects: [CGRect] = []
        for r in 0..<rows {
            for c in 0..<cols {
                rects.append(CGRect(
                    x: originX + CGFloat(c) * w,
                    y: originY + CGFloat(r) * h,
                    width: w,
                    height: h
                ))
            }
        }
        return rects
    }

    @discardableResult
    private static func runScript(_ source: String) -> String? {
        var err: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&err)
        if err != nil { return nil }
        return result?.stringValue
    }

    // Send a real zsh command into the Terminal window currently sitting at
    // grid cell (row, col). Identifies the target by matching window bounds
    // against `axQuadrants` for a candidate grid that contains the requested
    // cell - so the same action works regardless of which N×M grid was
    // spawned earlier. AppleScript `do script ... in window id N` types and
    // runs the command in that window.
    static func runInGridCell(row: Int, col: Int, command: String) async -> String {
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return "ok: terminal cell (empty command, skipped)" }
        guard row >= 0, col >= 0 else { return "error: row/col must be ≥ 0" }

        // Inspect Terminal's current windows (id + bounds). AppleScript
        // returns a flat comma-joined list: id1,l1,t1,r1,b1,id2,l2,…
        let listing = runScript("""
        tell application "Terminal"
            set out to {}
            repeat with w in windows
                try
                    set b to bounds of w
                    set end of out to id of w
                    set end of out to item 1 of b
                    set end of out to item 2 of b
                    set end of out to item 3 of b
                    set end of out to item 4 of b
                end try
            end repeat
            set AppleScript's text item delimiters to ","
            return out as string
        end tell
        """) ?? ""
        let parts = listing.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count >= 5, parts.count % 5 == 0 else {
            return "error: couldn't read Terminal windows - is the Terminal grid running? Add a 'Spawn Terminal grid' step before this one."
        }
        struct WinRect { let id: Int; let rect: CGRect }
        var wins: [WinRect] = []
        for i in stride(from: 0, to: parts.count, by: 5) {
            let l = parts[i+1], t = parts[i+2], r = parts[i+3], b = parts[i+4]
            wins.append(WinRect(id: parts[i], rect: CGRect(x: l, y: t, width: r - l, height: b - t)))
        }

        // Try plausible grid sizes (smallest first) that contain the
        // requested cell. Pick the first whose computed quadrant has a
        // window within 60pt of its center.
        let candidates: [(rows: Int, cols: Int)] = (1...4).flatMap { r in (1...4).map { c in (r, c) } }
            .filter { $0.rows > row && $0.cols > col }
            .sorted { $0.rows * $0.cols < $1.rows * $1.cols }

        var matchedID: Int?
        for cand in candidates {
            let quads = axQuadrants(rows: cand.rows, cols: cand.cols)
            guard quads.count == cand.rows * cand.cols else { continue }
            let target = quads[row * cand.cols + col]
            if let hit = wins.min(by: { rectDistance($0.rect, target) < rectDistance($1.rect, target) }),
               rectDistance(hit.rect, target) < 60 {
                matchedID = hit.id
                break
            }
        }
        guard let winID = matchedID else {
            return "error: no Terminal window at row \(row), col \(col). Spawn the grid first (add a 'Spawn Terminal grid' action above this one)."
        }

        let escaped = cmd
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let send = """
        tell application "Terminal"
            try
                do script "\(escaped)" in window id \(winID)
                return "ok"
            on error errMsg
                return "err:" & errMsg
            end try
        end tell
        """
        let result = runScript(send) ?? ""
        if result == "ok" {
            return "ok: ran in Terminal cell (\(row),\(col)) → \(cmd.prefix(80))"
        }
        return "error: terminal cell - \(result.isEmpty ? "AppleScript failed" : result)"
    }

    private static func rectDistance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        abs(a.midX - b.midX) + abs(a.midY - b.midY)
    }
}

// Runs an arbitrary zsh command under the user's login shell, capturing
// stdout + stderr, with a 30s hard timeout. Output is truncated so tool
// results stay within Claude's context budget.
enum ShellRunner {
    struct RawResult {
        let status: Int32
        let stdout: String     // raw, untruncated
        let truncated: String  // capped at 4000 chars for display
    }

    static func runRaw(command: String, timeoutSeconds: Int = 30) async -> RawResult {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return RawResult(status: 0, stdout: "", truncated: "")
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<RawResult, Never>) in
            let proc = Process()
            proc.launchPath = "/bin/zsh"
            proc.arguments = ["-lc", trimmed]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            do {
                try proc.run()
            } catch {
                cont.resume(returning: RawResult(status: -1, stdout: "failed to launch shell - \(error.localizedDescription)", truncated: ""))
                return
            }
            let deadline = DispatchTime.now() + .seconds(timeoutSeconds)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: deadline) {
                if proc.isRunning { proc.terminate() }
            }
            DispatchQueue.global(qos: .utility).async {
                proc.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let raw = String(data: data, encoding: .utf8) ?? ""
                let trunc: String = raw.count <= 4000 ? raw
                    : String(raw.prefix(4000)) + "\n…(truncated, \(raw.count) chars total)"
                cont.resume(returning: RawResult(status: proc.terminationStatus, stdout: raw, truncated: trunc))
            }
        }
    }

    static func run(command: String) async -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "ok: shell (empty, skipped)" }
        let r = await runRaw(command: trimmed)
        let header = r.status == 0 ? "ok: shell exit 0" : "error: shell exit \(r.status)"
        return r.truncated.isEmpty ? header : "\(header)\n\(r.truncated)"
    }

    // Execute a binary directly with an explicit argument array. NO shell is
    // involved, so caller-supplied arguments (URLs, config values) cannot be
    // interpreted as shell syntax. Use this instead of runRaw whenever any
    // argument comes from external/untrusted data.
    @discardableResult
    static func runArgs(_ launchPath: String, _ args: [String], timeoutSeconds: Int = 30) async -> RawResult {
        return await withCheckedContinuation { (cont: CheckedContinuation<RawResult, Never>) in
            let proc = Process()
            proc.launchPath = launchPath
            proc.arguments = args
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            do {
                try proc.run()
            } catch {
                cont.resume(returning: RawResult(status: -1, stdout: "failed to launch \(launchPath) - \(error.localizedDescription)", truncated: ""))
                return
            }
            let deadline = DispatchTime.now() + .seconds(timeoutSeconds)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: deadline) {
                if proc.isRunning { proc.terminate() }
            }
            DispatchQueue.global(qos: .utility).async {
                proc.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let raw = String(data: data, encoding: .utf8) ?? ""
                let trunc: String = raw.count <= 4000 ? raw
                    : String(raw.prefix(4000)) + "\n…(truncated, \(raw.count) chars total)"
                cont.resume(returning: RawResult(status: proc.terminationStatus, stdout: raw, truncated: trunc))
            }
        }
    }
}

// Runs an AppleScript source string; returns its string result or a
// formatted error message (no throw).
enum AppleScriptRunner {
    static func run(source: String) -> String {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "ok: applescript (empty, skipped)" }
        guard let script = NSAppleScript(source: trimmed) else {
            return "error: could not compile AppleScript"
        }
        var err: NSDictionary?
        let result = script.executeAndReturnError(&err)
        if let err = err {
            let msg = (err[NSAppleScript.errorMessage] as? String) ?? "unknown error"
            let num = (err[NSAppleScript.errorNumber] as? Int).map { " (\($0))" } ?? ""
            return "error: applescript failed\(num) - \(msg)"
        }
        let str = result.stringValue ?? ""
        return str.isEmpty ? "ok: applescript" : "ok: \(str)"
    }
}
