import Foundation
import GruxShellCore

// MARK: - Shell recovery tools (chat)
//
// Three tools that let chat answer the starter chips built from this Mac:
//
//   shell_audit_log         reads Grux's own audit log, nothing else. Read-only.
//   shell_snapshots         lists the snapshots `grux undo` can restore. Read-only.
//   shell_restore_snapshot  restores one, through the SAME restore path `grux undo` uses,
//                           and only after a tap in Approvals (JaxToolGate.evaluate).
//
// All three are named `shell_` so ToolRelevance files them under the developer group and
// they stay out of the Grux Local trained-tool contract, which covers core tools only.

enum ShellRecoveryTools {

    static let auditTool = "shell_audit_log"
    static let listTool = "shell_snapshots"
    static let restoreTool = "shell_restore_snapshot"
    static let names: Set<String> = [auditTool, listTool, restoreTool]

    /// The snapshot store to read, nil for the real one. Tests bind a temp directory, so no
    /// test lists or restores the operator's own repositories.
    @TaskLocal static var supportDir: String?
    /// The audit log to read, nil for `ShellAuditLog.logURL`. Tests only.
    @TaskLocal static var auditURL: URL?

    static let daysBack = 7
    static let maxLines = 200
    static let defaultLines = 50
    static let maxListed = 20
    /// How much of the log is read, from its end. A log nothing rotates can be any size.
    static let maxReadBytes: UInt64 = 4 * 1_048_576
    /// How long a reply may get before it is cut, so one call cannot flood the context.
    static let maxReplyChars = 16_000

