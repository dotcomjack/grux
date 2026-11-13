import XCTest
@testable import Grux

/// The chat empty state's chips, built from this Mac's state (`ChatStarterChips`).
///
/// Every rule is driven twice: once with its input present, asserting the exact chip a person
/// would send, and once without, asserting the exact reason it was skipped. A rule that is
/// only checked for presence passes against a builder that offers everything.
final class ChatStarterChipsTests: XCTestCase {

    // A fixed clock, a fixed zone and a fixed home, so nothing here reads the machine.
    let home = "/Users/tester"
    lazy var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()
    /// Sunday 2026-09-27, 8:00 PM Eastern.
    var now: Date { at(20, 0) }

    func at(_ hour: Int, _ minute: Int, daysAgo: Int = 0) -> Date {
        let day = cal.date(from: DateComponents(year: 2026, month: 9, day: 27 - daysAgo))!
        return cal.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
    }

    /// Chat can act on every rule, both permissions are granted and a local model is set up,
    /// so no rule fires and no unlock fills. Each test adds the one input it is about.
    func quiet() -> MacStarterState {
        var s = MacStarterState()
        s.chatCanRestoreSnapshots = true
        s.chatCanReadAuditLog = true
        s.calendarAccess = true
        s.screenRecording = true
        s.localModelSetUp = true
        s.memoryGB = 16
        return s
    }

    func build(_ s: MacStarterState) -> ChatStarterChips.Result {
        ChatStarterChips.build(s, now: now, calendar: cal, home: home)
    }

    // MARK: - Each rule, offered when its input exists

    func testUndoNamesTheCommandTheTimeAndTheFolder() {
        var s = quiet()
        s.lastDestructiveSnapshot = .init(at: at(17, 43), command: "find /Users/tester/x -name y -delete",
                                          folder: "/Users/tester/proj")
        let r = build(s)
        XCTAssertEqual(r.chips.map(\.ask), ["Undo `find ~/x -name y -delete` from 5:43 PM"])
        XCTAssertEqual(r.chips.first?.because, "a snapshot of ~/proj was taken right before it ran")
    }

    func testUndoFromEarlierInTheWeekNamesTheDay() {
        var s = quiet()
        s.lastDestructiveSnapshot = .init(at: at(9, 5, daysAgo: 1), command: "rm -rf build", folder: "/tmp/p")
        XCTAssertEqual(build(s).chips.map(\.ask), ["Undo `rm -rf build` from Saturday at 9:05 AM"])
    }

    func testRefusalNamesWhatWasRefused() {
        var s = quiet()
        s.lastRefusal = .init(at: at(19, 51), target: "/Users/tester/Desktop/Grux",
                              reason: "that folder is outside the allowlist")
        let r = build(s)
        XCTAssertEqual(r.chips.map(\.ask), ["Why did you refuse `~/Desktop/Grux`?"])
        XCTAssertEqual(r.chips.first?.because,
                       "the log has the refusal from 7:51 PM: that folder is outside the allowlist")
    }

    func testMeetingNamesTheNextOneToday() {
        var s = quiet()
        s.nextMeeting = .init(at: at(21, 30), title: "Design review")
        XCTAssertEqual(build(s).chips.map(\.ask), ["Prep me for Design review at 9:30 PM"])
    }

    func testWindowNamesTheAppAndTheTitle() {
        var s = quiet()
        s.frontWindow = .init(app: "Xcode", title: "Build failed in GruxTests.swift line 40")
        XCTAssertEqual(build(s).chips.map(\.ask), ["What is wrong in Xcode: Build failed in GruxTests\u{2026}?"])
    }

    func testTodayCountsTheCommands() {
        var s = quiet()
        s.commandsToday = 361
        XCTAssertEqual(build(s).chips.map(\.ask), ["What did you run today? (361 commands)"])
        s.commandsToday = 1
        XCTAssertEqual(build(s).chips.map(\.ask), ["What did you run today? (1 command)"])
    }

