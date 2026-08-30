import XCTest
@testable import Grux
import GruxShellCore

/// HOW MUCH THE SHELL IS TRUSTED, AND WHO DECIDES.
///
/// Measured 2026-08-26: the model decided. `ShellTool.claudeTools()` publishes
/// `mode` as an ordinary tool argument with the enum `trust`, `guarded`,
/// `strict`, and `ShellDispatcher` reads it as
/// `(input["mode"] as? String) ?? "guarded"`. That default only applies when the
/// model OMITS the field. When it supplies one, that is what the session runs
/// under for its whole life, because the mode is stored once at start and every
/// later `shell_run` inherits it. No reference to the shell mode existed in
/// Settings or `AppState`, so the user could not see the value and could not
/// change it.
///
/// The top of that dial is not a convenience setting. `ShellSafety.evaluate`
/// only consults `detectNetworkOrExternalEffect` when `mode != .trust`, so
/// `trust` removes the confirmation gate on network sends, deploys and force
/// pushes. And the model chooses its arguments while reasoning over text it did
/// not write: a file it just read, a page it just fetched. "Start the session in
/// trust mode" is a sentence an attacker can put in a README.
///
/// Same shape as `SessionConcurrency`, and the same conclusion: telling somebody
/// to keep a setting conservative while the setting is out of their hands is not
/// advice, it is decoration.
final class ShellTrustCeilingTests: XCTestCase {

    private var original: Any?
    private var originalRoots: Any?

    override func setUp() {
        super.setUp()
        original = UserDefaults.standard.object(forKey: ShellTrustCeiling.defaultsKey)
        // The live-session tests below point the shell allowlist at a temporary
        // directory. Saved and restored here rather than in those tests so a
        // failing assertion cannot leave the operator's real project root
        // rewritten in their own preferences.
        originalRoots = UserDefaults.standard.object(forKey: ShellAllowlist.watchedRootDefaultsKey)
    }

    override func tearDown() {
        if let original {
            UserDefaults.standard.set(original, forKey: ShellTrustCeiling.defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: ShellTrustCeiling.defaultsKey)
        }
        if let originalRoots {
            UserDefaults.standard.set(originalRoots, forKey: ShellAllowlist.watchedRootDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: ShellAllowlist.watchedRootDefaultsKey)
        }
        super.tearDown()
    }

    // MARK: - The ordering the clamp is built on

    func testStrictIsMoreRestrictiveThanGuardedIsMoreRestrictiveThanTrust() {
        // The clamp is a comparison, so if this ordering is ever written
        // backwards the clamp silently becomes a floor and every assertion about
        // "never raises" below still passes on the pairs that happen to agree.
        XCTAssertGreaterThan(ShellTrustCeiling.restrictiveness(.strict),
                             ShellTrustCeiling.restrictiveness(.guarded),
                             "strict is not ranked above guarded")
        XCTAssertGreaterThan(ShellTrustCeiling.restrictiveness(.guarded),
                             ShellTrustCeiling.restrictiveness(.trust),
                             "guarded is not ranked above trust")

        // And the order a Settings picker renders has to agree with it, or the
        // control reads as a dial pointing the wrong way.
        let ranks = ShellTrustCeiling.selectableModes.map(ShellTrustCeiling.restrictiveness)
        XCTAssertEqual(ranks, ranks.sorted(by: >),
                       "selectableModes is not ordered most restrictive first: \(ShellTrustCeiling.selectableModes)")
        XCTAssertEqual(Set(ShellTrustCeiling.selectableModes.map(\.rawValue)),
                       ["strict", "guarded", "trust"],
                       "a mode exists that Settings would never be able to offer")
    }

    // MARK: - The default

    func testTheDefaultWithNoStoredValueIsConservative() {
        UserDefaults.standard.removeObject(forKey: ShellTrustCeiling.defaultsKey)
        XCTAssertEqual(ShellTrustCeiling.ceiling, ShellTrustCeiling.conservativeDefault)
        XCTAssertNotEqual(ShellTrustCeiling.ceiling, .trust,
                          "an install that never opens Settings hands the model the ungated mode, "
                          + "which is the exact case this type exists to close")
        // And the default actually bites: with nothing stored, a model asking
        // for trust does not get it.
        XCTAssertEqual(ShellTrustCeiling.clamp(.trust), ShellTrustCeiling.conservativeDefault)
    }

    // MARK: - The clamp, over every pair

