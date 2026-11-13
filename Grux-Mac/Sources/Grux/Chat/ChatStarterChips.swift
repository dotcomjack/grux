import Foundation
import GruxShellCore

/// What this Mac actually holds, as the starter chips see it.
///
/// A plain value, gathered off the view by `ChatStarterChips.gather` and handed to the pure
/// `ChatStarterChips.build`, so every rule can be driven by a test without SwiftUI, EventKit,
/// Ollama or the person's own logs.
struct MacStarterState: Equatable, Sendable {
    struct Snapshot: Equatable, Sendable {
        var at: Date
        var command: String
        /// The work tree the snapshot covers.
        var folder: String
    }
    struct Refusal: Equatable, Sendable {
        var at: Date
        /// The audit line's `path`: a command for the shell, a path for the file tools.
        var target: String
        var reason: String
    }
    struct Meeting: Equatable, Sendable {
        var at: Date
        var title: String
    }
    struct Window: Equatable, Sendable {
        var app: String
        var title: String
    }

    var lastDestructiveSnapshot: Snapshot? = nil
    var lastRefusal: Refusal? = nil
    var commandsToday = 0
    var calendarAccess = false
    var nextMeeting: Meeting? = nil
    var screenRecording = false
    var frontWindow: Window? = nil
    /// Nil is UNKNOWN, not none: Ollama is installed and not answering, so its models may be
    /// sitting on disk. Setup is offered only on a positive none.
    var localModelSetUp: Bool? = false
    var memoryGB: Int? = nil

    /// Whether chat itself can act on the chip, which is a separate question from whether the
    /// fact exists. A chip is sent verbatim into a fresh thread, so a snapshot chat cannot
    /// restore, or a log chat cannot read, is an action that cannot work right now.
    var chatCanRestoreSnapshots = ChatStarterChips.chatCanRestoreSnapshots
    var chatCanReadAuditLog = ChatStarterChips.chatCanReadAuditLog
    /// Whether chat is routed to a local model (ChatService.isLocalTurn). A local model gets
    /// the recovery tools in its slots for a chip's ask, and does not use them reliably yet
    /// (measured 2026-11-12, Grux Local 2b), so the three shell chips are not offered there.
    var chatOnLocalModel = false
}

/// The chat empty state's suggestions, built from this Mac's real state, never a stock list.
///
/// NEVER OFFER AN ACTION THAT CANNOT WORK RIGHT NOW. A rule whose input is missing is skipped,
/// and the skip carries its reason, so a test can assert why a chip is absent rather than only
/// that it is.
enum ChatStarterChips {

    static let maxChips = 3

    /// Whether chat has the tool each fact needs, and each one names its wire.
    ///
    /// The undo chip is answered by `shell_snapshots` (find the id) and
    /// `shell_restore_snapshot` (restore it after a tap in Approvals), and the refusal and
    /// today chips by `shell_audit_log` (`ShellRecoveryTools`). Set one false and its chips go
    /// dark with that reason, which is what they did before those tools existed.
    ///
    /// The setup chips (Grux Local and the two unlocks) need no switch: chat has no tool that
    /// grants a permission or pulls a model, but the reply they ask for is a walk through the
    /// one step, and chat's capability block (`FeatureRegistry.systemPromptBlock`) names every
    /// missing piece.
    static let chatCanRestoreSnapshots = true
    static let chatCanReadAuditLog = true

    enum Rule: String, Sendable {
        case undo, refusal, meeting, window, today, local, cap
    }

    struct Chip: Equatable, Sendable {
        /// Sent VERBATIM as the person's first message, so it reads as something they type.
        let ask: String
        let because: String
    }

    struct Skip: Equatable, Sendable {
        let rule: Rule
        let reason: String
    }

    struct Result: Equatable, Sendable {
        let chips: [Chip]
        let skipped: [Skip]
        func reason(_ rule: Rule) -> String? { skipped.first { $0.rule == rule }?.reason }
    }

    private enum Pick { case chip(Chip), skip(String) }

    // MARK: - The rules