    func testLocalNamesTheSizeForThisMac() {
        var s = quiet()
        s.localModelSetUp = false
        let r = build(s)
        XCTAssertEqual(r.chips.map(\.ask), ["Set up Grux Local 4B for this Mac's 16 GB"])
        XCTAssertEqual(r.chips.first?.because,
                       "no local model yet, and the 4B is the size for Macs with 16 GB and up")
    }

    // MARK: - Each rule, skipped with its reason when its input is missing

    func testEveryRuleSkipsWithItsReasonOnAQuietMac() {
        let r = build(quiet())
        XCTAssertEqual(r.chips, [], "control: a quiet Mac with both permissions offers nothing")
        XCTAssertEqual(r.reason(.undo), "no destructive command has run in the last 7 days, so there is nothing to undo")
        XCTAssertEqual(r.reason(.refusal), "nothing has been refused in the last 7 days")
        XCTAssertEqual(r.reason(.meeting), "no meeting left on the calendar today")
        XCTAssertEqual(r.reason(.window), "the window you were in has no title Grux may read")
        XCTAssertEqual(r.reason(.today), "no command has run today")
        XCTAssertEqual(r.reason(.local), "a local model is already set up")
    }

    /// The rule that guards everything else: a fact chat cannot act on is not offered.
    func testAFactChatCannotActOnIsNotOffered() {
        var s = quiet()
        s.lastDestructiveSnapshot = .init(at: at(17, 43), command: "rm -rf x", folder: "/tmp/p")
        s.lastRefusal = .init(at: at(19, 0), target: "touch a", reason: "strict")
        s.commandsToday = 5
        s.chatCanRestoreSnapshots = false
        s.chatCanReadAuditLog = false
        let r = build(s)
        XCTAssertEqual(r.chips, [])
        XCTAssertEqual(r.reason(.undo), "chat has no tool to restore a snapshot by its id yet")
        XCTAssertEqual(r.reason(.refusal), "chat cannot read the audit log yet")
        XCTAssertEqual(r.reason(.today), "chat cannot read the audit log yet")
    }

    /// On a local model the three shell chips are not offered. Measured 2026-11-12 on the Mac
    /// mini, Grux Local 2b, real turns with the recovery tools in its slots: the undo ask called
    /// shell_undo with an id copied from a tool description, the refusal ask called nothing,
    /// and the today ask read the log and answered "I have not done that". None worked.
    func testOnALocalModelTheShellChipsAreNotOffered() {
        var s = quiet()
        s.lastDestructiveSnapshot = .init(at: at(17, 43), command: "rm -rf x", folder: "/tmp/p")
        s.lastRefusal = .init(at: at(19, 0), target: "touch a", reason: "strict")
        s.commandsToday = 5
        s.chatOnLocalModel = true
        let r = build(s)
        XCTAssertEqual(r.chips, [], "\(r.chips.map(\.ask))")
        let why = "chat runs on a local model here, and a local model does not use Grux's shell tools reliably yet"
        XCTAssertEqual(r.reason(.undo), why)
        XCTAssertEqual(r.reason(.refusal), why)
        XCTAssertEqual(r.reason(.today), why)
        // The same facts on a cloud route are offered (the control).
        s.chatOnLocalModel = false
        XCTAssertEqual(build(s).chips.count, 3)
    }

    /// Chat has the tools now (`ShellRecoveryTools`), so the shipped defaults light the chips.
    @MainActor func testTheShippedDefaultsLightTheChipsChatCanAnswer() {
        let s = MacStarterState()
        XCTAssertTrue(s.chatCanRestoreSnapshots)
        XCTAssertTrue(s.chatCanReadAuditLog)
        let names = Set(ChatService.allTools().map(\.name))
        XCTAssertTrue(names.isSuperset(of: ShellRecoveryTools.names), "a switch is on with no tool behind it")
    }