    func testClampLowersButNeverRaisesAcrossEveryModePair() {
        // Nine combinations, written as a loop rather than nine assertions so a
        // fourth mode added later is covered the day it is added rather than the
        // day somebody remembers this file.
        for ceiling in ShellTrustCeiling.selectableModes {
            ShellTrustCeiling.ceiling = ceiling
            for requested in ShellTrustCeiling.selectableModes {
                let got = ShellTrustCeiling.clamp(requested)

                XCTAssertGreaterThanOrEqual(
                    ShellTrustCeiling.restrictiveness(got),
                    ShellTrustCeiling.restrictiveness(requested),
                    "ceiling \(ceiling.rawValue) RAISED a request for \(requested.rawValue) to \(got.rawValue)"
                )
                XCTAssertGreaterThanOrEqual(
                    ShellTrustCeiling.restrictiveness(got),
                    ShellTrustCeiling.restrictiveness(ceiling),
                    "ceiling \(ceiling.rawValue) let \(requested.rawValue) through as \(got.rawValue)"
                )

                // A request at or below the ceiling is honoured unchanged. A
                // clamp that promoted every caller to the ceiling would be the
                // same defect running the other way: a caller that asks for
                // strict knows something the ceiling does not.
                if ShellTrustCeiling.restrictiveness(requested) >= ShellTrustCeiling.restrictiveness(ceiling) {
                    XCTAssertEqual(got, requested,
                                   "ceiling \(ceiling.rawValue) rewrote a safe request for \(requested.rawValue)")
                } else {
                    XCTAssertEqual(got, ceiling,
                                   "ceiling \(ceiling.rawValue) did not pull \(requested.rawValue) down to itself")
                }
            }
        }
    }

    func testTheOneCaseThatMatters() {
        // Stated on its own as well as inside the loop, because this is the
        // finding and a loop that stopped covering it would still be green.
        ShellTrustCeiling.ceiling = .strict
        XCTAssertEqual(ShellTrustCeiling.clamp(.trust), .strict,
                       "the model asked for trust and got it while the user had set strict")
        ShellTrustCeiling.ceiling = .guarded
        XCTAssertEqual(ShellTrustCeiling.clamp(.trust), .guarded)
        ShellTrustCeiling.ceiling = .trust
        XCTAssertEqual(ShellTrustCeiling.clamp(.trust), .trust,
                       "a user who explicitly chose trust is being overruled by their own setting")
    }

    // MARK: - A stored value that is not a mode

    func testAStoredValueOutOfRangeIsClamped() {
        // A preference key is reachable by anything: `defaults write`, a botched
        // migration, a sync from another machine. The failure mode has to be the
        // conservative default, never a crash and never the permissive end.
        UserDefaults.standard.set("yolo", forKey: ShellTrustCeiling.defaultsKey)
        XCTAssertEqual(ShellTrustCeiling.ceiling, ShellTrustCeiling.conservativeDefault,
                       "an unparseable stored mode did not fall back")
        XCTAssertEqual(ShellTrustCeiling.clamp(.trust), ShellTrustCeiling.conservativeDefault)

        // The empty string is its own case: it parses as neither a mode nor an
        // absence, and `""` is what a cleared text field writes.
        UserDefaults.standard.set("", forKey: ShellTrustCeiling.defaultsKey)
        XCTAssertEqual(ShellTrustCeiling.ceiling, ShellTrustCeiling.conservativeDefault)

        // Wrong TYPE, which is the one `string(forKey:)` would have coerced
        // instead of rejecting. A stored `1` must not become a mode.
        UserDefaults.standard.set(1, forKey: ShellTrustCeiling.defaultsKey)
        XCTAssertEqual(ShellTrustCeiling.ceiling, ShellTrustCeiling.conservativeDefault)

        UserDefaults.standard.set(["strict"], forKey: ShellTrustCeiling.defaultsKey)
        XCTAssertEqual(ShellTrustCeiling.ceiling, ShellTrustCeiling.conservativeDefault)
    }

    func testAValidStoredValueIsHonoured() {
        // The counterpart to the test above, and it has to be here: a getter
        // that returned the conservative default for EVERYTHING would pass every
        // fallback assertion and quietly make the setting unusable.
        for mode in ShellTrustCeiling.selectableModes {
            UserDefaults.standard.set(mode.rawValue, forKey: ShellTrustCeiling.defaultsKey)
            XCTAssertEqual(ShellTrustCeiling.ceiling, mode,
                           "a stored \(mode.rawValue) did not survive a round trip")
        }
    }

    // MARK: - The raw tool argument

