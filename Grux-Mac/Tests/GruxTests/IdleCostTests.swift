import XCTest
@testable import Grux

/// Guards the idle cost of the app, which is the thing that decides whether it can run on
/// a laptop without the fans coming on.
///
/// These read the SOURCE rather than the running app, deliberately. A CPU regression here
/// is introduced by writing a particular shape of code, and the shape is cheap to check
/// while the runtime cost is expensive and flaky to measure in a unit test.
final class IdleCostTests: XCTestCase {

    private func source(_ relative: String) throws -> String {
        // Tests/GruxTests/<file> -> package root -> Sources/Grux/<relative>
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux").appendingPathComponent(relative)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The regression this exists for: 57 separate repeating timers, each polling for a
    /// file-drop trigger in `~/.grux`, together making 93 stat() calls and 93 main-thread
    /// wakeups per second, forever, on an idle machine. They are one `TriggerWatcher` now.
    ///
    /// Adding another is a one-line change that looks harmless and costs a wakeup per
    /// second for the life of the process, which is exactly the kind of thing nobody
    /// notices until the fans are on.
    func testNoFileTriggerIsPolledOnATimer() throws {
        let src = try source("GruxApp.swift")
        let lines = src.components(separatedBy: "\n")
        var offenders: [String] = []
        for (i, line) in lines.enumerated() where line.contains("scheduledTimer") && line.contains("repeats: true") {
            let body = lines[(i + 1)..<min(i + 4, lines.count)].joined(separator: "\n")
            if body.contains("fileExists") {
                offenders.append("GruxApp.swift:\(i + 1)")
            }
        }
        XCTAssertTrue(offenders.isEmpty,
                      "file-drop triggers must register with TriggerWatcher, not poll on a "
                      + "timer. Offending sites: \(offenders.joined(separator: ", "))")
    }

    /// The conversion moved 57 sites. If a later edit drops registrations on the floor the
    /// triggers stop working silently, which is worse than the polling was.
    func testEveryTriggerIsStillRegistered() throws {
        let src = try source("GruxApp.swift")
        let count = src.components(separatedBy: "TriggerWatcher.shared.register").count - 1
        XCTAssertGreaterThanOrEqual(count, 57,
                                    "expected at least the 57 converted triggers, found \(count)")
        XCTAssertTrue(src.contains("TriggerWatcher.shared.start()"),
                      "registrations are inert unless the watcher is armed")
    }

    /// A Keychain read is an XPC round trip to securityd. These were computed properties
    /// read from inside SwiftUI view bodies, so they ran on every layout pass.
    func testKeychainReadsAreCached() throws {
        let src = try source("KeychainStore.swift")
        XCTAssertTrue(src.contains("if let hit = cached(key) { return hit }"),
                      "KeychainStore.get must consult the cache before hitting securityd")
        // A cache without invalidation is a correctness bug, so both writes must clear it.
        let setRange = try XCTUnwrap(src.range(of: "static func set(_ key: Key"))
        let deleteRange = try XCTUnwrap(src.range(of: "static func delete(_ key: Key"))
        for (name, r) in [("set", setRange), ("delete", deleteRange)] {
            let window = String(src[r.lowerBound..<src.index(r.lowerBound, offsetBy: 200)])
            XCTAssertTrue(window.contains("invalidate(key)"),
                          "KeychainStore.\(name) must invalidate the cache")
        }
    }

    /// Decorative animation must stop when nobody is looking.
    ///
    /// Thirteen `repeatForever` animations and several `TimelineView`s at 30 to 40 fps keep
    /// committing Core Animation transactions while the app sits in the background. A
    /// `repeatForever` animation does not stop when its window is hidden, which is why this
    /// has to be explicit. Measured on an idle laptop before the gate: the main thread was
    /// busy 1959 samples of 7350, and 1041 of those were the display transaction flush.
    func testDecorativeMotionSuspendsWhenNobodyIsLooking() throws {
        let theme = try source("DesignSystem/GruxTheme.swift")
        XCTAssertTrue(theme.contains("MotionSuspension.suspended"),
                      "the single gate every animation site consults must include the "
                      + "nobody-is-looking case, or each site has to remember separately")

        let gate = try source("DesignSystem/MotionSuspension.swift")
        // Conservative on purpose: a window the user is watching beside another app keeps
        // animating. Suspension needs BOTH inactive and no visible window.
        XCTAssertTrue(gate.contains("let suspend = !active && !anyVisible"),
                      "suspension must require both, or motion dies in a visible window")
        XCTAssertTrue(gate.contains("bumpRevisionForMotion"),
                      "without a revision bump the views never re-run onAppear, so the "
                      + "animations neither stop nor restart")
    }

    /// The most expensive feature in the app shipped ON while the two cheaper ambient
    /// features shipped OFF.
    ///
    /// `wakeWordEnabled` held the microphone open and ran SFSpeechRecognizer continuously
    /// from first launch, measured at roughly 22% of a core on an idle M-series laptop, and
    /// with `requiresOnDeviceRecognition` false it streamed that audio off the machine
    /// before the user had asked for anything. It now ships off like its neighbours.
    func testTheAlwaysOnMicFeatureShipsOff() throws {
        let src = try source("Models.swift")
        XCTAssertTrue(src.contains("wakeWordEnabled: Bool = false"),
                      "the wake word listener holds the mic open, it must not ship enabled")
        XCTAssertTrue(src.contains("forKey: .wakeWordEnabled) ?? false"),
                      "the decode fallback must match the init default or a config missing "
                      + "the key silently re-enables it")
        // The neighbour, so this fails if someone flips the other mic-owning feature on
        // instead. `focusEnabled` was named here in a first draft and does not exist, which
        // the test caught: the focus loop's switch lives elsewhere, not in this init.
        XCTAssertTrue(src.contains("ambientEnabled: Bool = false"),
                      "ambient listening must also still ship off")
    }

    /// The single largest cost in the shipping build: the session index read and split
    /// ENTIRE transcripts to build a descriptor, on a timer, against files that reach
    /// 537MB on this machine.
    ///
    /// The comment that justified it said sessions are "small (<5MB)" and that the read is
    /// "acceptable for a settings-picker call". Both stopped being true, and nothing failed
    /// when they did, which is why this is now an assertion instead of a comment.
    func testSessionIndexReadsOnlyTheTail() throws {
        let src = try source("ClaudeSession/ClaudeSessionIndex.swift")
        // Matched on the call, not on the argument name. The first version of this
        // assertion pinned `Data(contentsOf: url` and a plant that wrote
        // `Data(contentsOf: file` walked straight past it, which is the same
        // fitted-to-the-implementation mistake this suite exists to catch.
        XCTAssertFalse(src.contains("Data(contentsOf:"),
                       "the session index must not read whole transcripts, they reach "
                       + "hundreds of megabytes and this runs on a timer")
        XCTAssertTrue(src.contains("readTailLines"),
                      "descriptors are built from the tail, not the file")
        XCTAssertTrue(src.contains("lines.removeFirst()"),
                      "a tail read starts mid-line, so the partial first line must be dropped")
    }

    /// Terminal Focus is a labs feature whose poll ran at launch for everyone, and each
    /// tick walked the window list several times. It must be armed by state, not blindly.
    func testTerminalFocusPollIsGatedOnVisibility() throws {
        let src = try source("TerminalFocusState.swift")
        XCTAssertTrue(src.contains("let needed = isEnabled && (isVisible || isTerminalFront)"),
                      "the terminal poll must be gated on whether the overlay can change")
    }
}

/// The incremental fold must agree with the whole-history fold, exactly.
///
/// This is the assertion that makes the performance change safe. `ClaudeSessionTailer` now
/// folds only newly appended entries into a kept accumulator instead of re-folding the
/// entire transcript every tick. That is only legitimate if folding 1...n then n+1...m
/// gives the same snapshot as folding 1...m in one pass, so it is asserted rather than
/// assumed, including at the boundaries where a slice splits between related entries.
final class IncrementalFoldTests: XCTestCase {

