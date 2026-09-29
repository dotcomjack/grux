import AppKit
import XCTest

/// `tools/grux-sweep.sh` on a headless Mac (`~/.grux/HEADLESS`) captures through
/// Grux's own `fire-headless-snapshot`, never `screencapture` (which raises a Screen
/// Recording prompt nobody can answer) and never `open -b` (which activates Grux onto
/// someone else's screen).
///
/// Measured 2026-09-28: the sweep found its window with `xcrun swift winid.swift`
/// and grabbed it with `screencapture`, so on the headless Mini it could only fail or
/// prompt, and its fallback activated the app. This runs the real script against a
/// fake Grux (a thread answering the trigger files) with fake `screencapture`, `open`
/// and `xcrun` that only record that they were called.
final class GruxSweepHeadlessTests: XCTestCase {

    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private var home: URL!
    private var calls: URL!
    private var stop = false

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("GruxSweepHeadless-\(UUID().uuidString)")
        let grux = home.appendingPathComponent(".grux")
        try FileManager.default.createDirectory(
            at: grux.appendingPathComponent("headless-workspace/shots"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: grux.appendingPathComponent("HEADLESS").path, contents: Data())
        let workspace = """
        {"headless":true,"windows":[
          {"id":7,"title":"","visible":false,"frame":[0,0,500,500]},
          {"id":42,"title":"Grux OS","visible":true,"frame":[1070,636,1100,592]}]}
        """
        try workspace.write(to: grux.appendingPathComponent("headless-workspace/workspace.json"),
                            atomically: true, encoding: .utf8)

        let bin = home.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        calls = home.appendingPathComponent("calls.log")
        for tool in ["screencapture", "open", "xcrun", "osascript"] {
            try fake(bin, tool, "echo \"\(tool) $*\" >> '\(calls.path)'")
        }
        try fake(bin, "pgrep", "echo 123")
    }

    override func tearDownWithError() throws {
        stop = true
        try? FileManager.default.removeItem(at: home)
    }