    func testUndoOlderThanSevenDaysIsSkipped() {
        var s = quiet()
        s.lastDestructiveSnapshot = .init(at: at(17, 43, daysAgo: 8), command: "rm -rf x", folder: "/tmp/p")
        XCTAssertEqual(build(s).chips, [])
        XCTAssertNotNil(build(s).reason(.undo))
    }

    func testMeetingSkips() {
        var s = quiet()
        s.calendarAccess = false
        s.nextMeeting = .init(at: at(21, 30), title: "Design review")
        XCTAssertEqual(build(s).reason(.meeting), "Calendar is not connected")

        s = quiet()
        s.nextMeeting = .init(at: at(19, 0), title: "Already started")
        XCTAssertEqual(build(s).reason(.meeting), "no meeting left on the calendar today",
                       "a meeting that has begun is not one to prep for")
    }

    func testWindowSkipsWithoutScreenRecording() {
        var s = quiet()
        s.screenRecording = false
        s.frontWindow = .init(app: "Xcode", title: "Main.swift")
        let r = build(s)
        XCTAssertEqual(r.reason(.window), "Screen Recording is not granted, so Grux cannot see the window you are in")
        XCTAssertFalse(r.chips.map(\.ask).contains { $0.hasPrefix("What is wrong in") })
    }

    func testLocalSkips() {
        var s = quiet()
        s.localModelSetUp = nil
        XCTAssertEqual(build(s).reason(.local),
                       "Ollama is installed but not answering, so whether a local model is set up is unknown")
        s.localModelSetUp = false
        s.memoryGB = nil
        XCTAssertEqual(build(s).reason(.local), "this Mac's memory is unknown")
        s.memoryGB = 4
        XCTAssertEqual(build(s).reason(.local), "no Grux Local size is made for a Mac under 8 GB")
    }

    // MARK: - The cap and the fill

    func testNeverMoreThanThreeAndTheOverflowIsNamed() {
        var s = quiet()
        s.lastDestructiveSnapshot = .init(at: at(17, 43), command: "rm -rf x", folder: "/tmp/p")
        s.lastRefusal = .init(at: at(19, 0), target: "touch a", reason: "strict")
        s.nextMeeting = .init(at: at(21, 0), title: "Standup")
        s.frontWindow = .init(app: "Xcode", title: "Main.swift")
        s.commandsToday = 9
        s.localModelSetUp = false
        let r = build(s)
        XCTAssertEqual(r.chips.map(\.ask), ["Undo `rm -rf x` from 5:43 PM",
                                            "Why did you refuse `touch a`?",
                                            "Prep me for Standup at 9:00 PM"])
        XCTAssertEqual(r.skipped.filter { $0.rule == .cap }.map(\.reason),
                       ["only 3 chips: What is wrong in Xcode: Main.swift?",
                        "only 3 chips: What did you run today? (9 commands)",
                        "only 3 chips: Set up Grux Local 4B for this Mac's 16 GB"])
    }

    func testUnlocksFillOnlyEmptySlotsAndOnlyForAMissingPermission() {
        var fresh = MacStarterState()
        fresh.memoryGB = 48
        XCTAssertEqual(build(fresh).chips.map(\.ask), ["Set up Grux Local 9B for this Mac's 48 GB",
                                                       "Let Grux see the window I am in",
                                                       "Connect my calendar"])

        // Calendar connected with no meeting today: never told to connect it.
        var s = fresh
        s.calendarAccess = true
        XCTAssertFalse(build(s).chips.map(\.ask).contains("Connect my calendar"))

        // Screen Recording granted with no readable title: never told to grant it.
        s = fresh
        s.screenRecording = true
        XCTAssertFalse(build(s).chips.map(\.ask).contains("Let Grux see the window I am in"))

        // A full Mac leaves no slot to fill.
        s = fresh
        s.chatCanReadAuditLog = true
        s.lastRefusal = .init(at: at(19, 0), target: "touch a", reason: "strict")
        s.commandsToday = 3
        XCTAssertEqual(build(s).chips.map(\.ask), ["Why did you refuse `touch a`?",
                                                   "What did you run today? (3 commands)",
                                                   "Set up Grux Local 9B for this Mac's 48 GB"])
    }

