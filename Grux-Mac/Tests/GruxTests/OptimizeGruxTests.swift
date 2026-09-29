import XCTest
@testable import Grux

/// Optimize Grux: a request becomes a work order the person's own coding agent
/// runs end to end, and Grux shows where it is on the line.
@MainActor
final class OptimizeGruxTests: XCTestCase {

    private func temp() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("optimize-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private let source = WorkOrderSource(path: "/work/grux/Grux-Mac", commit: "abc1234", binaryMtime: 1_000)

    private func context(_ installed: WorkOrderContext.Installed, orderDir: String = "/orders/wo-test12") -> WorkOrderContext {
        WorkOrderContext(appPath: "/Applications/Grux.app", version: "3.0.0", build: "8", installed: installed,
                         supportDir: "/support/Grux", orderDir: orderDir)
    }

    private func sourcesFile(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    // MARK: - The progress an agent reports

    func test_progressReadsTheLastKnownStation_andIgnoresNoise() {
        let log = """
        # wo-abc: one line per station
        requirements | make the accent red

        analysis | it is theme.json accentHue, no code
        warming up | not a station
        review-1 | plan: set accentHue to 0 | undo: set it back
        """
        let p = WorkOrderProgress.parse(log)
        XCTAssertEqual(p.stage, .reviewPlan)
        XCTAssertEqual(p.note, "plan: set accentHue to 0 | undo: set it back", "a pipe inside the note was lost")
        XCTAssertTrue(p.stage.isReview)
        XCTAssertEqual(WorkOrderProgress.parse("").stage, .written)
        XCTAssertEqual(WorkOrderProgress.parse("# only a comment\n\n").stage, .written)
        XCTAssertEqual(WorkOrderProgress.parse("DONE | shipped").stage, .done, "case is not the agent's problem")
    }

    func test_theLineHasFifteenStops_twelveStationsAndThreeReviews() {
        let line = WorkOrderStage.line
        XCTAssertEqual(line.count, 15, "the line moved; update WorkOrder.swift's header comment, the line view's comment and this name together")
        XCTAssertEqual(line.filter(\.isReview).count, 3)
        // Eleven since 2026-09-22, when preflight joined the front, so a
        // request that left something out gets asked before anything is
        // built. Twelve since 2026-09-27, when cleanup joined the end, so
        // nothing temporary outlives the order.
        XCTAssertEqual(line.filter { !$0.isReview }.count, 12)
        XCTAssertEqual(line.filter(\.isReview), [.reviewPlan, .reviewDesign, .reviewResult])
        XCTAssertEqual(line.map(\.rawValue), ["preflight", "requirements", "analysis", "review-1", "design",
                                              "architecture", "governance", "review-2", "build", "validate",
                                              "review-3", "install", "verify", "monitor", "cleanup"])
        XCTAssertEqual(WorkOrderStage.done.position, line.count)
        XCTAssertEqual(WorkOrderStage.written.position, 0)
        XCTAssertEqual(WorkOrderStage.preflight.position, 1)
        XCTAssertEqual(WorkOrderStage.analysis.position, 3)
    }

    /// PREFLIGHT CANNOT BECOME AN INTERVIEW. Three questions is the cap, every
    /// one carries a recommendation so saying "go with your recommendations"
    /// finishes it, and a request that needs nothing asked says so and moves.
    func test_preflightAsksAtMostThreeQuestions_eachWithARecommendation() {
        let text = WorkOrderPrompt.build(id: "wo-test12", request: "change grux color accent to red",
                                         context: context(.localBuild(source)))
        let station = try? XCTUnwrap(text.components(separatedBy: "0. **preflight**").dropFirst().first)
        let body = String((station ?? "").prefix(900))
        XCTAssertTrue(body.contains("AT MOST THREE"), "the cap is not stated in words the agent cannot misread")
        XCTAssertTrue(body.contains("recommended answer"), "a question with no recommendation can be got wrong")
        XCTAssertTrue(body.contains("go with your recommendations"), "there is no one-word way to accept")
        XCTAssertTrue(body.contains("none needed"), "a request that needs no questions has no way past")
        XCTAssertTrue(body.contains("Never ask about implementation"),
                      "preflight may ask what changes the work, never how to do it")
        // And it comes before the first station that builds anything.
        let pre = try? XCTUnwrap(text.range(of: "**preflight**"))
        let req = try? XCTUnwrap(text.range(of: "**requirements**"))
        if let pre, let req { XCTAssertLessThan(pre.lowerBound, req.lowerBound) }
    }

    // MARK: - The work order

    func test_theWorkOrderCarriesTheRequestTheLineAndTheRules() {
        let text = WorkOrderPrompt.build(id: "wo-test12", request: "change grux color accent to red",
                                         context: context(.localBuild(source)))
        XCTAssertTrue(text.contains("> change grux color accent to red"), "the request is not quoted verbatim")
        XCTAssertTrue(text.contains("wo-test12"))
        XCTAssertTrue(text.contains("/orders/wo-test12/progress.log"), "the agent is not told where to report")
        var cursor = text.startIndex
        for station in WorkOrderStage.line {
            guard let r = text.range(of: station.rawValue, range: cursor..<text.endIndex) else {
                return XCTFail("\(station.rawValue) is missing or out of order")
            }
            cursor = r.upperBound
        }
        XCTAssertEqual(text.components(separatedBy: "Stop here").count - 1, 3, "every review must stop the agent")
        for rule in ["a setting already does what was asked", "Sources/Grux/DesignSystem",
                     "Nothing new leaves the Mac", "goes through Approvals", "Every existing test keeps passing",
                     "Push only if they ask", "CLAUDE.md", "CONTRIBUTING.md", "U+2014", "U+2013",
                     "config.json", "theme.json", "./build.sh", "swift test", "design-ratchet.py --check",
                     "applies an edit the moment the file changes"] {
            XCTAssertTrue(text.contains(rule), "the work order lost: \(rule)")
        }
    }

    /// ONE TEMPLATE FOR EVERY REQUEST. Grux never decides what kind of change
    /// was asked for; the agent does, at analysis. If the template branched on
    /// the request, two requests would differ by more than their own words.
    func test_theWorkOrderNeverBranchesOnTheRequest() {
        let ctx = context(.release(olderSource: nil))
        let a = WorkOrderPrompt.build(id: "wo-aaaaaa", request: "make the accent red", context: ctx)
        let b = WorkOrderPrompt.build(id: "wo-aaaaaa", request: "add a pomodoro timer to Today and a new Focus surface",
                                      context: ctx)
        XCTAssertEqual(a.replacingOccurrences(of: "make the accent red", with: "X"),
                       b.replacingOccurrences(of: "add a pomodoro timer to Today and a new Focus surface", with: "X"))
    }

    func test_whereTheSourceIs_localBuildWorksInPlace_theDownloadClonesItsOwnVersion() {
        let local = WorkOrderPrompt.build(id: "wo-x", request: "r", context: context(.localBuild(source)))
        XCTAssertTrue(local.contains("`/work/grux/Grux-Mac` at commit `abc1234`"))
        XCTAssertFalse(local.contains("git clone"), "a local build was told to clone")

        let download = WorkOrderPrompt.build(id: "wo-x", request: "r", context: context(.release(olderSource: nil)))
        XCTAssertTrue(download.contains("git clone --branch v3.0.0"))
        XCTAssertTrue(download.contains("linked from https://gruxai.com"), "a download is not told where the source is")
        XCTAssertTrue(download.contains("the downloaded release"))

        let both = WorkOrderPrompt.build(id: "wo-x", request: "r", context: context(.release(olderSource: source)))
        XCTAssertTrue(both.contains("git clone --branch v3.0.0"))
        XCTAssertTrue(both.contains("/work/grux/Grux-Mac"), "an older checkout on this Mac was not mentioned")
    }

    /// The binary must not carry the author's handle, and the repository URL
    /// does. The site links the repository instead.
    func test_noWorkOrderNamesTheAuthorsHandle() {
        for installed in [WorkOrderContext.Installed.localBuild(source), .release(olderSource: nil), .release(olderSource: source)] {
            let text = WorkOrderPrompt.build(id: "wo-x", request: "r", context: context(installed))
            XCTAssertFalse(text.lowercased().contains("github.com/"), "a work order names a repository URL")
        }
    }

    func test_whichInstallThisIs_fromTheRecordedSourceAndTheBinary() {
        XCTAssertEqual(WorkOrderContext.installed(source: source, binaryMtime: 1_002, sourceExists: true),
                       .localBuild(source))
        XCTAssertEqual(WorkOrderContext.installed(source: source, binaryMtime: 9_000, sourceExists: true),
                       .release(olderSource: source), "a later install of the download was read as this build")
        XCTAssertEqual(WorkOrderContext.installed(source: source, binaryMtime: 1_000, sourceExists: false),
                       .release(olderSource: nil), "a deleted checkout was offered")
        XCTAssertEqual(WorkOrderContext.installed(source: nil, binaryMtime: 1_000, sourceExists: false),
                       .release(olderSource: nil))
    }

    func test_theRequestIsTrimmedCappedAndNeverEmpty() {
        XCTAssertNil(WorkOrderPrompt.clean("   \n  "))
        XCTAssertEqual(WorkOrderPrompt.clean("  red accent \n"), "red accent")
        XCTAssertEqual(WorkOrderPrompt.clean(String(repeating: "a", count: 5000))?.count, WorkOrderPrompt.maxRequest)
    }

    /// THE LINE ENDS AT LIVE, NOT AT A COMMIT. Measured 2026-09-27: an agent
    /// built Keep Grux on top in a side worktree, committed, and stopped with
    /// "I haven't pushed it or merged it", so nothing was live until Jack
    /// asked again. The order has to carry the agent through the install, a
    /// check on the running app, the cleanup of anything temporary, and only
    /// then `done`.
    func test_theLineEndsAtLive_installVerifyCleanupThenDone() throws {
        let text = WorkOrderPrompt.build(id: "wo-test12", request: "make the accent baby blue",
                                         context: context(.localBuild(source)))
        XCTAssertNotNil(WorkOrderStage(rawValue: "cleanup"), "cleanup is not a station the agent can report")
        var cursor = text.startIndex
        for marker in ["**install**", "./build.sh", "relaunch", "**verify**", "running",
                       "**cleanup**", "merge", "git worktree remove", "branch", "done | "] {
            guard let r = text.range(of: marker, range: cursor..<text.endIndex) else {
                return XCTFail("\(marker) is missing or out of order")
            }
            cursor = r.upperBound
        }
        XCTAssertTrue(text.contains("<stage> | <note>") || text.contains("`analysis | "),
                      "the agent is not shown the line format")
        XCTAssertFalse(text.lowercased().contains("quit grux"), "a settings change still asks for a quit")
        XCTAssertFalse(text.contains("Commit or push only if the person asks"),
                       "the order still lets the agent stop at an uncommitted change")
    }

    /// A proposal's detail goes INTO the one template: the same stations,
    /// rules and line as a typed request, with the detail under the request.
    func test_aDetailRidesInsideTheOneTemplate() {
        let ctx = context(.localBuild(source))
        let plain = WorkOrderPrompt.build(id: "wo-aaaaaa", request: "keep Grux on top", context: ctx)
        let detailed = WorkOrderPrompt.build(id: "wo-aaaaaa", request: "keep Grux on top",
                                             detail: "### What to add\n\nA toggle in Settings.", context: ctx)
        XCTAssertTrue(detailed.contains("### What to add\n\nA toggle in Settings."), "the detail was dropped")
        XCTAssertLessThan(try XCTUnwrap(detailed.range(of: "> keep Grux on top")).lowerBound,
                          try XCTUnwrap(detailed.range(of: "### What to add")).lowerBound)
        // Everything after the detail is the same template, word for word.
        let tail = { (t: String) in String(t[t.range(of: "You are this person's coding agent.")!.lowerBound...]) }
        XCTAssertEqual(tail(plain), tail(detailed), "a detail changed the line")
        XCTAssertEqual(WorkOrderPrompt.build(id: "wo-aaaaaa", request: "keep Grux on top", detail: "  \n", context: ctx),
                       plain, "an empty detail left a heading behind")
    }

    /// ONE LINE FOR EVERY HANDOFF. Every handoff Grux writes for a person's
    /// coding agent goes through `WorkOrderPrompt`; no other file tells an
    /// agent how to build and test. Grux's own headless builder (RDWorker)
    /// and the verifier that runs the suite itself (RDVerifier) are not
    /// handoffs a person copies, and are the only other files allowed to
    /// name the test gate.
    func test_oneFormatterWritesEveryHandoffForAnAgent() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources/Grux")
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var formatters: Set<String> = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let code = try String(contentsOf: url, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            if code.contains("swift test") || code.contains("design-ratchet") {
                formatters.insert(String(url.path.dropFirst(sources.path.count + 1)))
            }
        }
        // The scan must find the one it expects, or it proves nothing.
        XCTAssertTrue(formatters.contains("Optimize/WorkOrder.swift"), "the scan is broken: \(formatters)")
        XCTAssertEqual(formatters, ["Optimize/WorkOrder.swift", "Foundry/RDWorker.swift", "Foundry/RDVerifier.swift"],
                       "a second formatter tells an agent how to build and test")
        let upgrade = try sourcesFile("Sources/Grux/Foundry/SelfUpgradeView.swift")
        XCTAssertTrue(upgrade.contains("createAndCopy("), "Self-Upgrade copies a handoff that is not a work order")
        let card = try sourcesFile("Sources/Grux/Optimize/OptimizeHubCard.swift")
        let copyProposal = try XCTUnwrap(card.range(of: "func copyProposal"))
        XCTAssertTrue(card[copyProposal.upperBound...].prefix(1500).contains("createAndCopy("),
                      "the proposed fix is copied without writing a work order")
    }

    // MARK: - The store

    func test_theStoreWritesAnOrderAnAgentCanReadAndReportTo() throws {
        let root = temp()
        let store = WorkOrderStore(root: root)
        XCTAssertNil(store.create(request: "  ", context: { self.context(.localBuild(self.source), orderDir: $0.path) }))
        let order = try XCTUnwrap(store.create(request: "change grux color accent to red",
                                               context: { self.context(.localBuild(self.source), orderDir: $0.path) }))
        XCTAssertTrue(order.id.hasPrefix("wo-"))
        XCTAssertNil(order.id.range(of: "[^a-z0-9-]", options: .regularExpression))
        let text = try XCTUnwrap(store.workOrderText(order))
        XCTAssertTrue(text.contains("\(order.dir.path)/progress.log"), "the order does not point at its own progress file")
        XCTAssertEqual(order.progress.stage, .written)

        // The agent reports, the way the work order tells it to.
        let handle = try FileHandle(forWritingTo: order.progressFile)
        handle.seekToEndOfFile()
        handle.write("analysis | it is theme.json\nreview-1 | set accentHue to 0?\n".data(using: .utf8)!)
        try handle.close()
        store.reload()
        XCTAssertEqual(store.orders.first?.progress.stage, .reviewPlan)
        XCTAssertEqual(store.waitingOnYou, 1)
        XCTAssertTrue(store.hasActive)

        store.remove(order.id)
        XCTAssertTrue(store.orders.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: order.dir.path))
    }