    func testAnAbsentModeIsClampedAndATypoIsNotGuessedAt() {
        ShellTrustCeiling.ceiling = .strict

        // Absent means the model expressed no preference, so the documented
        // default is what gets clamped. Before this, an omitted mode landed on
        // guarded even for a user who had asked for strict.
        XCTAssertEqual(ShellTrustCeiling.clampRawMode(nil), .strict)
        XCTAssertEqual(ShellTrustCeiling.clampRawMode(""), .strict)

        XCTAssertEqual(ShellTrustCeiling.clampRawMode("trust"), .strict)
        XCTAssertEqual(ShellTrustCeiling.clampRawMode("guarded"), .strict)
        XCTAssertEqual(ShellTrustCeiling.clampRawMode("strict"), .strict)

        ShellTrustCeiling.ceiling = .trust
        XCTAssertEqual(ShellTrustCeiling.clampRawMode("guarded"), .guarded,
                       "a request BELOW the ceiling was promoted to it")

        // A typo returns nil so the dispatcher's existing "unknown mode" error
        // still fires. Coercing it to a valid mode would trade a clear refusal
        // for a silent guess, and the guess would be invisible to the user.
        XCTAssertNil(ShellTrustCeiling.clampRawMode("trusted"))
        XCTAssertNil(ShellTrustCeiling.clampRawMode("TRUST"))
    }

    // MARK: - The clamp is applied, not merely defined

    /// A ceiling the request never passes through is decoration, which is the
    /// whole defect repeating one layer up. `ShellTrustCeiling` lives in the app
    /// target and `ShellDispatcher` lives in `GruxShellCore`, which cannot import
    /// the app, so the clamp has to sit on the app side of that boundary. This
    /// asserts that the boundary has exactly one door and that the clamp is
    /// nailed to it.
    ///
    /// Driving the real path instead would mean starting a PTY-backed bash
    /// session against a real directory inside a unit test, so this reads the
    /// source. That is the same trade `DenylistParityTests` makes and it is
    /// worth naming: this proves the call site exists and is ordered correctly,
    /// not that the process behaved.
    func testNothingInTheAppReachesTheDispatcherExceptShellTool() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // GruxTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // Grux-Mac
            .appendingPathComponent("Sources/Grux")

        var walked = 0
        var callers: [String] = []
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        for case let url as URL in walker where url.pathExtension == "swift" {
            walked += 1
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if text.contains("ShellDispatcher.dispatch(") {
                callers.append(url.lastPathComponent)
            }
        }