    // MARK: - Helpers

    func testGruxLocalSizeThresholds() {
        let cases: [(Int, String?)] = [(4, nil), (7, nil), (8, "2B"), (16, "4B"), (18, "4B"),
                                       (24, "9B"), (36, "9B"), (48, "9B"), (128, "9B")]
        for (gb, want) in cases {
            XCTAssertEqual(ChatStarterChips.localSize(memoryGB: gb)?.label, want, "\(gb) GB")
        }
        XCTAssertEqual(ChatStarterChips.localSize(memoryGB: 8)?.floor, 8)
        XCTAssertEqual(ChatStarterChips.localSize(memoryGB: 16)?.floor, 16)
        XCTAssertEqual(ChatStarterChips.localSize(memoryGB: 32)?.floor, 24)
    }

    func testTimesAreTwelveHourStandard() {
        XCTAssertEqual(ChatStarterChips.whenText(at(17, 43), now: now, calendar: cal), "5:43 PM")
        XCTAssertEqual(ChatStarterChips.whenText(at(0, 5), now: now, calendar: cal), "12:05 AM")
        XCTAssertEqual(ChatStarterChips.whenText(at(17, 43, daysAgo: 1), now: now, calendar: cal),
                       "Saturday at 5:43 PM")
        XCTAssertEqual(ChatStarterChips.whenText(at(17, 43, daysAgo: 7), now: now, calendar: cal),
                       "Sep 20 at 5:43 PM", "a week ago is a date, never this weekday's name")
        XCTAssertFalse(ChatStarterChips.whenText(at(17, 43), now: now, calendar: cal).contains("17"))
    }

    func testHomePathsReadAsTilde() {
        XCTAssertEqual(ChatStarterChips.shortenHome("/Users/tester", home: home), "~")
        XCTAssertEqual(ChatStarterChips.shortenHome("/Users/tester/Desktop/Grux", home: home), "~/Desktop/Grux")
        XCTAssertEqual(ChatStarterChips.shortenHome("rm -rf /Users/tester/a /Users/tester/b", home: home),
                       "rm -rf ~/a ~/b")
        XCTAssertEqual(ChatStarterChips.shortenHome("/Users/testerz/x", home: home), "/Users/testerz/x",
                       "a different home that shares a prefix is not this home")
    }

    func testChipsCarryNoDashes() {
        var s = quiet()
        s.lastDestructiveSnapshot = .init(at: at(17, 43), command: "rm -rf x", folder: "/tmp/p")
        s.screenRecording = false
        s.calendarAccess = false
        s.localModelSetUp = false
        for chip in build(s).chips + build(MacStarterState(memoryGB: 8)).chips {
            for text in [chip.ask, chip.because] {
                XCTAssertFalse(text.contains("\u{2014}") || text.contains("\u{2013}"), text)
            }
        }
    }

    // MARK: - Reading the real sources