    /// Thirty minutes with no new line and the order reads as waiting, so
    /// the row can offer it again. A finished order never waits.
    func test_aQuietOrderReadsAsWaiting_aFinishedOneNever() throws {
        let store = WorkOrderStore(root: temp())
        let order = try XCTUnwrap(store.create(request: "make the accent baby blue",
                                               context: { self.context(.release(olderSource: nil), orderDir: $0.path) }))
        XCTAssertFalse(order.isWaiting(now: order.updated.addingTimeInterval(29 * 60)))
        XCTAssertTrue(order.isWaiting(now: order.updated.addingTimeInterval(WorkOrderStore.quietAfter)),
                      "an order with no word for 30 minutes does not read as waiting")
        let handle = try FileHandle(forWritingTo: order.progressFile)
        handle.seekToEndOfFile()
        handle.write(Data("review-1 | the plan, yes?\n".utf8))
        store.reload()
        let atReview = try XCTUnwrap(store.orders.first)
        XCTAssertFalse(atReview.isWaiting(now: atReview.updated.addingTimeInterval(3 * 3600)),
                       "an order waiting on the person's review reads as waiting on the agent")
        handle.write(Data("done | shipped\n".utf8))
        try handle.close()
        store.reload()
        let done = try XCTUnwrap(store.orders.first)
        XCTAssertFalse(done.isWaiting(now: done.updated.addingTimeInterval(24 * 3600)), "a done order reads as waiting")
    }

