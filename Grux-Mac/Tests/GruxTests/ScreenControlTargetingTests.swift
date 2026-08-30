import AppKit
import CoreGraphics
import XCTest
@testable import Grux

/// WHICH APP `list_ui` READS, which is the only screen-control decision whose
/// wrongness is invisible.
///
/// Every other path in `ScreenControlEngine` fails loudly: a bad coordinate is
/// rejected, an unknown key name comes back as an error string, a missing grant
/// is an actionable sentence. Target resolution is the exception. It always
/// returns AN app, so a wrong answer looks exactly like a right one, and every
/// coordinate the model derives from it is then wrong in the same silent way.
///
/// The shipped version picked `runningApplications.first(where: regular && not
/// Grux && not hidden)`. `NSWorkspace.runningApplications` has NO DEFINED ORDER.
/// It is not z-ordered and not MRU-ordered, so "the app behind Grux" was in
/// practice whichever regular app happened to sit first in the array, usually
/// Finder or the earliest-launched app. `isHidden` compounded it: an app whose
/// windows are all minimised reports `isHidden == false`, so a minimised app
/// could win too.
///
/// The choice is tested as a PURE FUNCTION over a described window stack,
/// because the real one depends on what the developer happens to have open, and
/// a test that depends on that proves nothing on anybody else's machine.
final class ScreenControlTargetingTests: XCTestCase {

    private let selfPID: pid_t = 501
    private let finder = ScreenControlEngine.AppCandidate(
        pid: 100, bundleID: "com.apple.finder", name: "Finder", isRegular: true)
    private let chrome = ScreenControlEngine.AppCandidate(
        pid: 200, bundleID: "com.google.Chrome", name: "Google Chrome", isRegular: true)
    private let grux = ScreenControlEngine.AppCandidate(
        pid: 501, bundleID: "com.gruxai.grux", name: "Grux", isRegular: true)
    private let menuExtra = ScreenControlEngine.AppCandidate(
        pid: 300, bundleID: "com.example.menubar", name: "Menu Thing", isRegular: false)

    // MARK: - THE BUG

    /// The documented scenario, exactly. The operator is talking to Grux in the
    /// chat window, Chrome is the window immediately behind it, and Finder is
    /// buried at the back but sits earlier in `runningApplications`.
    ///
    /// The shipped code returned Finder here. It then handed the model Finder's
    /// AX tree with Finder's global coordinates, and the very next `click` in
    /// the LOCATE-then-ACT loop landed on whatever was painted at those points.
    func testWhenGruxIsFrontmostItTargetsTheWindowBehindItAndNotArrayOrder() {
        let picked = ScreenControlEngine.pickTarget(
            hint: nil,
            // Deliberately the order the OS actually hands back: NOT z-order.
            candidates: [finder, grux, chrome],
            frontToBack: [501, 200, 100],
            frontmostPID: 501,
            selfPID: selfPID)

        XCTAssertEqual(picked, chrome,
                       "Chrome is the window behind Grux. Finder is first in runningApplications "
                       + "and last on screen, and that array position is not a fact about the screen.")
    }

    /// Z-order is READ, not assumed. Same app set, different stack, different
    /// answer. If this returned the same app as the test above, the resolver
    /// would be ignoring the window list it claims to consult.
    func testTheAnswerFollowsTheWindowStackRatherThanTheAppList() {
        let picked = ScreenControlEngine.pickTarget(
            hint: nil,
            candidates: [finder, grux, chrome],
            frontToBack: [501, 100, 200],
            frontmostPID: 501,
            selfPID: selfPID)

        XCTAssertEqual(picked, finder, "Finder is now the window behind Grux and should win")
    }

    /// A minimised app is not "behind" anything. Its windows are off screen, so
    /// it never appears in the on-screen window list, and clicking coordinates
    /// read from it would hit whatever is actually painted there.
    ///
    /// This is the `isHidden` half of the bug and it needed no new flag to fix:
    /// asking the window server which windows are ON SCREEN excludes minimised
    /// ones for free, where `NSRunningApplication.isHidden` never did.
    func testAMinimisedAppIsNotTreatedAsTheAppBehind() {
        // Chrome is running and not hidden, but has no on-screen window.
        let picked = ScreenControlEngine.pickTarget(
            hint: nil,
            candidates: [chrome, grux, finder],
            frontToBack: [501, 100],
            frontmostPID: 501,
            selfPID: selfPID)

        XCTAssertEqual(picked, finder,
                       "Chrome is minimised, so it is not the app behind Grux even though "
                       + "runningApplications lists it first and isHidden is false")
    }