    func testAuditFactsFindTheLatestRefusalAndTodaysCommands() {
        // Eastern time is UTC-4 on this date, so 13:00Z is 9:00 AM local.
        let log = """
        {"bytes":0,"outcome":"denied_secret","path":"/Users/tester/.env","reason":"secret","resolved":"","tool":"fs_read","ts":"2026-09-10T15:00:00Z"}
        {"bytes":0,"outcome":"gated","path":"rm -rf /tmp/old","reason":"needs confirmation","resolved":"/tmp","tool":"shell_run","ts":"2026-09-25T15:00:00Z"}
        {"bytes":0,"outcome":"blocked","path":"touch proof.txt","reason":"strict mode: touch is not on the allowlist","resolved":"/tmp","tool":"shell_run_confirmed","ts":"2026-09-26T23:51:00.120Z"}
        {"bytes":0,"outcome":"gated","path":"git push","reason":"network","resolved":"/tmp","tool":"shell_run","ts":"2026-09-27T12:59:00Z"}
        {"bytes":10,"outcome":"ok","path":"ls","reason":"","resolved":"/tmp","tool":"shell_run_confirmed","ts":"2026-09-27T13:00:00.500Z"}
        {"bytes":10,"outcome":"ok","path":"pwd","reason":"","resolved":"/tmp","tool":"shell_run","ts":"2026-09-27T14:00:00Z"}
        {"bytes":10,"outcome":"ok","path":"/Users/tester/a.txt","reason":"","resolved":"/Users/tester/a.txt","tool":"fs_read","ts":"2026-09-27T14:30:00Z"}
        {"bytes":0,"outcome":"error","path":"make","reason":"exit 2","resolved":"/tmp","tool":"shell_run_confirmed","ts":"2026-09-27T15:00:00Z"}
        {"bytes":0,"outcome":"denied_missing","path":"/Users/tester/gone.txt","reason":"no such file","resolved":"","tool":"fs_read","ts":"2026-09-27T15:30:00Z"}
        {"bytes":0,"outcome":"ok","path":"echo late","reason":"","resolved":"/tmp","tool":"shell_run","ts":"2026-09-28T03:59:00Z"}
        {"bytes":0,"outcome":"ok","path":"echo tomorrow","reason":"","resolved":"/tmp","tool":"shell_run","ts":"2026-09-28T04:30:00Z"}
        {"ts":"2026-09-27T
        """
        let facts = ChatStarterChips.auditFacts(log, now: now, calendar: cal)
        // 03:59Z on the 28th is 11:59 PM on the 27th Eastern, so it is today's; 04:30Z is not.
        XCTAssertEqual(facts.commandsToday, 3,
                       "three shell commands ran on the local day; a file read, an error and tomorrow's line do not count")
        XCTAssertEqual(facts.lastRefusal?.target, "touch proof.txt",
                       "an error, a missing file and a gate held for confirmation are not refusals")
        XCTAssertEqual(facts.lastRefusal?.reason, "strict mode: touch is not on the allowlist")
        XCTAssertEqual(facts.lastRefusal.map { ChatStarterChips.whenText($0.at, now: now, calendar: cal) },
                       "Saturday at 7:51 PM", "the log is UTC and the chip is local")

        XCTAssertNil(ChatStarterChips.auditFacts("", now: now, calendar: cal).lastRefusal)
        let old = """
        {"bytes":0,"outcome":"denied_secret","path":"/Users/tester/.env","reason":"secret","resolved":"","tool":"fs_read","ts":"2026-09-10T15:00:00Z"}
        """
        XCTAssertNil(ChatStarterChips.auditFacts(old, now: now, calendar: cal).lastRefusal,
                     "a refusal older than 7 days is not offered")
        let secret = old.replacingOccurrences(of: "2026-09-10", with: "2026-09-27")
        XCTAssertEqual(ChatStarterChips.auditFacts(secret, now: now, calendar: cal).lastRefusal?.target,
                       "/Users/tester/.env", "a secret withheld is a refusal")
    }