    func test_ordersAreNewestFirst_andIdsDoNotCollide() throws {
        let store = WorkOrderStore(root: temp())
        let first = try XCTUnwrap(store.create(request: "one", context: { self.context(.release(olderSource: nil), orderDir: $0.path) }))
        Thread.sleep(forTimeInterval: 1.1)
        let second = try XCTUnwrap(store.create(request: "two", context: { self.context(.release(olderSource: nil), orderDir: $0.path) }))
        XCTAssertEqual(store.orders.map(\.id), [second.id, first.id])
        let ids = Set((0..<500).map { _ in WorkOrderStore.newID() })
        XCTAssertGreaterThan(ids.count, 495, "six characters from 31 should almost never collide in 500")
        for id in ids { XCTAssertNil(id.range(of: "[01oil]", options: .regularExpression, range: id.index(id.startIndex, offsetBy: 3)..<id.endIndex), id) }
    }

    func test_theSuiteNeverWritesTheOperatorsWorkOrders() {
        XCTAssertTrue(WorkOrderStore.shared.root.path.hasPrefix(Persistence.gruxDir.path))
        XCTAssertFalse(WorkOrderStore.shared.root.path.hasPrefix(NSHomeDirectory() + "/.grux"),
                       "the shared store points at the real ~/.grux under test")
    }

