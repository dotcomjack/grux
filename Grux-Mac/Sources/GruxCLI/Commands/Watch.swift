import ArgumentParser
import Foundation
import GruxSetupCore

// MARK: - grux watch

/// Follow a path and say what moved. A POLLER, and it says so on every screen it prints.
///
/// THERE IS NO ARBITRARY PATH WATCHER IN GRUX. The app subscribes to the handful of places
/// it owns and to nothing else, so this command has nothing to subscribe to: it stats the
/// tree on an interval and diffs two looks. Naming that in the help and in the output is not
/// modesty, it is the difference between a two second gap reading as normal and reading as a
/// missed change. Somebody who believes this is a file system event stream will conclude the
/// second one, and go hunting a bug that is not there.
///
/// It is also entirely local. It never opens the control socket, so it works with Grux
/// closed, it reads names, sizes and modification times rather than contents, and it writes
/// nothing at all.
struct Watch: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "watch",
        abstract: "Follow a file or a folder and report what changes. Reads only.",
        discussion: """
            THIS POLLS. It stats the path every --interval seconds and prints what moved \
            between two looks. It is not a file system event stream, so a change is reported \
            up to one interval late, and a change made and undone between two looks is never \
            seen at all.

            It reads names, sizes and modification times. It never opens a file's contents, \
            it writes nothing, and it never talks to Grux, so it works with the app closed.

            Skipped inside a folder, because polling them every couple of seconds is how a \
            watcher burns a core: .git, node_modules, .build and DerivedData. Pass --all to \
            include them. The output always says which ones it walked past.

            Exit codes: 0 done, 1 no such path, a tree too big to follow honestly, or a \
            follow loop asked for where nothing is attached to the terminal.
            """)

    @Argument(help: "A file or a folder to follow.")
    var path: String?

    @Option(name: .long, help: "Seconds between looks. Default 2, and 0.2 is the floor.")
    var interval: Double = 2

    @Flag(name: .long, help: "One look, print it, stop. This is the one a script wants.")
    var once = false

    @Flag(name: .long, help: "Same as --once, because a follow loop cannot end on its own.")
    var noInput = false

    @Flag(name: .long, help: "Look inside .git, node_modules, .build and DerivedData too.")
    var all = false

    /// Walked past unless --all. Every one of these is large, machine written, and changes
    /// constantly for reasons nobody watching a source tree wants a row about.
    static let skipped = [".git", "node_modules", ".build", "DerivedData"]

    /// Above this the walk stops and the command refuses.
    ///
    /// A poller reads the WHOLE tree every interval. At some size that stops being a poll
    /// and becomes a background job with an interval it cannot keep, and a tool that quietly
    /// takes nine seconds to honour `--interval 2` is lying about its own latency.
    static let entryCap = 20_000

    /// The most rows the baseline prints before it summarises instead.
    static let baselineRows = 12

    // MARK: - What a stat can see

    struct Mark {
        let size: Int64
        let modified: Date
        let isFolder: Bool
        let isLink: Bool
    }

    struct Snapshot {
        var marks: [String: Mark] = [:]
        /// The names actually walked past, and how many folders that was. Distinct, because
        /// a tree with forty `node_modules` in it should say the name once.
        var skippedNames: Set<String> = []
        var skippedFolders = 0
        var overflowed = false

        var files: Int { marks.values.filter { !$0.isFolder }.count }
        var folders: Int { marks.values.filter(\.isFolder).count }
        var bytes: Int64 { marks.values.reduce(0) { $0 + ($1.isFolder ? 0 : $1.size) } }
        var newest: Date? { marks.values.map(\.modified).max() }
    }

    enum Kind {
        case added, changed, removed

        var glyph: String {
            switch self {
            case .added: return "+"
            case .changed: return "~"
            case .removed: return "-"
            }
        }

        var word: String {
            switch self {
            case .added: return "added"
            case .changed: return "changed"
            case .removed: return "removed"
            }
        }

        /// Removal is the one that costs somebody something, so it is the one that gets the
        /// attention colour. The glyph and the word carry the meaning without it.
        var ink: TerminalStyle.Ink { self == .removed ? .attention : .ok }
    }

    struct Change {
        let kind: Kind
        let name: String
        let detail: String
    }

    // MARK: - Run

    func run() throws {
        let frame = Frame()
        let r = frame.renderer
        let fm = FileManager.default

        // NOT EXIT 64. ArgumentParser's own missing-argument code is EX_USAGE, and this
        // surface documents 0, 1, 2 and 3, so an agent reading those four has nothing to do
        // with a fifth.
        guard let path, !path.isEmpty else {
            frame.open(.look)
            print(r.prose("Name a file or a folder to follow. This reads and reports, and "
                + "writes nothing anywhere."))
            print("")
            print("    " + r.style.ink(.accent, "grux watch ~/src/thing"))
            print("    " + r.style.ink(.accent, "grux watch ~/src/thing --once"))
            print("")
            print(r.style.ink(.dim, r.prose("--once takes one look and exits, which is what "
                + "--no-input maps onto.", indent: 2)))
            leave(.failed)
        }

        // Expanded here as well as by the shell, because a quoted "~/src" arrives literally
        // and failing on it would look like the folder is missing.
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .standardizedFileURL

        var isFolder: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isFolder) else {
            frame.open(.look)
            print(r.prose("Nothing at \(url.path)."))
            suggest(url, frame)
            leave(.failed)
        }

        // --no-input MAPS ONTO --once. A follow loop writes until something kills it, and in
        // a pipe there is nobody to press Ctrl-C, so the honest refusal names the flag that
        // would have answered instead of hanging forever.
        let single = once || noInput
        guard single || r.style.isTTY else {
            frame.open(.look)
            print(r.prose("Nothing is attached to this terminal, so a follow loop here would "
                          + "never end: pass --once for a single look and an exit code."))
            leave(.failed)
        }

        let asked = interval.isFinite ? interval : 2
        let every = max(0.2, asked)

        var previous = snapshot(url, isFolder: isFolder.boolValue)
        guard !previous.overflowed else {
            frame.open(.look)
            print(r.prose("More than \(grouped(Self.entryCap)) entries under \(url.path), "
                          + "which is more than this will walk."))
            print("")
            print(r.prose("A poller reads the whole tree every interval, so a tree this size "
                          + "cannot be followed at any interval you would want. Name a "
                          + "subfolder, or a single file.", indent: 2))
            leave(.failed)
        }

        // MARK: Baseline

        frame.open(.look, isFolder.boolValue
            ? "Following \(url.path) and everything under it."
            : "Following \(url.path).")

        let ordered = previous.marks.map { (name: $0.key, mark: $0.value) }
            .sorted {
                // NEWEST FIRST, ties broken CASE INSENSITIVELY. A plain `<` on a String is
                // an ASCII sort, which files every lowercase name after every uppercase one,
                // and a fresh checkout gives half a tree the same modification date.
                $0.mark.modified == $1.mark.modified
                    ? ($0.name.lowercased(), $0.name) < ($1.name.lowercased(), $1.name)
                    : $0.mark.modified > $1.mark.modified
            }

        let shown = Array(ordered.prefix(Self.baselineRows))
        // TWO DIFFERENT NUMBERS, AND CONFLATING THEM CLIPPED NAMES THAT FIT. `room` is what
        // the terminal has left once the glyph, the word, the size and the clock are paid
        // for. `nameWidth` is only the column the baseline lines up on, so a file added
        // later with a longer name pushes the dim columns right instead of losing its own
        // folder: measured, `src/Added.swift` rendered as `.../Added.swift` in an 88 column
        // terminal with 54 columns going spare.
        let room = max(12, r.style.width - 34)
        let nameWidth = min(max(12, shown.map { clip($0.name, r, room).count }.max() ?? 12),
                            room)

        if ordered.isEmpty {
            print(r.prose("It is empty. The first thing that appears in it gets a row."))
        } else {
            for entry in shown {
                print(r.row(state: .satisfied,
                            label: clip(entry.name, r, room),
                            detail: entry.mark.isFolder ? "folder" : size(entry.mark.size),
                            labelWidth: nameWidth))
            }
        }

        // NO CENSUS FOR A SINGLE FILE. The one row above already carries its name and its
        // size, and "1 file and 0 folders, 3 bytes between them" is three counts nobody
        // needed and one of them reads like a fault.
        if isFolder.boolValue, !ordered.isEmpty {
            print("")
            var counted: [String] = []
            if previous.files > 0 { counted.append(plural(previous.files, "file")) }
            if previous.folders > 0 { counted.append(plural(previous.folders, "folder")) }
            var census = r.list(counted)
            if previous.files > 0 {
                census += ", " + size(previous.bytes)
                    + (previous.files > 1 ? " between them" : "")
            }
            census += "."
            if ordered.count > shown.count {
                census += " Showing the \(shown.count) touched most recently."
            }
            print(r.prose(census))
        }

        if previous.skippedFolders > 0 {
            let names = previous.skippedNames.sorted { $0.lowercased() < $1.lowercased() }
            // The count of folders walked past, never a count of what is inside them:
            // counting those would mean walking them, which is the cost being avoided.
            let sentence = previous.skippedFolders == names.count
                ? "Did not look inside " + r.list(names) + "."
                : "Did not look inside " + plural(previous.skippedFolders, "folder")
                    + " named " + r.list(names) + "."
            print("")
            print(r.style.ink(.dim, r.prose(sentence + " Pass --all to include them.",
                                            indent: 2)))
        }

        if single {
            proveOneLook(frame, previous, watching: url.path, isFolder: isFolder.boolValue)
            leave(.done)
        }

        // MARK: Follow

        print("")
        var caveat = "Looking every \(seconds(every)). "
        if every != asked {
            caveat += "\(trim(asked)) is under the floor, which exists so a stray zero "
                    + "cannot spin a core. "
        }
        caveat += "This polls, so a change is reported up to one look late, and a change "
                + "made and undone between two looks is never seen."
        print(r.style.ink(.dim, r.prose(caveat, indent: 2)))
        print("")
        print(r.style.ink(.dim, r.prose("Ctrl-C to stop. Nothing here writes anything.",
                                        indent: 2)))
        print("")

        let ledger = Ledger()

        // CTRL-C ON A DISPATCH QUEUE, NOT IN A SIGNAL HANDLER. A signal handler may not take
        // a lock or print, and this one has to do both to render a summary. Ignoring SIGINT
        // first is what stops the default disposition from killing the process before the
        // source ever fires.
        signal(SIGINT, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        interrupt.setEventHandler {
            // No blank line first. The terminal has already echoed ^C, and `open` leads with
            // a newline of its own, so printing one here left two empty lines under it.
            proveFollowed(frame, ledger, watching: url.path)
            leave(.done)
        }
        interrupt.resume()

        while true {
            Thread.sleep(forTimeInterval: every)
            let now = Date()

            // THE TARGET ITSELF GOING AWAY IS ONE FACT, NOT FOUR HUNDRED. Diffing an empty
            // walk against the baseline would print a row per entry and bury the only line
            // that explains why.
            guard fm.fileExists(atPath: url.path) else {
                ledger.note(.removed)
                print(render(Change(kind: .removed, name: url.lastPathComponent,
                                    detail: "the watched path itself"),
                             r, nameWidth: nameWidth, room: room, time: stamp(now)))
                print("")
                print(r.prose("There is nothing left to follow."))
                proveFollowed(frame, ledger, watching: url.path)
                leave(.done)
            }

            let current = snapshot(url, isFolder: isFolder.boolValue)

            // A TRUNCATED WALK IS A PARTIAL SNAPSHOT, and diffing one reads as a mass
            // deletion of everything the walk did not reach.
            guard !current.overflowed else {
                print("")
                print(r.prose("This grew past \(grouped(Self.entryCap)) entries, which is "
                              + "more than a poller can read every \(seconds(every)). "
                              + "Stopping here rather than reporting a half walked tree as "
                              + "deletions."))
                proveFollowed(frame, ledger, watching: url.path)
                leave(.done)
            }

            let changes = diff(previous, current)
            if !changes.isEmpty {
                let time = stamp(now)
                for change in changes {
                    ledger.note(change.kind)
                    print(render(change, r, nameWidth: nameWidth, room: room, time: time))
                }
            }
            previous = current
        }
    }

    // MARK: - Looking

    private static let markKeys: Set<URLResourceKey> = [
        .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
    ]

    private func snapshot(_ root: URL, isFolder: Bool) -> Snapshot {
        var shot = Snapshot()
        guard isFolder else {
            if let m = mark(root) { shot.marks[root.lastPathComponent] = m }
            return shot
        }

        let skips = all ? Set<String>() : Set(Self.skipped)

        // THE RELATIVE NAME IS CARRIED DOWN, NEVER RECOVERED BY STRIPPING THE ROOT OFF A
        // FULL PATH. Measured: watching /tmp/watchdemo printed every row as
        // /private/tmp/watchdemo/src/App.swift, because `contentsOfDirectory` hands back
        // URLs with the symlink resolved and /tmp is a symlink to /private/tmp on every Mac.
        // The prefix comparison could not match, so a row that should read `src/App.swift`
        // read as an absolute path in a column sized for a file name.
        var pending: [(url: URL, name: String)] = [(root, "")]

        while let folder = pending.popLast() {
            guard let kids = try? FileManager.default.contentsOfDirectory(
                at: folder.url, includingPropertiesForKeys: Array(Self.markKeys),
                options: []) else { continue }

            for kid in kids {
                guard let m = mark(kid) else { continue }
                let leaf = kid.lastPathComponent
                if m.isFolder, skips.contains(leaf) {
                    shot.skippedNames.insert(leaf)
                    shot.skippedFolders += 1
                    continue
                }
                let name = folder.name.isEmpty ? leaf : folder.name + "/" + leaf
                shot.marks[name] = m
                if shot.marks.count > Self.entryCap {
                    shot.overflowed = true
                    return shot
                }
                // A SYMLINK IS NOT DESCENDED INTO. Two links pointing above each other is a
                // cycle, and a walker that follows one never comes back.
                if m.isFolder, !m.isLink { pending.append((kid, name)) }
            }
        }
        return shot
    }

    private func mark(_ url: URL) -> Mark? {
        guard let v = try? url.resourceValues(forKeys: Self.markKeys) else { return nil }
        return Mark(size: Int64(v.fileSize ?? 0),
                    modified: v.contentModificationDate ?? .distantPast,
                    isFolder: v.isDirectory ?? false,
                    isLink: v.isSymbolicLink ?? false)
    }

    private func diff(_ was: Snapshot, _ now: Snapshot) -> [Change] {
        var out: [Change] = []

        for (name, mark) in now.marks {
            guard let before = was.marks[name] else {
                out.append(Change(kind: .added, name: name,
                                  detail: mark.isFolder ? "folder" : size(mark.size)))
                continue
            }
            // A FOLDER'S MODIFICATION DATE MOVES WHENEVER A CHILD IS ADDED OR REMOVED, and
            // that child already has its own row. Reporting both prints one fact twice and
            // buries the name somebody is looking for under a stack of its parents.
            if mark.isFolder || before.isFolder { continue }
            guard mark.size != before.size || mark.modified != before.modified else { continue }

            let delta = mark.size - before.size
            let detail: String
            if delta > 0 { detail = "grew " + size(delta) }
            else if delta < 0 { detail = "shrank " + size(-delta) }
            else { detail = "touched, same size" }
            out.append(Change(kind: .changed, name: name, detail: detail))
        }

        for (name, mark) in was.marks where now.marks[name] == nil {
            out.append(Change(kind: .removed, name: name,
                              detail: mark.isFolder ? "folder" : "was " + size(mark.size)))
        }

        return out.sorted {
            ($0.name.lowercased(), $0.name) < ($1.name.lowercased(), $1.name)
        }
    }

    /// A close sibling of a name that is not there, so a typo does not end the conversation.
    private func suggest(_ url: URL, _ frame: Frame) {
        let r = frame.renderer
        let parent = url.deletingLastPathComponent()
        let typed = url.lastPathComponent

        guard let siblings = try? FileManager.default
                .contentsOfDirectory(atPath: parent.path) else {
            print("")
            print(r.prose("There is no folder at \(parent.path) either, so this is not a "
                          + "misspelling of the last part of the name.", indent: 2))
            return
        }

        // The same cutoff shape `Lookup.nearest` uses: scaled to what was typed, because a
        // fixed one suggests three unrelated names for every miss.
        let cutoff = max(2, typed.count / 3)
        let near = siblings
            .map { (name: $0, distance: Lookup.edits(typed.lowercased(), $0.lowercased())) }
            .filter { $0.distance <= cutoff }
            .sorted { ($0.distance, $0.name.lowercased()) < ($1.distance, $1.name.lowercased()) }
            .prefix(3)
            .map { $0.name }

        guard !near.isEmpty else { return }
        print("")
        print(r.prose("Did you mean " + r.list(near) + "?", indent: 2))
    }

    // MARK: - Drawing

    private func render(_ change: Change, _ r: Renderer,
                        nameWidth: Int, room: Int, time: String) -> String {
        let name = clip(change.name, r, room)
        let padded = name.count < nameWidth
            ? name + String(repeating: " ", count: nameWidth - name.count)
            : name
        var line = "  " + r.style.ink(change.kind.ink, change.kind.glyph) + " "
            + change.kind.word.padding(toLength: 7, withPad: " ", startingAt: 0)
            + "  " + padded
        // On a narrow terminal the size column is the first thing to go: the name and the
        // time are what make a stream of these readable, the byte count is the footnote.
        if !r.style.isNarrow, !change.detail.isEmpty {
            line += "  " + r.style.ink(.dim, change.detail)
        }
        return line + "  " + r.style.ink(.dim, time)
    }

    /// PROVE for `--once`: one look, and how old the newest thing in it is.
    private func proveOneLook(_ frame: Frame, _ shot: Snapshot,
                              watching: String, isFolder: Bool) {
        let r = frame.renderer
        frame.open(.prove)

        var answer = "One look at \(watching), taken just now."
        if let newest = shot.newest, newest > .distantPast {
            answer += isFolder
                ? " The most recently changed thing under it moved \(ago(newest))."
                : " It was last changed \(ago(newest))."
        }
        print(r.prose(answer))
        print("")
        print(r.style.ink(.dim, r.prose("Nothing was written and nothing was sent to Grux. "
                                        + "Drop --once to follow it instead.", indent: 2)))
    }
}

