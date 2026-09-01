import XCTest

/// Every looping decorative animation must be able to stop.
///
/// `MotionSuspension` exists because a `repeatForever` animation and a
/// `TimelineView` do NOT stop when the window is hidden or the app is
/// deactivated. They keep committing Core Animation transactions forever, and
/// on an idle laptop that display transaction flush was measured as the single
/// largest cost in the process.
///
/// The gate only works if every site consults it, and that is exactly what
/// stopped being true. Measured 2026-08-31 on the shipped 1.2.1 build, idle and
/// in the background: 731 of 3932 main-thread samples were in
/// `stepTransactionFlush`, the display transaction flush, while nothing was on
/// screen. Six sites were animating with no gate, and `MotionTokens.gated`
/// itself consulted only half the gate while its own comment claimed it
/// "matches GruxTheme.reduceMotion exactly".
///
/// So the rule is total and mechanical rather than remembered: EVERY
/// `repeatForever` and EVERY `TimelineView(.animation(...))` in the app carries
/// a gate. There is deliberately no exemption list. An exemption list is a
/// second thing to keep in sync, and the bug this test exists to catch was
/// caused by two things that were supposed to stay in sync and did not.
final class MotionGateTests: XCTestCase {

    /// A looping-animation site found in the source.
    private struct Site {
        let file: String
        let line: Int
        let text: String
        let gatedBy: String?
        var isGated: Bool { gatedBy != nil }
    }

    /// The tokens that count as a gate, and what each one means.
    ///
    /// `reduceMotion`   the canonical read, `GruxTheme.reduceMotion`, which ORs
    ///                  the palette opt-out with `MotionSuspension.suspended`.
    /// `motionOff`      HomeHeroView's local alias for exactly that expression.
    /// `MotionTokens.gated`  the helper form, which returns nil under the gate.
    /// `paused:`        the `TimelineView` form, which stops the ticks.
    private static let gateTokens = ["reduceMotion", "motionOff", "MotionTokens.gated", "paused:"]

    /// What we are looking for: every form that loops until something stops it.
    ///
    /// The first version of this list held only the first two, and that gap was
    /// real rather than theoretical. It reported the sweep complete while three
    /// `symbolEffect` sites repeated forever on a flag, which is the same shape
    /// as the MeetingPanelView and ProjectsView bugs it did catch. A scanner
    /// that knows two of five forms reports 100% coverage of the two it knows.
    ///
    /// `options: .repeating` and `.iterative` are the perpetual symbolEffect
    /// spellings. `.repeat(n)`, `.nonRepeating` and `repeatCount(n)` are bounded
    /// and deliberately absent: they stop on their own.
    private static let loopMarkers = [
        "repeatForever",
        "TimelineView(.animation",
        "options: .repeating",
        ".variableColor.iterative",
    ]

    /// Spellings that bound a loop to a finite number of cycles. A site wearing
    /// one of these is exempt because it ENDS, not because anyone decided to
    /// excuse it, which is why this is a property of the code and not a list of
    /// file paths that would rot.
    private static let boundedMarkers = ["options: .repeat(", "options: .nonRepeating", "repeatCount("]

    // MARK: - The rule

    func testEveryLoopingAnimationIsGated() throws {
        let found = try Self.sites()
        let ungated = found.filter { !$0.isGated }

        XCTAssertTrue(ungated.isEmpty, """
            \(ungated.count) looping animation(s) run with no way to stop:

            \(ungated.map { "  \($0.file):\($0.line)\n      \($0.text)" }.joined(separator: "\n"))

            Every repeatForever and every TimelineView(.animation(...)) must
            consult the motion gate, so it stops when the user asked for less
            motion AND when nobody is looking at the window. Use one of:

              guard !GruxTheme.reduceMotion else { <reset to rest>; return }
              .animation(MotionTokens.gated(<animation>), value: <value>)
              TimelineView(.animation(minimumInterval: _, paused: GruxTheme.reduceMotion))
            """)
    }

    /// A scanner that finds nothing passes every assertion above it, which is
    /// the failure mode that makes a guard worthless. Prove it is still looking
    /// at real code before believing a clean result.
    func testTheScannerActuallyFindsTheKnownSites() throws {
        let found = try Self.sites()
        XCTAssertGreaterThanOrEqual(found.count, 12, """
            The motion-gate scanner found only \(found.count) looping animations. \
            There were 12 when this guard was written, so either the scanner is \
            broken (wrong root, changed markers, comment stripping too greedy) or \
            an entire family of animations was deleted. Both are worth a look \
            before this number is lowered.
            """)

    }