    // MARK: - Wiring

    func test_itIsReachableFromTheSidebarThePaletteAndATrigger_andNamedAtFirstRun() throws {
        let root = try sourcesFile("Sources/Grux/Shell/CommandPanelRoot.swift")
        XCTAssertTrue(root.contains("OptimizeHubCard()"), "the hub left the panel")
        // The classic shell keeps its sidebar button for the release it stays.
        let legacy = try sourcesFile("Sources/Grux/LaunchRootView.swift")
        let hero = try XCTUnwrap(legacy.range(of: "private var sidebarHero"))
        XCTAssertTrue(legacy[hero.upperBound...].prefix(1800).contains("OptimizeGruxButton()"),
                      "the button left the legacy sidebar header")
        XCTAssertTrue(try sourcesFile("Sources/Grux/Shell/OrbCommandPalette.swift").contains("id: \"optimize-grux\""))
        XCTAssertTrue(try sourcesFile("Sources/Grux/Triggers/AppTriggers.swift").contains("\"fire-optimize\""))
        XCTAssertTrue(HowItWorksStep.wayfinding.contains { $0.title == OptimizeCopy.title }, "not named at first run")
    }

    func test_buildRecordsItsSource_onlyForAnInstallItMakes() throws {
        let script = try sourcesFile("build.sh")
        let record = try XCTUnwrap(script.range(of: ".grux/source.json\" <<'SOURCE'"))
        let releaseExit = try XCTUnwrap(script.range(of: "echo \"[7/7] Done (release mode, nothing installed).\""))
        XCTAssertLessThan(releaseExit.lowerBound, record.lowerBound,
                          "a release build would record a builder's checkout for strangers")
    }

    func test_theHubIsAPanelCardNotARailRow() {
        let rail = SidebarIA.rail(developerUnlocked: false, brands: [])
        XCTAssertFalse(rail.contains { $0.label == OptimizeCopy.title })
        XCTAssertEqual(OptimizeDoor.allCases.count, 4)
    }
}