    static func build(_ s: MacStarterState,
                      now: Date = Date(),
                      calendar: Calendar = .current,
                      home: String = NSHomeDirectory()) -> Result {
        var chips: [Chip] = []
        var skipped: [Skip] = []
        func take(_ rule: Rule, _ pick: Pick) {
            switch pick {
            case .chip(let c): chips.append(c)
            case .skip(let reason): skipped.append(Skip(rule: rule, reason: reason))
            }
        }
        let when = { (d: Date) in whenText(d, now: now, calendar: calendar) }
        let localModel = "chat runs on a local model here, and a local model does not use Grux's shell tools reliably yet"

        take(.undo, {
            guard s.chatCanRestoreSnapshots else {
                return .skip("chat has no tool to restore a snapshot by its id yet")
            }
            guard !s.chatOnLocalModel else { return .skip(localModel) }
            guard let snap = s.lastDestructiveSnapshot,
                  now.timeIntervalSince(snap.at) <= 7 * 86_400 else {
                return .skip("no destructive command has run in the last 7 days, so there is nothing to undo")
            }
            let cmd = short(shortenHome(snap.command, home: home), 34)
            return .chip(Chip(ask: "Undo `\(cmd)` from \(when(snap.at))",
                              because: "a snapshot of \(shortenHome(snap.folder, home: home)) was taken right before it ran"))
        }())

        take(.refusal, {
            guard s.chatCanReadAuditLog else { return .skip("chat cannot read the audit log yet") }
            guard !s.chatOnLocalModel else { return .skip(localModel) }
            guard let r = s.lastRefusal, now.timeIntervalSince(r.at) <= 7 * 86_400 else {
                return .skip("nothing has been refused in the last 7 days")
            }
            return .chip(Chip(ask: "Why did you refuse `\(short(shortenHome(r.target, home: home), 28))`?",
                              because: "the log has the refusal from \(when(r.at)): \(shortenHome(r.reason, home: home))"))
        }())

        take(.meeting, {
            guard s.calendarAccess else { return .skip("Calendar is not connected") }
            guard let m = s.nextMeeting, m.at > now, calendar.isDate(m.at, inSameDayAs: now) else {
                return .skip("no meeting left on the calendar today")
            }
            return .chip(Chip(ask: "Prep me for \(short(m.title, 40)) at \(TodayModel.clock(m.at, calendar: calendar))",
                              because: "it is the next meeting on your calendar"))
        }())

        take(.window, {
            guard s.screenRecording else {
                return .skip("Screen Recording is not granted, so Grux cannot see the window you are in")
            }
            guard let w = s.frontWindow, !w.app.isEmpty, !w.title.isEmpty else {
                return .skip("the window you were in has no title Grux may read")
            }
            return .chip(Chip(ask: "What is wrong in \(w.app): \(short(w.title, 26))?",
                              because: "that is the window you are in"))
        }())

        take(.today, {
            guard s.chatCanReadAuditLog else { return .skip("chat cannot read the audit log yet") }
            guard !s.chatOnLocalModel else { return .skip(localModel) }
            guard s.commandsToday > 0 else { return .skip("no command has run today") }
            let n = s.commandsToday
            return .chip(Chip(ask: "What did you run today? (\(n) command\(n == 1 ? "" : "s"))",
                              because: "every one is in the plain text log"))
        }())

        take(.local, {
            guard let setUp = s.localModelSetUp else {
                return .skip("Ollama is installed but not answering, so whether a local model is set up is unknown")
            }
            guard !setUp else { return .skip("a local model is already set up") }
            guard let gb = s.memoryGB else { return .skip("this Mac's memory is unknown") }
            guard let fit = localSize(memoryGB: gb) else {
                return .skip("no Grux Local size is made for a Mac under 8 GB")
            }
            return .chip(Chip(ask: "Set up Grux Local \(fit.label) for this Mac's \(gb) GB",
                              because: "no local model yet, and the \(fit.label) is the size for Macs with \(fit.floor) GB and up"))
        }())

        // A thin Mac has little to work from. Empty slots go to the setup step that unlocks a
        // rule, keyed on the PERMISSION, not on the skip: a Mac with Calendar connected and no
        // meeting today must never be told to connect its calendar.
        if chips.count < maxChips, !s.screenRecording {
            chips.append(Chip(ask: "Let Grux see the window I am in",
                              because: "Screen Recording unlocks asks about whatever is on screen"))
        }
        if chips.count < maxChips, !s.calendarAccess {
            chips.append(Chip(ask: "Connect my calendar",
                              because: "your next meeting becomes something to prep for"))
        }

        for extra in chips.dropFirst(maxChips) {
            skipped.append(Skip(rule: .cap, reason: "only \(maxChips) chips: \(extra.ask)"))
        }
        return Result(chips: Array(chips.prefix(maxChips)), skipped: skipped)
    }