    private func fake(_ bin: URL, _ name: String, _ body: String) throws {
        let url = bin.appendingPathComponent(name)
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// A tab's picture: one solid colour per key, so every switch changes every pixel.
    private func png(for key: String) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1100, pixelsHigh: 592,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let h = key.unicodeScalars.reduce(UInt32(7)) { $0 &* 31 &+ $1.value }
        let c = NSColor(deviceRed: CGFloat(h % 256) / 255, green: CGFloat((h / 256) % 256) / 255,
                        blue: CGFloat((h / 65536) % 256) / 255, alpha: 1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        c.setFill()
        NSRect(x: 0, y: 0, width: 1100, height: 592).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    /// Answers `fire-open-tab` and `fire-headless-snapshot` the way the app does,
    /// naming each shot `<time>-<reason>-<window title>-<window id>.png` as
    /// `HeadlessWorkspace.snapshot` does.
    /// `snapshots: false` is a Grux too busy to render: it acks tabs and never snapshots.
    /// `answering` is how many snapshots it renders before it stops rendering.
    /// `ownSnapshotAfter`: Grux also snapshots on its own after each render and
    /// rewrites `snapshot-result.json` then (measured 50 to 70 ms after the
    /// sweep's), so the result naming the sweep's token is gone almost at once.
    /// `corrupt`: every shot is bytes no image reader accepts.
    /// Every token it is asked to snapshot is appended to `reasons.log`.
    private func startFakeGrux(snapshots: Bool = true, answering limit: Int = .max,
                               ownSnapshotAfter: Bool = false, corrupt: Bool = false) {
        let grux = home.appendingPathComponent(".grux")
        let ws = grux.appendingPathComponent("headless-workspace")
        Thread.detachNewThread { [weak self] in
            var current = "home"
            var n = 0
            while let self, !self.stop {
                let fm = FileManager.default
                let tab = grux.appendingPathComponent("fire-open-tab")
                if let key = try? String(contentsOf: tab, encoding: .utf8) {
                    try? fm.removeItem(at: tab)
                    current = key
                    try? key.write(to: grux.appendingPathComponent("open-tab-ack.txt"), atomically: true, encoding: .utf8)
                }
                let snap = grux.appendingPathComponent("fire-headless-snapshot")
                if snapshots, n < limit, let reason = try? String(contentsOf: snap, encoding: .utf8) {
                    try? fm.removeItem(at: snap)
                    n += 1
                    let log = self.home.appendingPathComponent("reasons.log")
                    if let h = try? FileHandle(forWritingTo: log) {
                        h.seekToEndOfFile(); h.write(Data((reason + "\n").utf8)); try? h.close()
                    } else {
                        try? (reason + "\n").write(to: log, atomically: true, encoding: .utf8)
                    }
                    var reasons = [reason]
                    if ownSnapshotAfter { reasons.append(current) }
                    for (i, why) in reasons.enumerated() {
                        let stamp = String(format: "20260928-000000-%03d", (2 * n + i) % 1000)
                        let hidden = ws.appendingPathComponent("shots/\(stamp)-\(why)-nswindow-7.png")
                        let shot = ws.appendingPathComponent("shots/\(stamp)-\(why)-grux-os-42.png")
                        try? self.png(for: "hidden").write(to: hidden)
                        try? (corrupt ? Data("not a png".utf8) : self.png(for: current)).write(to: shot)
                        let result: [String: Any] = ["reason": why, "renderedTab": current,
                                                     "files": [hidden.path, shot.path]]
                        try? JSONSerialization.data(withJSONObject: result)
                            .write(to: ws.appendingPathComponent("snapshot-result.json"), options: .atomic)
                    }
                }
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
    }

    /// `python3 -m site --user-base` under the real HOME.
    private func userBase() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", "-m", "site", "--user-base"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return out.isEmpty ? nil : out
    }

    /// The python3 the sweep would find on the test's PATH, past the fakes.
    private func realPython() -> String? {
        ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func runSweep(_ tabs: [String], extraEnv: [String: String] = [:]) throws -> (Int32, String) {
        let out = home.appendingPathComponent("out")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = [root.appendingPathComponent("tools/grux-sweep.sh").path, "t"] + tabs
        var env = ProcessInfo.processInfo.environment
        // framediff.py's Pillow may live in the user site, which Python finds through HOME.
        if env["PYTHONUSERBASE"] == nil, let base = userBase() { env["PYTHONUSERBASE"] = base }
        env["HOME"] = home.path
        env["PATH"] = home.appendingPathComponent("bin").path + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["GRUX_SWEEP_OUT"] = out.path
        env["GRUX_SWEEP_SHELL"] = "panel"
        env.merge(extraEnv) { $1 }
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let deadline = Date().addingTimeInterval(60)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if p.isRunning { p.terminate(); p.waitUntilExit() }
        let log = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (p.terminationStatus, log)
    }

    func test_headlessSweepCapturesThroughGruxAndNeverTheScreen() throws {
        startFakeGrux()
        let out = home.appendingPathComponent("out")
        let (status, log) = try runSweep(["chat", "mail", "settings"])
        let called = (try? String(contentsOf: calls, encoding: .utf8)) ?? ""
        XCTAssertEqual(called, "", "a headless sweep reached the screen or activated an app:\n\(called)\n\(log)")
        XCTAssertEqual(status, 0, log)
        for tab in ["chat", "mail", "settings"] {
            let shot = out.appendingPathComponent("t-\(tab).png")
            XCTAssertEqual(try? Data(contentsOf: shot), png(for: tab), "\(tab) is not that tab's picture\n\(log)")
        }
        XCTAssertTrue(log.contains("headless"), log)
    }

    /// No baseline means nothing to compare a tab against, so no tab can be certified.
    /// Measured live: right after a launch Grux spent 15 s opening Chat, every snapshot
    /// wait ran out, and the sweep certified `tuning (0 px)` from a file it never checked.
    func test_aSweepThatCannotCaptureCertifiesNothing() throws {
        startFakeGrux(snapshots: false)
        let (status, log) = try runSweep(["chat", "mail"], extraEnv: ["GRUX_SWEEP_SNAP_WAIT": "1"])
        XCTAssertNotEqual(status, 0, log)
        let written = (try? FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent("out").path)) ?? []
        XCTAssertFalse(written.contains("t-chat.png") || written.contains("t-mail.png"), "certified a tab it never captured: \(written)\n\(log)")
        XCTAssertTrue(log.contains("baseline"), log)
    }

    /// RV31: a frame that never arrives is a failure, not a settled frame. Grux here
    /// renders the pre-switch frame, the baseline (Chat) and its settle check, then Mail
    /// once, and never the frame that would prove Mail had stopped moving. A missing
    /// frame compared to anything measured 0, which read as settled, and Mail was certified.
    func test_aSnapshotThatNeverArrivesFailsTheSweep() throws {
        startFakeGrux(answering: 4)
        // 3 s, not 1: on a loaded host one slow frame must not stand in for the missing one.
        let (status, log) = try runSweep(["mail"], extraEnv: ["GRUX_SWEEP_SNAP_WAIT": "3"])
        XCTAssertNotEqual(status, 0, log)
        XCTAssertTrue(log.contains("no frame of mail"), log)
        let written = (try? FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent("out").path)) ?? []
        XCTAssertFalse(written.contains("t-mail.png"), "certified a tab whose settle frame never came: \(written)\n\(log)")
    }

    /// Final sweep, 2026-09-28: every run failed "no frame arrived". The sweep
    /// polled the one `snapshot-result.json`, which Grux's own post-tab snapshot
    /// overwrites 50 to 70 ms after the sweep's, so the result naming the token
    /// was gone before the next poll. The token's own file in `shots/` stays.
    func test_aResultOverwrittenByGruxsOwnSnapshotStillFindsTheFrame() throws {
        startFakeGrux(ownSnapshotAfter: true)
        let out = home.appendingPathComponent("out")
        let (status, log) = try runSweep(["chat", "mail", "settings"], extraEnv: ["GRUX_SWEEP_SNAP_WAIT": "3"])
        XCTAssertEqual(status, 0, log)
        for tab in ["chat", "mail", "settings"] {
            let shot = out.appendingPathComponent("t-\(tab).png")
            XCTAssertEqual(try? Data(contentsOf: shot), png(for: tab), "\(tab) is not that tab's picture\n\(log)")
        }
    }

    /// Final sweep: a framediff.py that cannot run (here, a python3 with no
    /// Pillow, as `/usr/bin/python3` is when env.sh was not sourced) printed
    /// nothing, the sweep read that as 0 px, and a working app was reported as
    /// "NEVER DIVERGED". A diff that cannot run ends the sweep and says why.
    func test_aFrameDiffThatCannotRunFailsLoudlyInsteadOfMeasuringZero() throws {
        let python = try XCTUnwrap(realPython(), "no python3 to run the sweep with")
        try fake(home.appendingPathComponent("bin"), "python3", """
        case "$1" in *framediff.py) echo "ModuleNotFoundError: No module named 'PIL'" >&2; exit 1;; esac
        exec \(python) "$@"
        """)
        startFakeGrux()
        let (status, log) = try runSweep(["chat", "mail"], extraEnv: ["GRUX_SWEEP_SNAP_WAIT": "3"])
        XCTAssertNotEqual(status, 0, log)
        XCTAssertTrue(log.contains("framediff.py could not compare"), log)
        XCTAssertTrue(log.contains("No module named 'PIL'"), "the reason is not shown:\n\(log)")
        XCTAssertFalse(log.contains("NEVER DIVERGED"), log)
        XCTAssertFalse(log.contains("(0 px)"), log)
        let written = (try? FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent("out").path)) ?? []
        XCTAssertFalse(written.contains { $0.hasPrefix("t-chat") || $0.hasPrefix("t-mail") }, "\(written)\n\(log)")
        assertCleanedUpAndRestored(log)
    }

    /// Review of e125705: a sweep that stops early (exit 1 or 2) still puts the
    /// app back on Home and leaves none of its working frames behind.
    private func assertCleanedUpAndRestored(_ log: String, file: StaticString = #filePath, line: UInt = #line) {
        let written = (try? FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent("out").path)) ?? []
        XCTAssertFalse(written.contains { $0.contains("-_") }, "working frames left behind: \(written)\n\(log)",
                       file: file, line: line)
        let ack = try? String(contentsOf: home.appendingPathComponent(".grux/open-tab-ack.txt"), encoding: .utf8)
        XCTAssertEqual(ack, "home", "the app was left on another tab\n\(log)", file: file, line: line)
    }