    /// Menu bar agents, overlays and other `.accessory` apps own on-screen
    /// windows but are never what an operator means by "the app I was just
    /// looking at".
    func testAccessoryAppsAreSkippedWhenLookingBehindGrux() {
        let picked = ScreenControlEngine.pickTarget(
            hint: nil,
            candidates: [grux, menuExtra, chrome],
            frontToBack: [501, 300, 200],
            frontmostPID: 501,
            selfPID: selfPID)

        XCTAssertEqual(picked, chrome, "a menu bar agent is not the app the operator is working in")
    }

    /// NEVER GUESS. With nothing behind Grux the honest answer is none, which
    /// the tool turns into "bring the app you want to control to the front".
    /// The shipped code fell through to returning Grux itself, so the model got
    /// a tree of the assistant's own window and no signal that it had.
    func testNothingBehindGruxResolvesToNothingRatherThanAGuess() {
        XCTAssertNil(ScreenControlEngine.pickTarget(
            hint: nil,
            candidates: [grux],
            frontToBack: [501],
            frontmostPID: 501,
            selfPID: selfPID),
            "with only Grux on screen there is no app behind it, and a guess here is a wrong click")
    }

    // MARK: - The ordinary case

    /// When the operator is looking at something other than Grux, that is the
    /// answer and no window walking is needed.
    func testWhenAnotherAppIsFrontmostItIsTheTarget() {
        let picked = ScreenControlEngine.pickTarget(
            hint: nil,
            candidates: [finder, grux, chrome],
            frontToBack: [200, 501, 100],
            frontmostPID: 200,
            selfPID: selfPID)

        XCTAssertEqual(picked, chrome)
    }

    // MARK: - The hint path

    /// An EXACT name match beats a substring match, whichever way round the
    /// array happens to be.
    ///
    /// The shipped matcher was one `first(where:)` with exact and `contains`
    /// ORed together, so over an unordered array "Mail" resolved to Mailplane
    /// whenever Mailplane came first. Same root cause as the bug above: a
    /// preference expressed as array position is not a preference.
    func testAnExactNameBeatsASubstringMatch() {
        let mail = ScreenControlEngine.AppCandidate(
            pid: 10, bundleID: "com.apple.mail", name: "Mail", isRegular: true)
        let mailplane = ScreenControlEngine.AppCandidate(
            pid: 11, bundleID: "com.mailplaneapp.Mailplane3", name: "Mailplane", isRegular: true)

        XCTAssertEqual(ScreenControlEngine.pickTarget(
            hint: "Mail", candidates: [mailplane, mail],
            frontToBack: [11, 10], frontmostPID: 11, selfPID: selfPID), mail,
            "the app literally called Mail is what \"Mail\" means")
    }

    /// Case and surrounding whitespace are not part of the question.
    func testTheHintIsMatchedCaseAndWhitespaceInsensitively() {
        XCTAssertEqual(ScreenControlEngine.pickTarget(
            hint: "  GOOGLE CHROME ", candidates: [finder, chrome],
            frontToBack: [100, 200], frontmostPID: 100, selfPID: selfPID), chrome)
    }

    /// A bundle id is a legal hint, and the tool's schema advertises it.
    func testABundleIdIsAValidHint() {
        XCTAssertEqual(ScreenControlEngine.pickTarget(
            hint: "com.google.Chrome", candidates: [finder, chrome],
            frontToBack: [100, 200], frontmostPID: 100, selfPID: selfPID), chrome)
    }

    /// A substring still resolves when nothing matches better, because a user
    /// saying "chrome" should not have to say "Google Chrome".
    func testASubstringStillResolvesWhenNothingMatchesBetter() {
        XCTAssertEqual(ScreenControlEngine.pickTarget(
            hint: "chrome", candidates: [finder, chrome],
            frontToBack: [100, 200], frontmostPID: 100, selfPID: selfPID), chrome)
    }

    /// Two equally good substring matches are broken by what is actually in
    /// front, not by array position.
    func testTiedHintMatchesAreBrokenByWhatIsInFront() {
        let a = ScreenControlEngine.AppCandidate(
            pid: 20, bundleID: "com.a.notes", name: "Notes Pro", isRegular: true)
        let b = ScreenControlEngine.AppCandidate(
            pid: 21, bundleID: "com.b.notes", name: "Notes Lite", isRegular: true)

        XCTAssertEqual(ScreenControlEngine.pickTarget(
            hint: "notes", candidates: [a, b],
            frontToBack: [21, 20], frontmostPID: 21, selfPID: selfPID), b,
            "both match equally well, so the one the user is actually looking at wins")
    }