// MARK: - The tally

/// The running count, written by the loop and read by the Ctrl-C handler on another queue.
///
/// The handler runs on a dispatch queue rather than in a signal context exactly so it can
/// take this lock and print. A `signal()` handler may safely do neither.
private final class Ledger: @unchecked Sendable {
    private let lock = NSLock()
    private var added = 0
    private var changed = 0
    private var removed = 0
    let started = Date()

    func note(_ kind: Watch.Kind) {
        lock.lock()
        defer { lock.unlock() }
        switch kind {
        case .added: added += 1
        case .changed: changed += 1
        case .removed: removed += 1
        }
    }

    func read() -> (added: Int, changed: Int, removed: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (added, changed, removed)
    }
}

/// PROVE for a follow that has ended, however it ended.
///
/// The breakdown has to add up to the total in front of it. A summary whose parts disagree
/// with its own headline is worse than no summary, because it is the line somebody quotes.
private func proveFollowed(_ frame: Frame, _ ledger: Ledger, watching: String) {
    let r = frame.renderer
    let tally = ledger.read()
    let total = tally.added + tally.changed + tally.removed
    let lasted = spent(Date().timeIntervalSince(ledger.started))

    frame.open(.prove)
    if total == 0 {
        print(r.prose("Watched \(watching) for \(lasted). Nothing moved."))
    } else {
        var parts: [String] = []
        if tally.added > 0 { parts.append("\(tally.added) added") }
        if tally.changed > 0 { parts.append("\(tally.changed) changed") }
        if tally.removed > 0 { parts.append("\(tally.removed) removed") }
        print(r.prose("Watched \(watching) for \(lasted) and saw "
                      + plural(total, "change") + ": " + r.list(parts) + "."))
    }
    print("")
    print(r.style.ink(.dim, r.prose("Nothing was written and nothing was sent to Grux. This "
                                    + "command only ever read names, sizes and modification "
                                    + "times.", indent: 2)))
}