    /// The detector must actually discriminate, not call everything gated.
    ///
    /// The first version of this proof asserted that some site was reported as
    /// gated by `paused:`. That can never happen and says nothing about the
    /// detector: the real spelling is `paused: reduceMotion`, so the earlier
    /// `reduceMotion` token always matches first. It failed for a reason that
    /// had nothing to do with the property under test, which is the signature
    /// of an assertion aimed at the wrong thing. Feed it known inputs instead.
    func testTheGateDetectorDiscriminates() throws {
        let ungated = [
            "    private func startAnimating() {",
            "        withAnimation(.linear(duration: 9).repeatForever(autoreverses: false)) {",
            "            phase = 2 * .pi",
            "        }",
        ]
        XCTAssertNil(Self.gate(for: 1, in: ungated),
                     "an ungated repeatForever was reported as gated, so the guard cannot fail")

        let guarded = [
            "    private func startAnimating() {",
            "        guard !GruxTheme.reduceMotion else { return }",
            "        withAnimation(.linear(duration: 9).repeatForever(autoreverses: false)) {",
            "            phase = 2 * .pi",
            "        }",
        ]
        XCTAssertEqual(Self.gate(for: 2, in: guarded), "reduceMotion")

        let timeline = [
            "    var body: some View {",
            "        TimelineView(.animation(minimumInterval: 1.0 / 40.0,",
            "                                paused: someLocalFlag)) { tl in",
        ]
        XCTAssertEqual(Self.gate(for: 1, in: timeline), "paused:",
                       "the paused: form on a wrapped line was not detected")

        // The window must not reach past the enclosing entry point and borrow a
        // gate from an unrelated function above it.
        let borrowed = [
            "    private func other() {",
            "        guard !GruxTheme.reduceMotion else { return }",
            "    }",
            "    private func startAnimating() {",
            "        withAnimation(.linear(duration: 9).repeatForever(autoreverses: false)) {",
        ]
        XCTAssertNil(Self.gate(for: 4, in: borrowed),
                     "the detector borrowed a gate from the function above it")
    }

    // MARK: - Machinery

    /// The Swift package root, `Grux-Mac`, derived from this file's own path so
    /// the test runs from any working directory and from Xcode too.
    private static func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)     // .../Grux-Mac/Tests/GruxTests/ThisFile.swift
            .deletingLastPathComponent()    // .../Grux-Mac/Tests/GruxTests
            .deletingLastPathComponent()    // .../Grux-Mac/Tests
            .deletingLastPathComponent()    // .../Grux-Mac
    }

    /// Every looping-animation site under `Sources/Grux`, with whether it is gated.
    private static func sites() throws -> [Site] {
        let root = packageRoot().appendingPathComponent("Sources/Grux")
        guard let walker = FileManager.default.enumerator(atPath: root.path) else { return [] }

        var out: [Site] = []
        for case let rel as String in walker {
            guard (rel as NSString).pathExtension == "swift" else { continue }
            let url = root.appendingPathComponent(rel)
            guard let src = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let lines = src.components(separatedBy: "\n")

            for (i, raw) in lines.enumerated() {
                // A doc comment describing the problem is not an instance of it.
                // MotionSuspension.swift and GruxTheme.swift both discuss
                // `repeatForever` at length and neither performs one.
                let trimmed = raw.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") { continue }
                guard loopMarkers.contains(where: { raw.contains($0) }) else { continue }
                // A bounded loop stops on its own, so it is not what this guard
                // is about. `.variableColor.iterative` is perpetual by default
                // and finite when `options:` says so, which means the marker
                // alone cannot tell them apart. Note `options: .repeat(` does
                // NOT match `options: .repeating`: the paren is what separates
                // the finite form from the endless one.
                if boundedMarkers.contains(where: { raw.contains($0) }) { continue }

                out.append(Site(file: rel, line: i + 1,
                                text: trimmed,
                                gatedBy: gate(for: i, in: lines)))
            }
        }
        return out.sorted { ($0.file, $0.line) < ($1.file, $1.line) }
    }

    /// The gate token covering the site at `index`, or nil if there is none.
    ///
    /// The window is the animation's own entry point, not a fixed line count. A
    /// fixed count was tried first and misread twice: it called HomeHeroView
    /// ungated (its guard reads `motionOff`) and ProjectsView ungated (its gate
    /// sits on the line above). Walking up to the enclosing `func`, `body`,
    /// `onAppear` or `onChange` is what an author would call "the same place".
    private static func gate(for index: Int, in lines: [String]) -> String? {
        let boundaries = ["func ", "var body", ".onAppear", ".onChange"]
        var start = index
        var walked = 0
        while start > 0 && walked < 40 {
            let line = lines[start]
            if boundaries.contains(where: { line.contains($0) }) { break }
            start -= 1
            walked += 1
        }
        // Include a couple of lines past the site: a TimelineView call wraps,
        // and `paused:` routinely lands on the following line.
        let end = min(index + 2, lines.count - 1)
        let window = lines[start...end].joined(separator: "\n")
        return gateTokens.first { window.contains($0) }
    }
}
