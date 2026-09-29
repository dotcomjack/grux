import XCTest
@testable import Grux

/// LIVE STATE, NEVER A MANUAL REFRESH (Grux-Mac CLAUDE.md, 2026-09-27).
///
/// Everything Grux shows that lives in a file is observed, not read once.
/// Each test here changes a file the way another process would (an agent's
/// `echo >>`, an editor's atomic save, a folder appearing or going) and waits
/// for the published value to move. None of them calls a reload.
@MainActor
final class LiveStateTests: XCTestCase {

    private func temp() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("live-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func context(_ dir: URL) -> WorkOrderContext {
        WorkOrderContext(appPath: "/Applications/Grux.app", version: "3.0.0", build: "8",
                         installed: .release(olderSource: nil), supportDir: "/support/Grux", orderDir: dir.path)
    }

    /// Waits for `condition`, yielding the main actor so the watchers'
    /// main-queue handlers can run. Nothing here reloads anything.
    private func eventually(_ seconds: Double = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }

    /// The way the work order tells an agent to report: append in place.
    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        handle.write(Data(text.utf8))
        try handle.close()
    }

    // MARK: - Work orders

    func test_anAppendedLineMovesThePublishedStation_withNoReload() async throws {
        let store = WorkOrderStore(root: temp())
        let order = try XCTUnwrap(store.create(request: "make the accent baby blue", context: context))
        XCTAssertEqual(store.orders.first?.progress.stage, .written)

        try append("preflight | none needed\n", to: order.progressFile)
        let moved = await eventually { store.orders.first?.progress.stage == .preflight }
        XCTAssertTrue(moved, "the station did not move without a reload")

        try append("done | the accent is baby blue\n", to: order.progressFile)
        let done = await eventually { store.orders.first?.progress.stage == .done }
        XCTAssertTrue(done, "done never showed")
        XCTAssertEqual(store.orders.first?.progress.note, "the accent is baby blue")
        // A finished order lets go of its descriptors; only the root stays.
        XCTAssertFalse(store.watchedPaths.contains(order.progressFile.path), "a done order still holds its log open")
        XCTAssertFalse(store.watchedPaths.contains(order.dir.path), "a done order still holds its folder open")
        XCTAssertEqual(store.watchedPaths, [store.root.path])
    }

    /// An order that finished and was copied again is live again: a stopped
    /// one stays watched, and a done one is re-armed by Copy again.
    func test_aFinishedOrderCopiedAgainMovesLive() async throws {
        let store = WorkOrderStore(root: temp())
        let stopped = try XCTUnwrap(store.create(request: "hide Meetings", context: context))
        try append("analysis | a setting\nstopped | out of time\n", to: stopped.progressFile)
        let halted = await eventually { store.orders.first?.progress.stage == .stopped }
        XCTAssertTrue(halted)
        try append("build | back on it\n", to: stopped.progressFile)
        let resumed = await eventually { store.orders.first?.progress.stage == .build }
        XCTAssertTrue(resumed, "a stopped order that carried on stayed at stopped")

        try append("done | hidden\n", to: stopped.progressFile)
        let finished = await eventually { store.orders.first?.progress.stage == .done }
        XCTAssertTrue(finished)
        XCTAssertEqual(store.watchedPaths, [store.root.path], "a done order still holds descriptors")
        // Copy again, then the agent starts over on the same order.
        store.copiedAgain(stopped.id)
        XCTAssertTrue(store.watchedPaths.contains(stopped.progressFile.path), "Copy again did not re-arm the order")
        try append("preflight | none needed\n", to: stopped.progressFile)
        let again = await eventually { store.orders.first?.progress.stage == .preflight }
        XCTAssertTrue(again, "the re-copied order's next line was missed")
        XCTAssertTrue(store.watchedPaths.contains(stopped.progressFile.path))
    }

    /// Some agents rewrite the whole file rather than appending. The old file
    /// is replaced under the watcher, and the next line must still show.
    func test_aLogRewrittenAtomicallyIsStillSeen_andSoIsTheLineAfterIt() async throws {
        let store = WorkOrderStore(root: temp())
        let order = try XCTUnwrap(store.create(request: "hide Meetings", context: context))
        try "# rewritten\nanalysis | a sidebar setting\n".write(to: order.progressFile, atomically: true, encoding: .utf8)
        let first = await eventually { store.orders.first?.progress.stage == .analysis }
        XCTAssertTrue(first, "an atomic rewrite was missed")
        try append("review-1 | hide it?\n", to: order.progressFile)
        let second = await eventually { store.orders.first?.progress.stage == .reviewPlan }
        XCTAssertTrue(second, "the watcher died with the file it replaced")
    }

    /// An order written by another Grux process, and one removed in Finder,
    /// show in this store with no reload.
    func test_ordersAddedOrRemovedOutsideTheStoreShowLive() async throws {
        let root = temp()
        let store = WorkOrderStore(root: root)
        XCTAssertTrue(store.orders.isEmpty)
        let other = WorkOrderStore(root: root)
        let order = try XCTUnwrap(other.create(request: "add a timer to Today", context: context))
        let added = await eventually { store.orders.map(\.id) == [order.id] }
        XCTAssertTrue(added, "an order written elsewhere never appeared")
        try FileManager.default.removeItem(at: order.dir)
        let removed = await eventually { store.orders.isEmpty }
        XCTAssertTrue(removed, "a folder removed outside Grux stayed on the card")
        XCTAssertTrue(store.watchedPaths.contains(root.path), "the root is not watched")
        XCTAssertFalse(store.watchedPaths.contains(order.dir.path), "a removed order is still held open")
    }

    /// The watcher holds exactly what it was last asked for, and lets go of
    /// a path that is still there but no longer wanted.
    func test_theWatcherLetsGoOfWhatIsNoLongerWanted() throws {
        let dir = temp()
        let a = dir.appendingPathComponent("a.log"), b = dir.appendingPathComponent("b.log")
        try Data("a".utf8).write(to: a)
        try Data("b".utf8).write(to: b)
        let watch = FileWatch {}
        watch.watch([dir, a, b])
        XCTAssertEqual(watch.watchedPaths, [dir.path, a.path, b.path])
        watch.watch([dir, a])
        XCTAssertEqual(watch.watchedPaths, [dir.path, a.path], "a path no longer wanted is still held open")
        watch.watch([dir, a, dir.appendingPathComponent("missing.log")])
        XCTAssertEqual(watch.watchedPaths, [dir.path, a.path], "a missing path was reported as watched")
        watch.stop()
        XCTAssertTrue(watch.watchedPaths.isEmpty)
    }

    // MARK: - Settings files

    /// config.json edited in place while Grux runs (`echo > config.json`, or
    /// an agent's settings change) applies with no relaunch.
    func test_anExternalEditToConfigJsonApplies_withNoRelaunch() async throws {
        let state = AppState.shared
        let before = state.config.keepOnTop
        state.saveConfig()
        defer {
            state.config.keepOnTop = before
            state.saveConfig()
        }
        let sync = try XCTUnwrap(state.configSync)
        let count = sync.applied
        let url = Persistence.configURL
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json["keepOnTop"] = !before
        // Non-atomic on purpose: the file is rewritten in place, the way a
        // shell redirect writes it.
        try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: url)
        let applied = await eventually { state.config.keepOnTop == !before }
        XCTAssertTrue(applied, "an edit to config.json on disk did not reach the running app")
        XCTAssertEqual(sync.applied, count + 1, "one outside edit was applied other than once")
    }

    /// Grux's own saves raise the same file events, and must not be read
    /// back as outside edits: no reload, so no loop.
    func test_gruxsOwnConfigSaveIsNotReadBack() async throws {
        let state = AppState.shared
        let sync = try XCTUnwrap(state.configSync)
        let before = state.config.keepOnTop
        defer {
            state.config.keepOnTop = before
            state.saveConfig()
        }
        let count = sync.applied
        // Each save's own event is waited for, so every one is handled on its own
        // (saves in one main turn coalesce into one event).
        for toggle in [false, true, true] {
            if toggle { state.config.keepOnTop.toggle() }
            let seen = sync.events
            state.saveConfig()
            let handled = await eventually { sync.events > seen }
            XCTAssertTrue(handled, "no file event arrived for Grux's own save")
        }
        // Then one outside edit, as a marker: file events are handled in order, so
        // once it has applied every earlier event has been handled, and a count
        // above one means an own save was applied too.
        let url = Persistence.configURL
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json["keepOnTop"] = !state.config.keepOnTop
        let target = !state.config.keepOnTop
        try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: url)
        let marked = await eventually { state.config.keepOnTop == target }
        XCTAssertTrue(marked, "the outside marker edit never applied")
        XCTAssertEqual(sync.applied, count + 1, "Grux's own save was applied as an outside edit")
    }

    /// A half-written or broken file is not applied, and is not quarantined:
    /// the next good write still lands.
    func test_aBrokenConfigWriteIsIgnored_andTheNextGoodOneApplies() async throws {
        let state = AppState.shared
        let before = state.config.keepOnTop
        state.saveConfig()
        defer {
            state.config.keepOnTop = before
            state.saveConfig()
        }
        let url = Persistence.configURL
        let good = try Data(contentsOf: url)
        try Data("{ \"keepOnTop\": ".utf8).write(to: url)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(state.config.keepOnTop, before, "a broken file changed the config")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: good) as? [String: Any])
        json["keepOnTop"] = !before
        try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
        let applied = await eventually { state.config.keepOnTop == !before }
        XCTAssertTrue(applied, "the good write after a broken one was not applied")
    }

    /// theme.json replaced by an editor's atomic save applies with no relaunch.
    func test_anExternalEditToThemeJsonApplies_withNoRelaunch() async throws {
        let url = temp().appendingPathComponent("theme.json")
        let theme = ThemeConfig(fileURL: url)
        XCTAssertEqual(theme.appearance, .dark)
        var edited = ThemeSettings.default
        edited.appearance = .light
        edited.reduceMotion = true
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(edited).write(to: url, options: .atomic)
        let applied = await eventually { theme.appearance == .light && theme.reduceMotion }
        XCTAssertTrue(applied, "an edit to theme.json on disk did not reach the running app")
        XCTAssertEqual(theme.diskApplies, 1)
        // Its own save afterwards is not read back.
        theme.glassIntensity = 0.5
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(theme.diskApplies, 1, "the theme's own save was applied as an outside edit")
        let onDisk = try JSONDecoder().decode(ThemeSettings.self, from: Data(contentsOf: url))
        XCTAssertEqual(onDisk.glassIntensity, 0.5, accuracy: 0.001, "the theme's own save did not land")
        XCTAssertEqual(onDisk.appearance, .light, "applying the outside edit lost it on the next save")
    }

    // MARK: - Self-Upgrade source checkout

    /// After a click finds the checkout gone, Build it re-arms by itself when
    /// the checkout or source.json comes back, with no tab reload.
    func test_aMissingCheckoutReArmsByItselfWhenItComesBack() async throws {
        let base = temp()
        let checkout = base.appendingPathComponent("grux", isDirectory: true)
        let sourceFile = base.appendingPathComponent("source.json")
        func makeCheckout() throws {
            let fm = FileManager.default
            try fm.createDirectory(at: checkout.appendingPathComponent("Grux-Mac"), withIntermediateDirectories: true)
            try Data().write(to: checkout.appendingPathComponent("Grux-Mac/Package.swift"))
            try fm.createDirectory(at: checkout.appendingPathComponent(".git"), withIntermediateDirectories: true)
        }
        try makeCheckout()
        try JSONEncoder().encode(WorkOrderSource(path: checkout.path, commit: "abc1234", binaryMtime: 1))
            .write(to: sourceFile)
        let watch = SourceCheckoutWatch { FoundryEngine.resolveRepoRoot(environment: [:], sourceFile: sourceFile) != nil }
        XCTAssertTrue(watch.available)
        let loop = Task { await watch.watch(every: .milliseconds(50)) }
        defer { loop.cancel() }

        // The checkout goes, and a click finds it gone.
        try FileManager.default.removeItem(at: checkout)
        watch.markMissing()
        XCTAssertFalse(watch.available)
        try makeCheckout()
        let back = await eventually { watch.available }
        XCTAssertTrue(back, "the card stayed on cannot build here after the checkout came back")

        // source.json goes and comes back the same way.
        let recorded = try Data(contentsOf: sourceFile)
        try FileManager.default.removeItem(at: sourceFile)
        let gone = await eventually { !watch.available }
        XCTAssertTrue(gone, "a removed source.json still offered Build it")
        try recorded.write(to: sourceFile)
        let rearmed = await eventually { watch.available }
        XCTAssertTrue(rearmed, "a restored source.json did not re-arm Build it")
    }

    /// The pane keeps the watch running while it is visible, and the click
    /// path hands its finding to the watch rather than to a one-off flag.
    func test_theSelfUpgradePaneKeepsTheCheckoutLive() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(contentsOf: root.appendingPathComponent("Sources/Grux/Foundry/SelfUpgradeView.swift"),
                              encoding: .utf8)
        XCTAssertTrue(view.contains(".task { await source.watch() }"), "the pane does not keep the checkout live")
        XCTAssertTrue(view.contains("source.markMissing()"))
        XCTAssertFalse(view.contains("@State private var sourceAvailable"), "a one-off flag came back")
    }
}