// MARK: - Words for numbers

private func plural(_ n: Int, _ word: String) -> String {
    "\(n) \(word)\(n == 1 ? "" : "s")"
}

/// `20,000`, never `20000`. Five unbroken digits in a sentence is a number somebody has to
/// count rather than read.
private func grouped(_ n: Int) -> String {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    return f.string(from: NSNumber(value: n)) ?? String(n)
}

private func size(_ bytes: Int64) -> String {
    let f = ByteCountFormatter()
    f.countStyle = .file
    f.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
    // `0` AND NOT "Zero bytes". ByteCountFormatter spells zero as a capitalised word by
    // default, and this string lands mid sentence: measured, an empty tree read
    // "2 files and 1 folder, Zero bytes between them."
    f.allowsNonnumericFormatting = false
    return f.string(fromByteCount: bytes)
}

/// `2` and `0.2`, never `2.0`, and never `0.20000000000000001`.
///
/// The guard is the whole reason this is three lines. `Int(_:)` TRAPS on a Double outside
/// Int64, and `--interval` takes whatever number the command line hands it, so
/// `grux watch . --interval 1e30` died here: measured, exit 5 with the baseline already on
/// screen and not one word after it. A number formatter has to be total, because the input
/// it formats came from a stranger.
private func trim(_ value: Double) -> String {
    guard value.magnitude < 1e15 else { return String(format: "%.2g", value) }
    return value == value.rounded() ? String(Int(value)) : String(format: "%.2g", value)
}