    /// An unmatched hint is an honest nil, not the frontmost app. Silently
    /// retargeting is how a click meant for one app lands in another.
    func testAnUnmatchedHintResolvesToNothing() {
        XCTAssertNil(ScreenControlEngine.pickTarget(
            hint: "Photoshop", candidates: [finder, chrome],
            frontToBack: [100, 200], frontmostPID: 100, selfPID: selfPID))
    }

    /// A hint may name Grux itself. That is explicit, so it is honoured: the
    /// self-skip exists to interpret silence, not to override an instruction.
    func testAnExplicitHintCanNameGruxItself() {
        XCTAssertEqual(ScreenControlEngine.pickTarget(
            hint: "Grux", candidates: [grux, chrome],
            frontToBack: [501, 200], frontmostPID: 501, selfPID: selfPID), grux)
    }

    // MARK: - The live wiring

    /// The pure function above is only worth anything if the real resolver
    /// actually feeds it the window server's z-order. This asserts the live
    /// reader returns a plausible stack on this machine, which is what makes
    /// the unit tests above a statement about production and not about a
    /// struct nobody calls.
    func testTheLiveWindowOrderReaderReturnsRealPIDs() throws {
        let order = ScreenControlEngine.onScreenPIDsFrontToBack()

        // AN EMPTY LIST IS A REAL ANSWER, NOT A BROKEN READER.
        //
        // A CI runner has no window server session, so there genuinely are no
        // on-screen windows and the correct return is []. The first version of
        // this test asserted non-empty, which made it pass on a desktop and fail
        // on every headless machine: the exact defect this same commit range
        // fixes in FirstRunChatTests, written by the same hand a few hours
        // later. Measured 2026-08-23: green locally, red on GitHub Actions.
        //
        // The logic this file actually guards is the pure `pickTarget`, which
        // runs everywhere. This one is the live wiring, and live wiring needs a
        // display to be live.
        try XCTSkipIf(order.isEmpty,
                      "no on-screen windows: this host has no window server session")

        XCTAssertEqual(order.count, Set(order).count, "the same app must appear once, at its frontmost window")
        for pid in order {
            XCTAssertGreaterThan(pid, 0, "a window owner pid must be real")
        }
    }

    /// Runs EVERYWHERE, including headless, because the skip above must not be
    /// the only thing standing between this reader and a crash. Whatever it
    /// returns has to be well formed, and on a machine with no windows that
    /// means empty rather than garbage.
    func testTheWindowOrderReaderIsWellFormedEvenWithNoDisplay() {
        let order = ScreenControlEngine.onScreenPIDsFrontToBack()
        let selfPID = ProcessInfo.processInfo.processIdentifier

        XCTAssertEqual(order.count, Set(order).count, "duplicate pids in the window order")
        XCTAssertFalse(order.contains(0), "pid 0 is not a window owner")

        // And the resolver's headless behaviour is the honest one: with nothing
        // on screen and Grux frontmost there is no app behind it, so the answer
        // is nil rather than a guess.
        if order.isEmpty {
            XCTAssertNil(ScreenControlEngine.pickTarget(
                hint: nil, candidates: [], frontToBack: [], frontmostPID: selfPID, selfPID: selfPID),
                "with no windows at all the resolver must decline rather than invent a target")
        }
    }

