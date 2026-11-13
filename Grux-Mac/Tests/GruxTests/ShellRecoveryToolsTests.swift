import XCTest
import GruxShellCore
@testable import Grux

/// The three chat tools behind the starter chips (`ShellRecoveryTools`): the audit log reader,
/// the snapshot list, and the snapshot restore that waits for a tap in Approvals.
///
/// Every test binds its own snapshot store, work folder and audit log in a temp directory
/// (`ShellRecoveryTools.$supportDir`, `$auditURL`), so nothing here reads or restores the
/// operator's own files.
@MainActor
final class ShellRecoveryToolsTests: XCTestCase {

    private var tmp: URL!
    private var work: URL!
    private var support: URL!
    private var savedRoots: Any?
    private var savedMode: AutonomyMode!
    private var savedJudge: (@MainActor (PendingApproval) async -> ApprovalRisk?)?
    private var queuedBefore: Set<UUID> = []

    let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()
    /// Sunday 2026-09-27, 8:00 PM Eastern (00:00Z on the 28th).
    var now: Date { ISO8601DateFormatter().date(from: "2026-09-28T00:00:00Z")! }

    override func setUp() async throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("grux-recovery-" + UUID().uuidString)
        work = tmp.appendingPathComponent("work")
        support = tmp.appendingPathComponent("support")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        // The folder Grux may work in, for this process only, put back afterwards.
        savedRoots = UserDefaults.standard.object(forKey: ShellAllowlist.watchedRootDefaultsKey)
        UserDefaults.standard.set(work.path, forKey: ShellAllowlist.watchedRootDefaultsKey)
        savedMode = AutonomyController.shared.mode
        savedJudge = ApprovalQueue.shared.judgeRisk
        ApprovalQueue.shared.judgeRisk = nil
        queuedBefore = Set(ApprovalQueue.shared.pending.map(\.id))
    }

    override func tearDown() async throws {
        for item in ApprovalQueue.shared.pending where !queuedBefore.contains(item.id) {
            ApprovalQueue.shared.skip(item.id)
        }
        ApprovalQueue.shared.judgeRisk = savedJudge
        AutonomyController.shared.setMode(savedMode)
        if let savedRoots { UserDefaults.standard.set(savedRoots, forKey: ShellAllowlist.watchedRootDefaultsKey) }
        else { UserDefaults.standard.removeObject(forKey: ShellAllowlist.watchedRootDefaultsKey) }
        try? FileManager.default.removeItem(at: tmp)
        // dispatchTool records each call as recent tool use, which pulls the developer
        // tools into every later turn in this process (measured: ToDoListAskTests lost
        // add_task from a lean local turn after this class ran). Leave none behind.
        RecentToolUse.shared.clear()
    }

    // MARK: - Fixtures

    /// A real shadow repository: `notes.txt` reads "original" at the snapshot and
    /// "destroyed" afterwards. Returns the snapshot id.
    private func seedSnapshot(session: String = "chat-session", root: URL? = nil) async throws -> String {
        let root = root ?? work!
        let store = ShellSnapshotStore(sessionId: session, rootDir: root.path, supportDir: support.path)
        try await store.ensureInitialized()
        try "original".write(to: root.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let snap = try await store.snapshot(label: "before destructive cmd #1: rm notes.txt",
                                            trigger: "destructive-detect", commandIndex: 1)
        try "destroyed".write(to: root.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        return snap.snapshotId
    }

    private var notes: String { (try? String(contentsOf: work.appendingPathComponent("notes.txt"), encoding: .utf8)) ?? "" }

    private func inStore<T>(_ body: () async throws -> T) async rethrows -> T {
        try await ShellRecoveryTools.$supportDir.withValue(support.path) { try await body() }
    }

    private func writeLog(_ text: String) throws -> URL {
        let url = tmp.appendingPathComponent("fs-audit.log")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func audit(_ input: [String: Any], log url: URL) -> String {
        ShellRecoveryTools.$auditURL.withValue(url) {
            ShellRecoveryTools.auditLog(input: input, now: now, calendar: cal, home: "/Users/tester")
        }
    }

    private static let log = """
    {"bytes":0,"outcome":"blocked","path":"touch proof.txt","reason":"strict mode: touch is not on the allowlist","resolved":"/tmp","tool":"shell_run_confirmed","ts":"2026-09-26T23:51:00.120Z"}
    {"bytes":10,"outcome":"ok","path":"ls","reason":"","resolved":"/tmp","tool":"shell_run_confirmed","ts":"2026-09-27T13:00:00.500Z"}
    {"bytes":10,"outcome":"ok","path":"/Users/tester/a.txt","reason":"","resolved":"/Users/tester/a.txt","tool":"fs_read","ts":"2026-09-27T14:30:00Z"}
    {"bytes":0,"outcome":"denied_allowlist","path":"/Users/tester/Desktop/Grux","reason":"outside allowlist","resolved":"","tool":"fs_list","ts":"2026-09-27T15:29:00Z"}
    {"bytes":10,"outcome":"ok","path":"pwd","reason":"","resolved":"/tmp","tool":"shell_run","ts":"2026-09-27T16:00:00Z"}
    """

    // MARK: - shell_audit_log: happy path

    func testTheAuditLogAnswersTheTodayAndRefusalChips() throws {
        let url = try writeLog(Self.log)
        let today = audit([:], log: url)
        XCTAssertTrue(today.hasPrefix("ok: 4 lines today, 2 shell commands ran ok today."), today)
        XCTAssertTrue(today.contains("12:00 PM shell_run ok: pwd"), "newest first, local 12 hour time: \(today)")
        XCTAssertFalse(today.contains("touch proof.txt"), "yesterday's line is not today's")

        let refused = audit(["outcome": "refused", "day": "yesterday"], log: url)
        XCTAssertTrue(refused.contains("7:51 PM shell_run_confirmed blocked: touch proof.txt (strict mode: touch is not on the allowlist)"), refused)

        let todayRefused = audit(["outcome": "refused"], log: url)
        XCTAssertTrue(todayRefused.contains("denied_allowlist: ~/Desktop/Grux"), "home paths read as ~: \(todayRefused)")
    }

    // MARK: - shell_audit_log: refusals

    func testTheAuditLogTakesNoPath() throws {
        let url = try writeLog(Self.log)
        for input: [String: Any] in [["path": "/etc/passwd"], ["file": "../../.ssh/id_ed25519"], ["day": "today", "url": "x"]] {
            let r = audit(input, log: url)
            XCTAssertTrue(r.hasPrefix("refused:"), "\(input): \(r)")
            XCTAssertTrue(r.contains("takes only day, outcome and limit"), r)
        }
    }

    func testTheAuditLogRefusesADayOutOfReachAndAnUnknownOutcome() throws {
        let url = try writeLog(Self.log)
        XCTAssertTrue(audit(["day": "2026-09-19"], log: url).hasPrefix("refused:"), "8 days back")
        XCTAssertTrue(audit(["day": "2026-09-20"], log: url).hasPrefix("ok:"), "7 days back is in reach")
        XCTAssertTrue(audit(["day": "2026-09-28"], log: url).hasPrefix("refused:"), "tomorrow")
        XCTAssertTrue(audit(["day": "last week"], log: url).hasPrefix("refused:"))
        XCTAssertTrue(audit(["outcome": "everything"], log: url).hasPrefix("refused:"))
    }

    func testAnOversizeReadIsRefused() throws {
        let url = try writeLog(Self.log)
        let r = audit(["limit": 201], log: url)
        XCTAssertEqual(r, "refused: a read is at most 200 lines, and 201 were asked for.")
        XCTAssertTrue(audit(["limit": 200], log: url).hasPrefix("ok:"))
        XCTAssertTrue(audit(["limit": 1e30], log: url).hasPrefix("refused:"), "a huge number is refused, never a crash")
        XCTAssertTrue(audit(["limit": "all"], log: url).hasPrefix("refused:"))
    }

    /// A log bigger than the cap is read from its end only, and the reply says so.
    func testABigLogIsReadOnlyFromItsEnd() throws {
        let filler = String(repeating: "{\"ts\":\"2026-09-01T00:00:00Z\",\"tool\":\"fs_read\",\"path\":\"x\",\"outcome\":\"ok\"}\n",
                            count: Int(ShellRecoveryTools.maxReadBytes / 70) + 2_000)
        let url = try writeLog(filler + Self.log)
        let r = audit([:], log: url)
        XCTAssertTrue(r.hasPrefix("ok: 4 lines today"), r)
        XCTAssertTrue(r.contains("Only the last 4 MB of a 4 MB log was read") || r.contains("Only the last 4 MB of a 5 MB log was read"), r)

        let tail = ShellRecoveryTools.readTail(url: url, maxBytes: 100)
        XCTAssertNotNil(tail.fullSize)
        XCTAssertFalse(tail.text?.hasPrefix("\"") ?? true, "the cut never starts mid line")
        XCTAssertTrue(tail.text?.contains("\"pwd\"") ?? false)
    }

    // MARK: - shell_audit_log: the scrubber

    func testEveryReturnedFieldIsScrubbed() throws {
        // The guard's own documented example of an assigned secret, not a real one.
        let secretLine = """
        {"bytes":0,"outcome":"blocked","path":"export DB_PASS=hunter2secret","reason":"DB_PASS=hunter2secret is not allowed","resolved":"/tmp","tool":"shell_run","ts":"2026-09-27T17:00:00Z"}
        """
        let url = try writeLog(Self.log + "\n" + secretLine)
        let r = audit([:], log: url)
        XCTAssertTrue(r.contains("export DB_PASS"), "control: the line is in the reply: \(r)")
        XCTAssertFalse(r.contains("hunter2secret"), "the secret reached chat: \(r)")
        XCTAssertTrue(r.contains("[REDACTED"), r)
    }

    // MARK: - shell_snapshots

    func testTheListNamesTheSnapshotAndScrubsItsLabel() async throws {
        let id = try await seedSnapshot()
        let r = await inStore { await ShellRecoveryTools.listSnapshots(input: [:], home: "/Users/nobody") }
        XCTAssertTrue(r.hasPrefix("ok: 1 snapshot"), r)
        XCTAssertTrue(r.contains("\(id) | "), r)
        XCTAssertTrue(r.contains("before destructive cmd #1: rm notes.txt"), r)
    }

    func testTheListTakesNoArgumentsAndReadsOnlyTheStore() async throws {
        _ = try await seedSnapshot()
        for input: [String: Any] in [["path": "/etc"], ["support_dir": tmp.path], ["store": "../"]] {
            let r = await inStore { await ShellRecoveryTools.listSnapshots(input: input) }
            XCTAssertTrue(r.hasPrefix("refused:"), "\(input): \(r)")
        }
        // A repository sitting OUTSIDE the store is never listed.
        let elsewhere = tmp.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let outside = ShellSnapshotStore(sessionId: "outside", rootDir: work.path, supportDir: elsewhere.path)
        try await outside.ensureInitialized()
        let stray = try await outside.snapshot(label: "before destructive cmd #9: rm x", trigger: "destructive-detect", commandIndex: 9)
        let r = await inStore { await ShellRecoveryTools.listSnapshots(input: [:]) }
        XCTAssertFalse(r.contains(stray.snapshotId), "a repository outside the store was listed: \(r)")
    }

    func testTheListIsBoundedToTwentyAndToAFolderGruxMayWorkIn() async throws {
        let store = ShellSnapshotStore(sessionId: "busy", rootDir: work.path, supportDir: support.path)
        try await store.ensureInitialized()
        for i in 1...22 {
            try "v\(i)".write(to: work.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
            _ = try await store.snapshot(label: "turn \(i)", trigger: "turn-start", commandIndex: i)
        }
        let r = await inStore { await ShellRecoveryTools.listSnapshots(input: [:]) }
        XCTAssertTrue(r.hasPrefix("ok: 22 snapshots from the last 7 days, showing 20"), r)
        XCTAssertEqual(r.split(separator: "\n").count, 21, "a header and 20 rows")

        UserDefaults.standard.set("/nowhere/else", forKey: ShellAllowlist.watchedRootDefaultsKey)
        let off = await inStore { await ShellRecoveryTools.listSnapshots(input: [:]) }
        XCTAssertTrue(off.hasPrefix("ok: no snapshot"), "a folder Grux may no longer work in is not offered: \(off)")
    }

    /// The snapshot the undo chip names stays listed however many request baselines follow it.
    func testTheDestructiveSnapshotStaysListedBehindManyBaselines() async throws {
        let id = try await seedSnapshot(session: "busy")
        let store = ShellSnapshotStore(sessionId: "busy", rootDir: work.path, supportDir: support.path)
        try await store.hydrate()
        for i in 2...23 {
            _ = try await store.snapshot(label: "turn \(i)", trigger: "turn-start", commandIndex: i)
        }
        let r = await inStore { await ShellRecoveryTools.listSnapshots(input: [:]) }
        XCTAssertTrue(r.split(separator: "\n").dropFirst().first?.hasPrefix(id) ?? false, r)
    }

    /// A folder whose name holds a word the gate's sniffers react to still queues a plain card.
    func testAFolderNamedLikeAPostStillQueuesACard() async throws {
        let odd = tmp.appendingPathComponent("threads-publish-wireframes")
        try FileManager.default.createDirectory(at: odd, withIntermediateDirectories: true)
        UserDefaults.standard.set([work.path, odd.path], forKey: ShellAllowlist.watchedRootDefaultsKey)
        let id = try await seedSnapshot(session: "odd", root: odd)
        let r = await inStore {
            await ChatService.dispatchTool(name: ShellRecoveryTools.restoreTool, input: ["snapshot_id": id])
        }
        XCTAssertTrue(r.hasPrefix("pending:"), r)
        let card = ApprovalQueue.shared.pending.first { $0.action.detail["snapshot_id"] == id }
        XCTAssertEqual(card?.urgent, false, "a restore is not a spend")
    }

    // MARK: - shell_restore_snapshot: the gate holds

    /// THE GATE. Through the real chat door, in every autonomy mode, the restore queues for a
    /// tap and the folder is untouched.
    func testTheRestoreWaitsForATapInEveryMode() async throws {
        let id = try await seedSnapshot()
        for mode in AutonomyMode.allCases {
            AutonomyController.shared.setMode(mode)
            let r = await inStore {
                await ChatService.dispatchTool(name: ShellRecoveryTools.restoreTool, input: ["snapshot_id": id])
            }
            XCTAssertTrue(r.hasPrefix("pending:"), "\(mode): the restore ran without a tap: \(r)")
            XCTAssertEqual(notes, "destroyed", "\(mode): the folder changed before anybody tapped")
        }
        let cards = ApprovalQueue.shared.pending.filter {
            !queuedBefore.contains($0.id) && $0.action.detail["__replay_tool"] == ShellRecoveryTools.restoreTool
        }
        XCTAssertFalse(cards.isEmpty, "no card waits for the tap")
        XCTAssertTrue(cards.allSatisfy { $0.state == .pending }, "a card resolved itself")
        XCTAssertTrue(cards.first?.summary.contains("back to how it was at") ?? false,
                      "the card names the folder and the time: \(cards.first?.summary ?? "")")
    }

    func testADryRunNeverRestores() async throws {
        let id = try await seedSnapshot()
        let r = await JaxToolGate.$dryRun.withValue(true) {
            await inStore { await ChatService.dispatchTool(name: ShellRecoveryTools.restoreTool, input: ["snapshot_id": id]) }
        }
        XCTAssertTrue(r.hasPrefix("dryrun:"), r)
        XCTAssertEqual(notes, "destroyed")
    }

    // MARK: - shell_restore_snapshot: the happy path, end to end

    /// The id from the list's own output, through the gate, approved, restored by the same
    /// path `grux undo` uses.
    func testTheListedIdRestoresAfterTheTap() async throws {
        _ = try await seedSnapshot()
        let listed = await inStore { await ShellRecoveryTools.listSnapshots(input: [:]) }
        let id = try XCTUnwrap(listed.split(separator: "\n").dropFirst().first?
            .components(separatedBy: " | ").first, listed)

        let pending = await inStore {
            await ChatService.dispatchTool(name: ShellRecoveryTools.restoreTool, input: ["snapshot_id": id])
        }
        XCTAssertTrue(pending.hasPrefix("pending:"), pending)
        let card = try XCTUnwrap(ApprovalQueue.shared.pending.first {
            !queuedBefore.contains($0.id) && $0.action.detail["__replay_tool"] == ShellRecoveryTools.restoreTool
        })

        let result = await inStore { await ApprovalQueue.shared.approveAndExecute(card.id) }
        XCTAssertTrue(result.hasPrefix("ok: restored to snapshot \(id)"), result)
        XCTAssertEqual(notes, "original", "the tap restored the folder")
    }

    // MARK: - shell_restore_snapshot: refusals

    func testABadIdIsRefusedBeforeAnythingIsQueued() async throws {
        _ = try await seedSnapshot()
        for bad in ["../../etc/passwd", "s1-abcdef0/../../x", "/tmp/support/chat-session.git", "", "S1-ABCDEF0", "rm -rf ~"] {
            let r = await inStore {
                await ChatService.dispatchTool(name: ShellRecoveryTools.restoreTool, input: ["snapshot_id": bad])
            }
            XCTAssertTrue(r.hasPrefix("refused:"), "\(bad): \(r)")
            XCTAssertTrue(r.contains("is not a snapshot id"), "\(bad): \(r)")
        }
        XCTAssertTrue(ApprovalQueue.shared.pending.allSatisfy { queuedBefore.contains($0.id) },
                      "a refused id still put a card in Approvals")
        XCTAssertEqual(notes, "destroyed")
    }

    func testAnUnknownIdAndAForbiddenFolderAreRefused() async throws {
        _ = try await seedSnapshot()
        let unknown = await inStore {
            await ChatService.dispatchTool(name: ShellRecoveryTools.restoreTool, input: ["snapshot_id": "s9-0000000"])
        }
        XCTAssertTrue(unknown.hasPrefix("refused: No snapshot called s9-0000000"), unknown)

        let id = try await seedSnapshot(session: "second")
        UserDefaults.standard.set("/nowhere/else", forKey: ShellAllowlist.watchedRootDefaultsKey)
        let forbidden = await inStore {
            await ChatService.dispatchTool(name: ShellRecoveryTools.restoreTool, input: ["snapshot_id": id])
        }
        XCTAssertTrue(forbidden.hasPrefix("refused:"), forbidden)
        XCTAssertEqual(notes, "destroyed")
    }

    /// The shared path refuses a non-id for every door, `grux undo` included.
    func testTheSharedRestorePathRefusesANonId() async {
        let r = await GruxControlTools.restoreSnapshot(snapshotId: "../../etc", supportDir: support.path)
        guard case .refused(let reason) = r else { return XCTFail("restored a path") }
        XCTAssertTrue(reason.contains("is not a snapshot id"), reason)
    }

    // MARK: - Routing: the chips bring the tools in, an ordinary ask does not

    func testEachChipBringsItsToolAndAnOrdinaryAskDoesNot() {
        let all = ChatService.allTools()
        func routed(_ text: String) -> Set<String> {
            Set(ToolRelevance.filter(all, signals: .init(utterance: text)).map(\.name)).intersection(ShellRecoveryTools.names)
        }
        XCTAssertEqual(routed("Undo `rm -rf build` from 5:43 PM"), ShellRecoveryTools.names)
        XCTAssertEqual(routed("Why did you refuse `touch proof.txt`?"), ShellRecoveryTools.names)
        XCTAssertEqual(routed("What did you run today? (361 commands)"), ShellRecoveryTools.names)
        for ordinary in ["write a list", "what time is it", "add milk to my groceries",
                         "summarize this email", "what is on my calendar tomorrow",
                         "undo that paste", "I ran today, 5 miles", "I refuse to wait",
                         "take a snapshot of my week", "what did you run into today"] {
            XCTAssertEqual(routed(ordinary), [], "\(ordinary) pulled the shell tools in")
        }
    }
}