    // MARK: - Helpers, pure

    /// The Grux Local size for this memory, from the same table the installer uses
    /// (`FileNamingRoute.idealGruxLocalTag`), so the chip never names a size the setup would
    /// not pull. Under 8 GB nothing is offered: the 2B is made for 8 GB Macs.
    static func localSize(memoryGB gb: Int) -> (label: String, floor: Int)? {
        guard gb >= 8 else { return nil }
        let tag = FileNamingRoute.idealGruxLocalTag(memoryGB: Double(gb))
        let label = String(tag.split(separator: ":").last ?? "").uppercased()
        let floors = ["2B": 8, "4B": 16, "9B": 24]
        guard let floor = floors[label] else { return nil }
        return (label, floor)
    }

    /// `5:43 PM` today, `Monday at 5:43 PM` within the last 6 days, `Sep 20 at 5:43 PM` before
    /// that, so a bare weekday never names last week's day. Never a 24 hour clock: the time
    /// comes from `TodayModel.clock`, the app's one formatter.
    static func whenText(_ date: Date, now: Date, calendar: Calendar) -> String {
        let clock = TodayModel.clock(date, calendar: calendar)
        if calendar.isDate(date, inSameDayAs: now) { return clock }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day ?? 99
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = calendar.timeZone
        f.dateFormat = (1...6).contains(days) ? "EEEE" : "MMM d"
        return f.string(from: date) + " at " + clock
    }

    /// Home paths read as `~`, inside a command as well as on their own.
    static func shortenHome(_ text: String, home: String) -> String {
        guard !home.isEmpty, home != "/" else { return text }
        if text == home { return "~" }
        return text.replacingOccurrences(of: home + "/", with: "~/")
    }

    static func short(_ text: String, _ n: Int) -> String {
        text.count <= n ? text
            : String(text.prefix(n - 1)).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }

    // MARK: - Reading the real sources, pure

    /// Outcomes in the audit log that mean Grux REFUSED. `error` (the command ran and failed),
    /// `denied_missing` (the file is not there) and `gated` (held for a confirmation the person
    /// usually gives a moment later) are not refusals, and asking "why did you refuse" about
    /// any of them would be a false question.
    static let refusalOutcomes: Set<String> = ["blocked", "denied_allowlist", "denied_denylist",
                                               "denied_rate", "denied_secret"]

    /// The latest refusal in the last 7 days and today's count of shell commands Grux ran,
    /// from the text of `fs-audit.log`. Read newest first and stopped at the first line older
    /// than 7 days, so a log that is never rotated costs a week of lines, not its whole life.
    /// A line that will not parse is skipped, as `grux history` does: a process killed
    /// mid-write leaves a torn last line.
    static func auditFacts(_ text: String, now: Date,
                           calendar: Calendar) -> (lastRefusal: MacStarterState.Refusal?, commandsToday: Int) {
        struct Line: Decodable { var ts: String; var tool: String; var path: String; var outcome: String; var reason: String? }
        let decoder = JSONDecoder()
        var refusal: MacStarterState.Refusal?
        var today = 0
        for raw in text.split(separator: "\n").reversed() {
            guard let line = try? decoder.decode(Line.self, from: Data(raw.utf8)),
                  let at = parseTimestamp(line.ts) else { continue }
            let isToday = calendar.isDate(at, inSameDayAs: now)
            if isToday, line.tool.hasPrefix("shell_run"), line.outcome == "ok" { today += 1 }
            if refusal == nil, refusalOutcomes.contains(line.outcome),
               now.timeIntervalSince(at) <= 7 * 86_400 {
                let reason = line.reason ?? ""
                refusal = .init(at: at, target: line.path, reason: reason.isEmpty ? "refused" : reason)
            }
            // Newest first: once a refusal is known and the lines are older than today,
            // nothing further back can change either answer, and nothing past a week can.
            if refusal != nil, at < calendar.startOfDay(for: now) { break }
            if now.timeIntervalSince(at) > 7 * 86_400 { break }
        }
        return (refusal, today)
    }