    private func entries() -> [ClaudeSessionEntry] {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let usage = ClaudeSessionUsage(
            inputTokens: 100, outputTokens: 50, cacheReadTokens: 10, cacheCreationTokens: 5)
        return [
            .permissionMode(sessionId: "session-abc"),
            .user(ts: t0, text: "first question", cwd: "/Users/x/proj", gitBranch: "main"),
            .assistant(ts: t0.addingTimeInterval(1), text: "first answer", toolUseName: nil,
                       usage: usage, model: "claude-opus-4", stopReason: nil,
                       cwd: "/Users/x/proj", gitBranch: "main"),
            .user(ts: t0.addingTimeInterval(2), text: "second question", cwd: nil, gitBranch: nil),
            .assistant(ts: t0.addingTimeInterval(3), text: "second answer", toolUseName: "Bash",
                       usage: usage, model: "claude-opus-4", stopReason: "tool_use",
                       cwd: nil, gitBranch: nil),
            .other,
            .assistant(ts: t0.addingTimeInterval(4), text: "third answer", toolUseName: nil,
                       usage: usage, model: "claude-opus-4", stopReason: nil,
                       cwd: nil, gitBranch: "feature-branch"),
        ]
    }

    func testFoldingInSlicesEqualsFoldingAtOnce() throws {
        let all = entries()
        let whole = try XCTUnwrap(
            ClaudeSessionJSONL.snapshot(fromEntries: all, sessionId: "seed"))

        // Every split point, so no boundary is special-cased by accident.
        for cut in 0...all.count {
            var acc = ClaudeSessionJSONL.SnapshotAccumulator(sessionId: "seed")
            ClaudeSessionJSONL.fold(Array(all[..<cut]), into: &acc)
            ClaudeSessionJSONL.fold(Array(all[cut...]), into: &acc)
            let incremental = try XCTUnwrap(ClaudeSessionJSONL.build(acc),
                                            "nil snapshot at cut \(cut)")
            XCTAssertEqual(incremental, whole, "incremental fold diverged at cut \(cut)")
        }
    }

    /// Cost and token totals accumulate, so a repeated fold of the same slice would double
    /// count. This pins that the tailer's contract is "fold each entry exactly once".
    func testAccumulatingFieldsAreNotDoubleCounted() throws {
        let all = entries()
        var acc = ClaudeSessionJSONL.SnapshotAccumulator(sessionId: "seed")
        ClaudeSessionJSONL.fold(all, into: &acc)
        let once = try XCTUnwrap(ClaudeSessionJSONL.build(acc))

        ClaudeSessionJSONL.fold(all, into: &acc)
        let twice = try XCTUnwrap(ClaudeSessionJSONL.build(acc))

        XCTAssertEqual(twice.totalInputTokens, once.totalInputTokens * 2,
                       "totals must accumulate, which is why the caller must never re-fold")
        XCTAssertEqual(twice.title, once.title, "last-wins fields must be idempotent")
    }
}