    static func claudeTools() -> [ClaudeTool] {
        [
            ClaudeTool(
                name: auditTool,
                description: "Read Grux's own audit log: every shell command Grux ran and every file read, with refusals and why. Use for 'what did you run today', 'why did you refuse X'. Read-only. Reads one file and takes no path. At most \(daysBack) days back.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "day": ["type": "string", "description": "today (default), yesterday, or a date like 2026-09-27, at most \(daysBack) days back."],
                        "outcome": ["type": "string", "description": "all (default), refused (blocked or denied), or one outcome: ok, blocked, gated, error, denied_allowlist, denied_denylist, denied_rate, denied_missing, denied_secret."],
                        "limit": ["type": "integer", "description": "Lines to return, newest first. Default \(defaultLines), at most \(maxLines)."],
                    ],
                ]
            ),
            ClaudeTool(
                name: listTool,
                description: "List the shell snapshots Grux can restore, newest first: the ones taken before a destructive command and at the start of each request, from the last \(daysBack) days, at most \(maxListed). Read-only. Use before shell_restore_snapshot to find the id for 'undo X from 5:43 PM'.",
                inputSchema: ["type": "object", "properties": [String: Any]()]
            ),
            ClaudeTool(
                name: restoreTool,
                description: "Put a folder back to a snapshot from shell_snapshots. Files changed since are restored and files made since are removed. Always waits for the person's yes in Approvals before it runs.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "snapshot_id": ["type": "string", "description": "An id from shell_snapshots, like s3-1a2b3c4."],
                    ],
                    "required": ["snapshot_id"],
                ]
            ),
        ]
    }

    static func dispatch(name: String, input: [String: Any]) async -> String {
        switch name {
        case auditTool: return auditLog(input: input)
        case listTool: return await listSnapshots(input: input)
        case restoreTool: return await restore(input: input)
        default: return "error: unknown tool \(name)"
        }
    }

    // MARK: - shell_audit_log

    static let knownOutcomes: Set<String> = ["ok", "blocked", "gated", "error", "denied_allowlist",
                                             "denied_denylist", "denied_rate", "denied_missing",
                                             "denied_secret"]

    static func auditLog(input: [String: Any], now: Date = Date(), calendar: Calendar = .current,
                         home: String = NSHomeDirectory()) -> String {
        // NO PATH, EVER. The tool reads one file. A caller that names a path or anything
        // else is told so, rather than having the argument silently dropped.
        let allowed: Set<String> = ["day", "outcome", "limit"]
        let extra = input.keys.filter { !$0.hasPrefix("__") && !allowed.contains($0) }.sorted()
        guard extra.isEmpty else {
            return "refused: \(auditTool) reads one file, Grux's own audit log, and takes only day, outcome "
                + "and limit. It does not take \(extra.joined(separator: ", "))."
        }

        let dayRaw = ((input["day"] as? String) ?? "today").trimmingCharacters(in: .whitespaces).lowercased()
        guard let day = resolveDay(dayRaw, now: now, calendar: calendar) else {
            return "refused: the day must be today, yesterday, or a date like 2026-09-27 within the last "
                + "\(daysBack) days, and \(dayRaw) is not."
        }

        let outcomeRaw = ((input["outcome"] as? String) ?? "all").trimmingCharacters(in: .whitespaces).lowercased()
        let wanted: Set<String>?
        switch outcomeRaw {
        case "all", "": wanted = nil
        case "refused": wanted = ChatStarterChips.refusalOutcomes
        case let one where knownOutcomes.contains(one): wanted = [one]
        default:
            return "refused: there is no outcome called \(outcomeRaw). Use all, refused, or one of "
                + knownOutcomes.sorted().joined(separator: ", ") + "."
        }

        let limit: Int
        switch input["limit"] {
        case nil: limit = defaultLines
        case let n as Int: limit = max(1, n)
        // A JSON number can arrive as a Double, and Int(1e30) traps, so only an exact,
        // representable value is taken.
        case let d as Double where d.isFinite: limit = max(1, Int(exactly: d.rounded(.down)) ?? Int.max)
        default: return "refused: limit is a number of lines, at most \(maxLines)."
        }
        guard limit <= maxLines else {
            return "refused: a read is at most \(maxLines) lines, and \(limit) were asked for."
        }

        guard let url = auditURL ?? ShellAuditLog.logURL else {
            return "ok: there is no audit log on this Mac yet, so nothing has run or been refused."
        }
        let tail = readTail(url: url, maxBytes: maxReadBytes)
        guard let text = tail.text else {
            return "ok: there is no audit log on this Mac yet, so nothing has run or been refused."
        }

        struct Line: Decodable { var ts: String; var tool: String; var path: String; var outcome: String; var reason: String? }
        let decoder = JSONDecoder()
        var matched: [(Date, Line)] = []
        var shellRan = 0
        for raw in text.split(separator: "\n").reversed() {
            guard let line = try? decoder.decode(Line.self, from: Data(raw.utf8)),
                  let at = ChatStarterChips.parseTimestamp(line.ts) else { continue }
            if at < day { break }
            guard calendar.isDate(at, inSameDayAs: day) else { continue }
            if line.tool.hasPrefix("shell_run"), line.outcome == "ok" { shellRan += 1 }
            if wanted.map({ $0.contains(line.outcome) }) ?? true { matched.append((at, line)) }
        }

        let dayName = calendar.isDate(day, inSameDayAs: now) ? "today"
            : ChatStarterChips.whenText(day, now: now, calendar: calendar).components(separatedBy: " at ").first ?? dayRaw
        var out = "ok: \(matched.count) line\(matched.count == 1 ? "" : "s") \(dayName)"
            + (wanted == nil ? "" : " with outcome \(outcomeRaw)")
            + ", \(shellRan) shell command\(shellRan == 1 ? "" : "s") ran ok \(dayName)."
        if matched.count > limit { out += " Showing the newest \(limit)." }
        if let full = tail.fullSize {
            out += " Only the last \(maxReadBytes / 1_048_576) MB of a \(full / 1_048_576) MB log was read, "
                + "so older lines are not counted."
        }
        // EVERY FIELD SCRUBBED, ONE AT A TIME. A command is the likeliest place for a token,
        // and redacting an assembled line instead would let the scrubber's neighbour rule
        // mistake Grux's own words for a credential.
        func clean(_ s: String) -> String { ChatStarterChips.shortenHome(ShellOutputGuard.redact(s), home: home) }
        for (at, line) in matched.prefix(limit) {
            var row = "\n\(TodayModel.clock(at, calendar: calendar)) \(clean(line.tool)) \(clean(line.outcome)): \(clean(line.path))"
            if let reason = line.reason, !reason.isEmpty { row += " (\(clean(reason)))" }
            if out.count + row.count > maxReplyChars {
                out += "\n(cut at \(maxReplyChars) characters; ask for fewer lines or one outcome)"
                break
            }
            out += row
        }
        return out
    }

    /// Start of the asked-for day, or nil when it is not a day within reach.
    static func resolveDay(_ raw: String, now: Date, calendar: Calendar) -> Date? {
        let today = calendar.startOfDay(for: now)
        let day: Date?
        switch raw {
        case "today", "": day = today
        case "yesterday": day = calendar.date(byAdding: .day, value: -1, to: today)
        default:
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = calendar.timeZone
            f.dateFormat = "yyyy-MM-dd"
            day = f.date(from: raw).map { calendar.startOfDay(for: $0) }
        }
        guard let day, day <= today,
              let back = calendar.dateComponents([.day], from: day, to: today).day, back <= daysBack else { return nil }
        return day
    }

    /// The last `maxBytes` of a file, starting at a line boundary. `fullSize` is set when the
    /// file was bigger and only its end was read. Nil text when there is no file.
    static func readTail(url: URL, maxBytes: UInt64) -> (text: String?, fullSize: UInt64?) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return (nil, nil) }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return (nil, nil) }
        let start = size > maxBytes ? size - maxBytes : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd() else { return ("", nil) }
        var text = String(decoding: data, as: UTF8.self)
        if start > 0, let nl = text.firstIndex(of: "\n") { text = String(text[text.index(after: nl)...]) }
        return (text, start > 0 ? size : nil)
    }

    // MARK: - shell_snapshots

    struct Listed: Equatable, Sendable {
        let id: String
        let at: Date
        let folder: String
        let label: String
        /// Taken right before a destructive command, the kind the undo chip names.
        let beforeDestructive: Bool
    }

    /// What chat may restore: in the snapshot store, restorable, from the last 7 days, and in
    /// a folder Grux may still work in. One predicate for the list, the restore and the chip.
    static func restorable(now: Date = Date()) async -> [Listed] {
        let sessions = await ShellSnapshotIndex.sessions(supportDir: supportDir)
        var out: [Listed] = []
        for session in sessions where session.isRestorable {
            guard let root = session.rootDir, mayRestore(root: root) else { continue }
            for r in session.snapshots where now.timeIntervalSince(r.createdAt) <= Double(daysBack) * 86_400 {
                out.append(Listed(id: r.snapshotId, at: r.createdAt, folder: root, label: r.label,
                                  beforeDestructive: r.trigger == "destructive-detect"
                                      || r.label.hasPrefix(ChatStarterChips.destructiveLabelPrefix)))
            }
        }
        // The ones before a destructive command first, so the snapshot the undo chip names
        // is always inside the listed 20 however many request baselines came after it.
        return out.sorted { ($0.beforeDestructive ? 1 : 0, $0.at) > ($1.beforeDestructive ? 1 : 0, $1.at) }
    }

    /// A folder chat may put back: one the person still lets Grux work in. A folder they have
    /// since taken off that list is no longer Grux's to rewrite from chat; `grux undo` at a
    /// terminal still can.
    static func mayRestore(root: String) -> Bool {
        ShellAllowlist.isInsideAllowedRoot(root)
    }

    static func listSnapshots(input: [String: Any], now: Date = Date(), calendar: Calendar = .current,
                              home: String = NSHomeDirectory()) async -> String {
        let extra = input.keys.filter { !$0.hasPrefix("__") }.sorted()
        guard extra.isEmpty else {
            return "refused: \(listTool) reads only Grux's own snapshot store and takes no arguments. "
                + "It does not take \(extra.joined(separator: ", "))."
        }
        let all = await restorable(now: now)
        guard !all.isEmpty else {
            return "ok: no snapshot from the last \(daysBack) days can be restored from chat."
        }
        var out = "ok: \(all.count) snapshot\(all.count == 1 ? "" : "s") from the last \(daysBack) days"
            + (all.count > maxListed ? ", showing \(maxListed)" : "")
            + ", the ones taken before a destructive command first, then newest first."
        for s in all.prefix(maxListed) {
            // The id is Grux's own and printed as is; the label carries the raw command and the
            // folder a person's path, so those two are scrubbed, each on its own.
            let label = ChatStarterChips.shortenHome(ShellOutputGuard.redact(s.label), home: home)
            let folder = ChatStarterChips.shortenHome(ShellOutputGuard.redact(s.folder), home: home)
            out += "\n\(s.id) | \(ChatStarterChips.whenText(s.at, now: now, calendar: calendar)) | \(folder) | \(label)"
        }
        return out
    }

    // MARK: - shell_restore_snapshot

    enum Preflight {
        case action(ProposedAction)
        case refused(String)
    }

    /// Runs inside the gate, BEFORE anything is queued: refuses an id that is not a snapshot
    /// id or not one chat may restore, and otherwise builds the card a person reads, naming
    /// the folder and the time. It never restores; that happens only after the tap.
    static func preflight(input: [String: Any], now: Date = Date(), calendar: Calendar = .current,
                          home: String = NSHomeDirectory()) async -> Preflight {
        let id = ((input["snapshot_id"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard GruxControlTools.isSnapshotId(id) else {
            return .refused("\(id.isEmpty ? "An empty id" : "That") is not a snapshot id. Snapshot ids look like "
                            + "s3-1a2b3c4; \(listTool) lists them.")
        }
        guard let hit = await restorable(now: now).first(where: { $0.id == id }) else {
            return .refused("No snapshot called \(id) can be restored from chat: it is not in Grux's snapshot "
                            + "store, it is older than \(daysBack) days, or its folder is gone or no longer "
                            + "one Grux may work in. \(listTool) lists the ones that can.")
        }
        let folder = ChatStarterChips.shortenHome(hit.folder, home: home)
        let when = ChatStarterChips.whenText(hit.at, now: now, calendar: calendar)
        // The command stays OFF the card text: the gate reads it for words like "publish" and
        // would refuse a restore because of what the destroyed command said.
        return .action(ProposedAction(
            kind: .other,
            summary: "Put \(folder) back to how it was at \(when) (snapshot \(id)). Files changed since are "
                + "restored and files made since are removed.",
            target: restoreTool,
            detail: ["tool": restoreTool, "snapshot_id": id]))
    }

    static func restore(input: [String: Any]) async -> String {
        // Re-checked after the tap: the folder or the store may have changed while the card
        // waited, and a restore runs only on what is restorable now.
        switch await preflight(input: input) {
        case .refused(let reason): return "refused: \(reason) Nothing was changed."
        case .action: break
        }
        let id = ((input["snapshot_id"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // The same Touch ID gate a confirmed dangerous shell command passes, when it is on.
        guard await SensitiveActionGate.shared.authorize(.shellDangerous, reason: "restore shell snapshot \(id)") else {
            return "refused: Touch ID authorization was refused, so nothing was changed."
        }
        switch await GruxControlTools.restoreSnapshot(snapshotId: id, supportDir: supportDir) {
        case .restored(let restoredTo, let changed, _, _):
            let files = changed.isEmpty ? "No file had changed since then."
                : "Files put back or removed: " + changed.prefix(20).map { ShellOutputGuard.redact($0) }
                    .joined(separator: ", ") + (changed.count > 20 ? ", and \(changed.count - 20) more." : ".")
            return "ok: restored to snapshot \(restoredTo). \(files)"
        case .refused(let reason):
            // The shared path points a terminal at grux_shell_snapshots; chat has its own.
            return "refused: " + reason.replacingOccurrences(of: "grux_shell_snapshots", with: listTool)
                + " Nothing was changed."
        }
    }
}