    /// The log writes `2026-08-28T19:33:09.596Z`; older lines carry no fraction. Built once:
    /// a formatter per line is the expensive part of reading a log.
    nonisolated(unsafe) private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let withoutFraction = ISO8601DateFormatter()

    static func parseTimestamp(_ ts: String) -> Date? {
        withFraction.date(from: ts) ?? withoutFraction.date(from: ts)
    }

    /// One snapshot as the index reports it, flattened so the choice is testable without a
    /// shadow repository on disk.
    struct SnapshotRow: Sendable {
        var folder: String?
        var restorable: Bool
        var trigger: String
        var label: String
        var createdAt: Date
    }

    static let destructiveLabelPrefix = "before destructive cmd #"

    /// The newest restorable snapshot taken before a destructive command in the last 7 days.
    /// Repositories written before trailers existed hydrate with trigger `unknown`, so the
    /// label is accepted as well.
    static func latestDestructive(_ rows: [SnapshotRow], now: Date) -> MacStarterState.Snapshot? {
        let hit = rows
            .filter { $0.restorable && $0.folder != nil
                && ($0.trigger == "destructive-detect" || $0.label.hasPrefix(destructiveLabelPrefix))
                && now.timeIntervalSince($0.createdAt) <= 7 * 86_400 }
            .max { $0.createdAt < $1.createdAt }
        guard let hit, let folder = hit.folder else { return nil }
        return .init(at: hit.createdAt, command: commandFromLabel(hit.label), folder: folder)
    }

    /// `before destructive cmd #1: find . -name x -delete` becomes `find . -name x -delete`.
    /// Redacted on the way out: the label holds the raw command, and the chip is shown and
    /// then sent as a message, so a token in it must not travel.
    static func commandFromLabel(_ label: String) -> String {
        guard label.hasPrefix(destructiveLabelPrefix),
              let colon = label.range(of: ": ") else { return ShellOutputGuard.redact(label) }
        return ShellOutputGuard.redact(String(label[colon.upperBound...]))
    }
}

// MARK: - Gathering, live

extension ChatStarterChips {

    /// This Mac's state right now. Every read here is cheap or awaited: the permission checks
    /// and the window title are synchronous system calls, the calendar read is one day of one
    /// store, Ollama is a loopback request, and the audit log and snapshot repositories are
    /// read off the main actor.
    @MainActor
    static func gather(now: Date = Date(), calendar: Calendar = .current) async -> MacStarterState {
        var s = MacStarterState()
        s.chatOnLocalModel = ChatService.isLocalTurn(
            providerOverride: PresetStore.shared.activeChatApplication()?.providerOverride,
            resolved: ModelRegistry.shared.resolvedProvider)
        s.memoryGB = Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded())

        s.screenRecording = ScreenCapturer.shared.hasPermission()
        if s.screenRecording {
            // The window the person was in, not Grux: Grux is in front while they read this.
            // Its title has already been through the capture privacy list.
            let w = WorkspaceObserver.shared.snapshot()
            if !w.lastNonGruxName.isEmpty, !w.lastNonGruxWindowTitle.isEmpty {
                s.frontWindow = .init(app: w.lastNonGruxName, title: w.lastNonGruxWindowTitle)
            }
        }