    /// Review of e125705: framediff.py read an unreadable frame as "totally
    /// different", so a garbage capture could be certified as a tab.
    func test_anUnreadableFrameFailsTheSweepInsteadOfCountingAsChanged() throws {
        startFakeGrux(corrupt: true)
        let (status, log) = try runSweep(["chat", "mail"], extraEnv: ["GRUX_SWEEP_SNAP_WAIT": "3"])
        XCTAssertNotEqual(status, 0, log)
        XCTAssertTrue(log.contains("framediff.py could not compare"), log)
        let written = (try? FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent("out").path)) ?? []
        XCTAssertFalse(written.contains { $0.hasPrefix("t-chat") || $0.hasPrefix("t-mail") }, "\(written)\n\(log)")
        assertCleanedUpAndRestored(log)
    }

    /// A sweep that cannot capture at all (exit 1) cleans up and restores too.
    func test_aSweepThatStopsEarlyStillRestoresTheApp() throws {
        startFakeGrux(answering: 4)
        let (status, log) = try runSweep(["mail"], extraEnv: ["GRUX_SWEEP_SNAP_WAIT": "3"])
        XCTAssertNotEqual(status, 0, log)
        assertCleanedUpAndRestored(log)
    }

    /// Review of e125705: a frame is this sweep's own only if its token is. A
    /// token of pid and counter alone matches a file an earlier sweep left
    /// under a recycled pid, so each sweep adds a nonce of its own.
    func test_eachSweepAsksForFramesUnderItsOwnNonce() throws {
        startFakeGrux()
        let (status, log) = try runSweep(["chat"])
        XCTAssertEqual(status, 0, log)
        let reasons = ((try? String(contentsOf: home.appendingPathComponent("reasons.log"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
        XCTAssertFalse(reasons.isEmpty, log)
        let shape = #"^sweep-[0-9]+-[0-9a-z]{6,}-[0-9]+$"#
        for r in reasons { XCTAssertNotNil(r.range(of: shape, options: .regularExpression), "token without a nonce: \(r)") }
        let nonces = Set(reasons.map { $0.split(separator: "-")[2] })
        XCTAssertEqual(nonces.count, 1, "one sweep, one nonce: \(reasons)")
        XCTAssertLessThanOrEqual(reasons.first?.count ?? 99, 40, "the app keeps 40 characters of a token in a file name")
    }
}