        // Anti-vacuity. A walker pointed at the wrong directory finds no callers
        // and passes, which is the failure that looks like success.
        XCTAssertGreaterThan(walked, 100, "only \(walked) Swift files walked; the scan is looking in the wrong place")
        XCTAssertEqual(callers.sorted(), ["ShellTool.swift"], """
            \(callers.count) file(s) in the app target call ShellDispatcher.dispatch: \
            \(callers.sorted().joined(separator: ", ")).
            The trust ceiling is applied in ShellTool.dispatch, so any other caller runs the shell \
            with whatever mode the model asked for and the ceiling becomes decoration. Route it \
            through ShellTool, or move the clamp somewhere both callers pass.
            """)
    }

    func testShellToolClampsBeforeItCallsTheDispatcher() throws {
        let tool = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/ShellTool/ShellTool.swift")
        let text = try String(contentsOf: tool, encoding: .utf8)

        let clampAt = try XCTUnwrap(text.range(of: "ShellTrustCeiling.clampRawMode"),
                                    "ShellTool.swift no longer applies the trust ceiling at all")
        let dispatchAt = try XCTUnwrap(text.range(of: "ShellDispatcher.dispatch("))
        XCTAssertLessThan(clampAt.lowerBound, dispatchAt.lowerBound,
                          "the clamp is applied after the call it is meant to bound")
        XCTAssertTrue(text.contains(#"input["mode"] = clamped.rawValue"#),
                      "the clamped value is computed and then thrown away")
    }

    // MARK: - The ceiling on the path that actually reaches the shell
    //
    // EVERY TEST ABOVE THIS LINE IS ARITHMETIC OR A SOURCE GREP.
    //
    // The clamp lands on `shell_start`'s `mode` argument, and that binds the
    // session's stored mode. It does not bind `shell_run_confirmed`, which
    // carries no `mode` argument at all: `ShellSession.runConfirmed` evaluates
    // with a hardcoded `.trust` and then discards the strict allowlist verdict
    // along with the confirm verdict. Measured 2026-08-26 on this tree: a session
    // the ceiling had pinned to `strict` would run any binary at all through one
    // confirmed call, with no biometric prompt on a default install and with no
    // prior refusal needed to launder, while Settings told the user the session
    // "runs only an allowlist of development tools, and refuses anything else".
    // The suite was green throughout, because nothing drove that tool.
    //
    // So these two spawn a real bash and a real shadow-git store against a
    // temporary directory. That is the cost of proving the process behaved
    // rather than proving a source file contains a string, and the previous
    // section says plainly that it was not paid.
    //
    // `ShellTool.dispatch` for the start, so the clamp genuinely runs.
    // `ShellDispatcher.dispatch` for the run legs, and the split is deliberate:
    // `ShellTool` puts `SensitiveActionGate` in front of the confirmed path, and
    // that gate reads a policy file out of the operator's Application Support
    // directory, so a machine with the "Dangerous shell commands" toggle on would
    // open a biometric sheet in the middle of `swift test`. The two calls are
    // otherwise identical and `testShellToolClampsBeforeItCallsTheDispatcher`
    // pins that `ShellTool` forwards to the dispatcher.
    //
    // These append to the shared shell audit log, because a command that ran is
    // supposed to leave a line. `shell_end` tears the shadow repo back down.

    /// The `session_id:` line out of a `shell_start` response.
    private static func sessionId(in response: String) -> String? {
        for line in response.split(separator: "\n") where line.hasPrefix("session_id: ") {
            return String(line.dropFirst("session_id: ".count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// A directory the shell allowlist will accept, torn down by the caller.
    private func makeTemporaryRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grux-ceiling-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        UserDefaults.standard.set([root.path], forKey: ShellAllowlist.watchedRootDefaultsKey)
        return root
    }

    func testShellRunConfirmedCannotWalkAroundAStrictCeiling() async {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        ShellTrustCeiling.ceiling = .strict

        // The model asks for the ungated mode. The clamp answers strict.
        let started = await ShellTool.dispatch(name: "shell_start", input: [
            "root_dir": root.path,
            "mode": "trust",
            "mirror": false
        ])
        XCTAssertTrue(started.contains("mode: strict"),
                      "the session did not start under the ceiling, so nothing below proves "
                      + "anything: \(started)")
        guard let sessionId = Self.sessionId(in: started) else {
            return XCTFail("shell_start returned no session_id: \(started)")
        }

        // `touch` is not on the strict allowlist, and a file on disk is proof of
        // execution that no amount of reading the response text can fake. The
        // finding's own exploit is a `curl` POST, which has the same shape and
        // the same verdict; this spelling is used because a test that fires a
        // real request when it regresses is a test nobody can safely run.
        let proof = root.appendingPathComponent("proof.txt")
        let blocked = await ShellDispatcher.dispatch(name: "shell_run_confirmed", input: [
            "session_id": sessionId,
            "command": "touch proof.txt"
        ])
        XCTAssertTrue(blocked.hasPrefix("blocked:"),
                      "the confirmed path ran a command the strict allowlist refuses: \(blocked)")
        XCTAssertTrue(blocked.contains("not on allowlist"), blocked)
        XCTAssertFalse(FileManager.default.fileExists(atPath: proof.path),
                       "the command executed anyway, so only the response text changed")

        // And the same door still opens for what strict does allow. A ceiling
        // that refused the whole confirmed path would delete the feature rather
        // than bound it, and it would pass the assertion above.
        let allowed = await ShellDispatcher.dispatch(name: "shell_run_confirmed", input: [
            "session_id": sessionId,
            "command": "echo confirmed-ran > allowed.txt"
        ])
        XCTAssertTrue(allowed.contains("ok (confirmed)"), allowed)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("allowed.txt").path),
            "an allowlisted command was refused on the confirmed path: \(allowed)")

        _ = await ShellDispatcher.dispatch(name: "shell_end", input: ["session_id": sessionId])
    }

    func testAGuardedSessionStillGetsTheConfirmedPathItWasBuiltFor() async {
        // The counterpart, and it has to be here. Refusing `.requiresConfirm` on
        // this path as well would pass every assertion in the test above and
        // remove the only way a user can ever say "push it". The confirmed tool
        // lifts the CONFIRM gate; it was never entitled to lift the allowlist.
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        ShellTrustCeiling.ceiling = .guarded

        let started = await ShellTool.dispatch(name: "shell_start", input: [
            "root_dir": root.path,
            "mode": "trust",
            "mirror": false
        ])
        XCTAssertTrue(started.contains("mode: guarded"), started)
        guard let sessionId = Self.sessionId(in: started) else {
            return XCTFail("shell_start returned no session_id: \(started)")
        }

        // Harmless text that the external-effect detector reads as a publish, so
        // the gate fires without the test doing anything to the outside world.
        let command = "echo 'npm publish'"
        let gated = await ShellDispatcher.dispatch(name: "shell_run", input: [
            "session_id": sessionId,
            "command": command
        ])
        XCTAssertTrue(gated.hasPrefix("gated:"),
                      "the network gate stopped firing, so the confirmed path below is no longer "
                      + "the path under test: \(gated)")

        let ran = await ShellDispatcher.dispatch(name: "shell_run_confirmed", input: [
            "session_id": sessionId,
            "command": command
        ])
        XCTAssertTrue(ran.contains("ok (confirmed)"),
                      "a guarded session could not run a command the user confirmed: \(ran)")

        _ = await ShellDispatcher.dispatch(name: "shell_end", input: ["session_id": sessionId])
    }
}