        // Full read access only. `CalendarService.hasAccess` is false for write-only access
        // and under XCTest, so the suite never reads the operator's diary.
        s.calendarAccess = CalendarService.shared.hasAccess
        if s.calendarAccess,
           let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) {
            s.nextMeeting = CalendarService.shared.events(from: now, to: end)
                .first { !$0.isAllDay && $0.start > now }
                .map { .init(at: $0.start, title: $0.title) }
        }

        s.localModelSetUp = await localModelSetUp()

        if s.chatCanReadAuditLog, let url = ShellAuditLog.logURL {
            // The same bounded tail the chat tool reads, so a log nothing rotates costs at
            // most its last few MB every tick, never its whole life.
            let facts = await Task.detached(priority: .utility) {
                auditFacts(ShellRecoveryTools.readTail(url: url, maxBytes: ShellRecoveryTools.maxReadBytes).text ?? "",
                           now: now, calendar: calendar)
            }.value
            s.lastRefusal = facts.lastRefusal
            s.commandsToday = facts.commandsToday
        }

        if s.chatCanRestoreSnapshots {
            s.lastDestructiveSnapshot = await lastDestructiveSnapshot(now: now)
        }
        return s
    }

    /// The newest snapshot before a destructive command that chat may restore, through the
    /// same predicate the list and the restore use (`ShellRecoveryTools.restorable`), so the
    /// chip never offers what the tool would refuse. Re-read only when the store changes:
    /// hydrating spawns git per repository, and this runs every 30 seconds.
    @MainActor
    static func lastDestructiveSnapshot(now: Date) async -> MacStarterState.Snapshot? {
        let signature = snapshotStoreSignature(ShellSnapshotIndex.defaultSupportDir())
        if signature != cachedSignature || cachedRows == nil {
            cachedRows = await Task.detached(priority: .utility) {
                await ShellRecoveryTools.restorable(now: now).map {
                    SnapshotRow(folder: $0.folder, restorable: true, trigger: "", label: $0.label, createdAt: $0.at)
                }
            }.value
            cachedSignature = signature
        }
        // The folder can vanish or leave the allowed list without the store changing.
        let live = (cachedRows ?? []).filter {
            guard let folder = $0.folder else { return false }
            return FileManager.default.fileExists(atPath: folder) && ShellRecoveryTools.mayRestore(root: folder)
        }
        return latestDestructive(live, now: now)
    }

    @MainActor private static var cachedSignature: String?
    @MainActor private static var cachedRows: [SnapshotRow]?

    /// Every shadow repository's name and the time its HEAD log last moved, which changes on
    /// every snapshot and every restore. Stat calls only.
    static func snapshotStoreSignature(_ dir: String) -> String {
        let fm = FileManager.default
        let entries = ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".git") }.sorted()
        return entries.map { entry -> String in
            let head = dir + "/" + entry + "/logs/HEAD"
            let path = fm.fileExists(atPath: head) ? head : dir + "/" + entry
            let at = (try? fm.attributesOfItem(atPath: path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return entry + "@" + String(at)
        }.joined(separator: ",")
    }

    /// True when Ollama answers and holds a model that runs on this Mac, false when Ollama is
    /// not installed or holds nothing local, nil when it is installed and not answering.
    @MainActor
    static func localModelSetUp(now: Date = Date()) async -> Bool? {
        let ollama = OllamaManager.shared
        // Never during a start or stop, which `refresh` could overwrite.
        if ollama.serverState == .starting || ollama.serverState == .stopping { return nil }
        // With no binary found, `refresh` runs `which` and waits on it on the main actor. Do
        // that at most once every 10 minutes, so a Mac without Ollama does not pay it every tick.
        // The server is still asked every tick: a remote or oddly installed Ollama answers
        // without a binary this Mac can find, and must not read as "no local model".
        if ollama.binaryPath == nil, let last = lastBinaryProbe, now.timeIntervalSince(last) < 600 {
            guard await ollama.isHealthy() else { return false }
            await ollama.refreshInstalled()
            return ollama.installedTags.contains { !FileNamingRoute.isCloudTag($0) }
        }
        if ollama.binaryPath == nil { lastBinaryProbe = now }
        await ollama.refresh()
        if ollama.serverState.isRunning {
            return ollama.installedTags.contains { !FileNamingRoute.isCloudTag($0) }
        }
        return ollama.binaryPath == nil ? false : nil
    }

    @MainActor private static var lastBinaryProbe: Date?
}