private func seconds(_ value: Double) -> String {
    trim(value) + (value == 1 ? " second" : " seconds")
}

private func spent(_ elapsed: TimeInterval) -> String {
    let total = max(0, Int(elapsed.rounded()))
    if total < 60 { return plural(total, "second") }
    let minutes = total / 60
    if minutes < 60 {
        return total % 60 == 0 ? plural(minutes, "minute") : "\(minutes)m \(total % 60)s"
    }
    return "\(minutes / 60)h \(minutes % 60)m"
}

/// How old, as a sentence. A bare timestamp makes the reader do the subtraction.
private func ago(_ date: Date) -> String {
    let elapsed = Date().timeIntervalSince(date)
    if elapsed < 0 { return "at \(stamp(date)), which is in the future" }
    if elapsed < 45 { return "moments ago" }
    if elapsed < 3600 { return plural(Int((elapsed / 60).rounded()), "minute") + " ago" }
    if elapsed < 86_400 { return plural(Int((elapsed / 3600).rounded()), "hour") + " ago" }

    let f = DateFormatter()
    f.dateFormat = "d MMM 'at' h:mm a"
    f.amSymbol = "AM"
    f.pmSymbol = "PM"
    return "on " + f.string(from: date)
}

/// Standard time. A database stores 24 hour time correctly and rendering it straight through
/// is the bug: nobody reading a terminal thinks in 19:33.
private func stamp(_ date: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "h:mm:ss a"
    f.amSymbol = "AM"
    f.pmSymbol = "PM"
    return f.string(from: date)
}

/// Clipped from the LEFT, which is the opposite of what `grux logs` does, and deliberately.
///
/// A log line carries its meaning at the front. A path carries it at the END: the file name
/// is the answer and the folders above it are context, so dropping the head keeps the part
/// somebody is reading for. Clipped only on a terminal, never in a pipe, because a machine
/// reading this wants the whole path and a truncated one silently loses a grep.
private func clip(_ text: String, _ r: Renderer, _ room: Int) -> String {
    guard r.style.isTTY, text.count > room else { return text }
    return "\u{2026}" + String(text.suffix(room - 1))
}