    /// END TO END, against this machine's real window stack.
    ///
    /// The unit tests above describe stacks. This one takes the ACTUAL one from
    /// the window server and the ACTUAL running app list, tells the resolver
    /// that the test host is frontmost (which is what "the operator is looking
    /// at Grux" means), and checks the answer is a real app that is not us and
    /// is genuinely on screen. It is the join between the pure function and the
    /// live inputs, which is the seam the shipped bug lived in.
    @MainActor
    func testAgainstTheRealWindowStackItPicksSomethingRealAndNotItself() throws {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let order = ScreenControlEngine.onScreenPIDsFrontToBack()
        let candidates = NSWorkspace.shared.runningApplications.map {
            ScreenControlEngine.AppCandidate(pid: $0.processIdentifier,
                                             bundleID: $0.bundleIdentifier,
                                             name: $0.localizedName,
                                             isRegular: $0.activationPolicy == .regular)
        }
        let onScreenRegulars = order.compactMap { pid in
            candidates.first { $0.pid == pid && $0.isRegular && $0.pid != selfPID }
        }
        try XCTSkipIf(onScreenRegulars.isEmpty, "no other regular app has a window on this machine right now")

        let picked = try XCTUnwrap(ScreenControlEngine.pickTarget(
            hint: nil, candidates: candidates, frontToBack: order,
            frontmostPID: selfPID, selfPID: selfPID))

        XCTAssertNotEqual(picked.pid, selfPID, "it resolved to the caller's own process")
        XCTAssertTrue(picked.isRegular, "\(picked.name ?? "?") is not a regular app")
        XCTAssertTrue(order.contains(picked.pid),
                      "\(picked.name ?? "?") has no on-screen window, so it is not behind anything")
        XCTAssertEqual(picked.pid, onScreenRegulars.first?.pid,
                       "it did not pick the FRONTMOST eligible app: got \(picked.name ?? "?"), "
                       + "expected \(onScreenRegulars.first?.name ?? "?")")
    }

    /// END TO END through the real AX bridge: a named app, a real accessibility
    /// tree, read off the main actor, back through the public entry point the
    /// tool calls. Proves the whole read path works and not merely that the
    /// pieces typecheck.
    @MainActor
    func testListUIElementsReallyReadsTheAppItWasAskedFor() async throws {
        try XCTSkipUnless(ScreenControlEngine.hasAccessibility(),
                          "the test host has no Accessibility grant, so no AX tree is readable")
        let running = NSWorkspace.shared.runningApplications
        try XCTSkipUnless(running.contains { $0.localizedName == "Finder" }, "Finder is not running")

        // Awaited first: XCTUnwrap takes an autoclosure, which cannot be async.
        let read = await ScreenControlEngine.listUIElements(appHint: "Finder", maxCount: 20)
        let result = try XCTUnwrap(read, "the resolver found no app for the hint \"Finder\"")

        XCTAssertEqual(result.app, "Finder", "an explicit hint resolved to a different app")
        for el in result.elements {
            XCTAssertFalse(el.role.isEmpty, "an element came back with no role")
            XCTAssertTrue(el.frame.width > 1 && el.frame.height > 1,
                          "a zero-size element would produce an unclickable coordinate")
        }
    }

    // MARK: - Finding 2: the walk must not hold the main actor

    /// `listUIElements` used to be `@MainActor` end to end, so the whole AX walk
    /// ran on the main actor: up to 4000 nodes, each doing several BLOCKING
    /// `AXUIElementCopyAttributeValue` XPC round trips with a 0.6s timeout. On a
    /// large tree (Chrome, Xcode, any Electron app) that is a multi-second UI
    /// freeze, and against a beachballed target it is scanned x timeout.
    ///
    /// Only the app resolution genuinely needs the main actor, because it
    /// touches `NSWorkspace`. The walk does not, and this test is the proof:
    /// it would not COMPILE if `collectElements` were main-actor isolated.
    func testTheAccessibilityWalkRunsOffTheMainActor() async {
        let ranOffMain = await Task.detached(priority: .userInitiated) { () -> Bool in
            // The test host's own pid. Not AX-trusted, so this returns fast and
            // empty; what is under test is WHERE it runs, not what it finds.
            _ = ScreenControlEngine.collectElements(pid: ProcessInfo.processInfo.processIdentifier,
                                                    maxCount: 5)
            return !Thread.isMainThread
        }.value

        XCTAssertTrue(ranOffMain, "the AX walk executed on the main thread")
    }

    // MARK: - Finding 8: the grant path has to be reachable

    /// `promptAccessibility()` is documented as the "explicit enable / grant"
    /// path and shipped with NO CALL SITE anywhere in Sources or Tests. The
    /// Settings switch wrote the flag and told the user to walk to System
    /// Settings themselves, so the one system prompt that makes the grant a
    /// single click could never appear.
    func testTurningTheSwitchOnOffersTheAccessibilityGrant() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let settings = try String(
            contentsOf: root.appendingPathComponent("Sources/Grux/SettingsView.swift"), encoding: .utf8)

        XCTAssertTrue(settings.contains("promptAccessibility"),
                      "the Screen control switch is the explicit grant path this function exists for, "
                      + "and nothing calls it, so macOS never offers the one-click grant")
    }
}