    func testLatestDestructiveSnapshotIsTheNewestRestorableOneThisWeek() {
        typealias Row = ChatStarterChips.SnapshotRow
        let rows = [
            Row(folder: "/tmp/a", restorable: true, trigger: "turn-start",
                label: "turn 3", createdAt: at(19, 0)),
            Row(folder: "/tmp/gone", restorable: false, trigger: "destructive-detect",
                label: "before destructive cmd #4: rm -rf gone", createdAt: at(18, 0)),
            Row(folder: "/tmp/old", restorable: true, trigger: "destructive-detect",
                label: "before destructive cmd #1: rm -rf old", createdAt: at(18, 0, daysAgo: 9)),
            Row(folder: "/tmp/legacy", restorable: true, trigger: "unknown",
                label: "before destructive cmd #2: find . -name x -delete", createdAt: at(17, 43)),
            Row(folder: "/tmp/b", restorable: true, trigger: "destructive-detect",
                label: "before destructive cmd #7: rm notes.txt", createdAt: at(9, 0)),
        ]
        let hit = ChatStarterChips.latestDestructive(rows, now: now)
        XCTAssertEqual(hit?.command, "find . -name x -delete")
        XCTAssertEqual(ChatStarterChips.commandFromLabel("before destructive cmd #3: rm -rf build"), "rm -rf build")
        XCTAssertEqual(hit?.folder, "/tmp/legacy")
        XCTAssertNil(ChatStarterChips.latestDestructive(Array(rows.prefix(3)), now: now))
    }

    // MARK: - The four states on the proposal board

    /// The prototype's four real states (`messaging-r1/gen/states.json`), built with the
    /// SHIPPED switches (no override), must produce the chips on the board (`results.json`).
    /// Prints them so the run log carries the evidence.
    func testTheFourBoardStatesProduceTheBoardChips() {
        func state(snapshot: (String, String)? = nil, refusal: (String, String)? = nil,
                   commands: Int, memory: Int) -> MacStarterState {
            var s = MacStarterState()
            s.commandsToday = commands
            s.memoryGB = memory
            s.localModelSetUp = false
            if let (time, cmd) = snapshot {
                s.lastDestructiveSnapshot = .init(at: clock(time), command: cmd, folder: "the session folder")
            }
            if let (time, target) = refusal {
                s.lastRefusal = .init(at: clock(time), target: target, reason: "from the log")
            }
            return s
        }
        let cases: [(String, MacStarterState, [String])] = [
            ("Our test Mac, Sep 27 (16 GB, 361 commands logged)",
             state(snapshot: ("5:43 PM", "sort -o loop-a23b-sorted.txt loop-a23b-sorted.txt"),
                   refusal: ("7:51 PM", "touch proof.txt"), commands: 361, memory: 16),
             ["Undo `sort -o loop-a23b-sorted.txt loop\u{2026}` from 5:43 PM",
              "Why did you refuse `touch proof.txt`?",
              "What did you run today? (361 commands)"]),
            ("Our test Mac, Oct 23 (145 commands, no destructive command in the last 7 days)",
             state(refusal: ("9:27 AM", "touch proof.txt"), commands: 145, memory: 16),
             ["Why did you refuse `touch proof.txt`?",
              "What did you run today? (145 commands)",
              "Set up Grux Local 4B for this Mac's 16 GB"]),
            ("Our test Mac, Nov 1 (a quiet day: 2 log lines, both refusals)",
             state(refusal: ("11:29 AM", "~/Desktop/Grux"), commands: 0, memory: 16),
             ["Why did you refuse `~/Desktop/Grux`?",
              "Set up Grux Local 4B for this Mac's 16 GB",
              "Let Grux see the window I am in"]),
            ("A fresh install (48 GB MacBook Pro, nothing granted yet)",
             state(commands: 0, memory: 48),
             ["Set up Grux Local 9B for this Mac's 48 GB",
              "Let Grux see the window I am in",
              "Connect my calendar"]),
        ]
        for (label, s, want) in cases {
            let got = ChatStarterChips.build(s, now: at(23, 59), calendar: cal, home: home)
            print("BOARD STATE: \(label)")
            for chip in got.chips { print("  CHIP: \(chip.ask)") }
            for skip in got.skipped { print("  SKIP \(skip.rule.rawValue): \(skip.reason)") }
            XCTAssertEqual(got.chips.map(\.ask), want, label)
        }
    }

    /// "5:43 PM" on the fixed day.
    func clock(_ text: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = cal.timeZone
        f.dateFormat = "yyyy-MM-dd h:mm a"
        return f.date(from: "2026-09-27 " + text)!
    }
}
