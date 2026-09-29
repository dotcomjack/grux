import XCTest
@testable import Grux

/// P-E-2: Tuning, shape C. What it says, what its two new dials enforce, where
/// it opens from, and that the controls which moved there left Settings rather
/// than living in two places.
@MainActor
final class TuningTests: XCTestCase {

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func source(_ relative: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(relative), encoding: .utf8)
    }

    // MARK: - What each card says, from live values

    func test_theSummariesSayWhatIsSet() {
        XCTAssertEqual(TuningCopy.acts(threshold: 0.75, mode: .alwaysOn),
                       "Acts at 0.75 or more, listening \(ListeningMode.alwaysOn.label.lowercased()).")
        XCTAssertEqual(TuningCopy.talks(speaks: true, rate: 1.25), "Speaks replies at 1.25x.")
        XCTAssertEqual(TuningCopy.talks(speaks: false, rate: 1.5), "Quiet: replies stay on screen.")
        XCTAssertEqual(TuningCopy.interrupts(start: 9, end: 17, cooldown: 20),
                       "Between \(ClockFormat.hourLabel(9)) and \(ClockFormat.hourLabel(17)), at most every 20 min.")
        XCTAssertTrue(TuningCopy.alone(mode: .grind, ceiling: 0).hasSuffix("self-upgrade proposes only."))
        XCTAssertTrue(TuningCopy.alone(mode: .grind, ceiling: 2).hasSuffix("self-upgrade lands on its own."))
        XCTAssertTrue(TuningCopy.alone(mode: .grind, ceiling: 9).hasSuffix("lands on its own."), "an out of range ceiling must not crash")
        XCTAssertEqual(TuningCopy.spends(count: 3, costUSD: 0.001, budget: 0), "3 decisions today, under $0.01.")
        XCTAssertEqual(TuningCopy.spends(count: 40, costUSD: 0.25, budget: 500), "40 decisions today, $0.25, 500 a day, then on device.")
        XCTAssertTrue(TuningCopy.remembers(memory: false, recapHour: 18).hasPrefix("Forgets when you quit"))
    }

    /// `%.2g` printed 1.25 as "1.2", so the card misstated the speed set.
    func test_theVoiceSpeedReadsExactly() {
        XCTAssertEqual(TuningCopy.rate(1.5), "1.5")
        XCTAssertEqual(TuningCopy.rate(1.25), "1.25")
        XCTAssertEqual(TuningCopy.rate(2.0), "2")
        XCTAssertEqual(TuningCopy.rate(0.75), "0.75")
    }

    func test_noCopyHereUsesADash() {
        let all = [TuningCopy.title, TuningCopy.subtitle, TuningCopy.optimizeTitle, TuningCopy.optimizeBody,
                   TuningCopy.pointer, TuningCopy.settingsLink, TuningCopy.spokenPointer, TuningCopy.memoryPointer,
                   TuningCopy.listeningPointer, TuningCopy.interrupt,
                   TuningCopy.tierPointer(.tier4_hybrid_8s),
                   TuningCopy.decisionsKey(saved: true, capped: true), TuningCopy.decisionsKey(saved: false, capped: false)]
            + TuningCopy.Card.allCases.map(\.title)
        for line in all {
            XCTAssertFalse(line.contains("\u{2014}") || line.contains("\u{2013}"), line)
        }
    }

    // MARK: - The daily decision budget

    private func jev(_ at: Date = Date()) -> DecisionLedgerEntry {
        DecisionLedgerEntry(surface: "s", provider: .jev, latencyMs: 90, inputTokens: 10, outputTokens: 1, at: at, summary: "x")
    }
    private func local(_ at: Date = Date()) -> DecisionLedgerEntry {
        DecisionLedgerEntry(surface: "s", provider: .local, latencyMs: 5, inputTokens: 0, outputTokens: 0, at: at, summary: "x")
    }

    func test_theCapTurnsTheKeyOffUntilMidnight_andOnlyJevRowsCount() {
        let ledger = DecisionLedger(storeURL: nil)
        let engine = DecisionEngine(keyLookup: { "k" }, ledger: ledger, dailyBudget: { 2 })
        ledger.record(jev(Date().addingTimeInterval(-86_400 * 2)))   // an earlier day
        ledger.record(local()); ledger.record(local())
        ledger.record(jev())
        XCTAssertTrue(engine.hasRemoteKey, "one of two used; the key is still live")
        ledger.record(jev())
        XCTAssertFalse(engine.hasRemoteKey, "the cap is reached, so every gate answers on device")
        XCTAssertTrue(engine.hasSavedKey, "the key is still saved, and Tuning must say so")
        XCTAssertTrue(engine.budgetReached())
        XCTAssertEqual(engine.remoteKey(), "", "the batched path reads through the same cap")
        XCTAssertFalse(engine.budgetReached(now: Date().addingTimeInterval(86_400)), "tomorrow starts again")
    }

    func test_noCapMeansNoCap() {
        let ledger = DecisionLedger(storeURL: nil)
        let engine = DecisionEngine(keyLookup: { "k" }, ledger: ledger, dailyBudget: { 0 })
        for _ in 0..<50 { ledger.record(jev()) }
        XCTAssertTrue(engine.hasRemoteKey)
        XCTAssertFalse(engine.budgetReached())
    }

    /// `recent` keeps the last 2,000 rows of every provider, so counting off
    /// it would never trip a cap above what that window holds.
    func test_theCountSurvivesTheLedgerTrim() {
        let ledger = DecisionLedger(storeURL: nil)
        let engine = DecisionEngine(keyLookup: { "k" }, ledger: ledger, dailyBudget: { 2_050 })
        for _ in 0..<2_100 { ledger.record(jev()) }
        XCTAssertEqual(ledger.recent.count, 2_000, "the window this test is about")
        XCTAssertEqual(ledger.remoteDecisions(), 2_100)
        XCTAssertTrue(engine.budgetReached(), "a cap above the window never trips")
    }

    func test_aCappedDecisionNeverCallsOut() async {
        final class Counter: DecisionProvider, @unchecked Sendable {
            let kind: DecisionProviderKind = .jev
            var calls = 0
            func decide(state: String, questions: [String: DecisionQuestion]) async throws -> DecisionResult {
                calls += 1
                return DecisionResult(answers: [:], latencyMs: 1, inputTokens: 1, outputTokens: 1, provider: .jev)
            }
        }
        let counter = Counter()
        let ledger = DecisionLedger(storeURL: nil)
        let engine = DecisionEngine(keyLookup: { "k" }, ledger: ledger, dailyBudget: { 1 }, remote: { _ in counter })
        let q: [String: DecisionQuestion] = ["intent": .choice(instructions: "?", criteria: ["a": "a", "b": "b"])]
        _ = await engine.decide(surface: "t", state: "one", questions: q)
        XCTAssertEqual(counter.calls, 1)
        let second = await engine.decide(surface: "t", state: "two", questions: q)
        XCTAssertEqual(counter.calls, 1, "past the cap the remote was called anyway")
        XCTAssertEqual(second.provider, .local)
    }

    func test_theShippedEngineReadsTheCapFromConfig_andNeverUnderTest() throws {
        let src = try source("Sources/Grux/Decisions/DecisionEngine.swift")
        XCTAssertTrue(src.contains("dailyBudget: { DecisionEngine.isUnderTest ? 0 : AppState.shared.config.dailyDecisionBudget }"))
    }

    // MARK: - The self-upgrade ceiling

    func test_theCeilingOnlyEverLowers_andFailsClosed() {
        for earned in TrustTier.allCases {
            XCTAssertEqual(FoundryEngine.cappedTier(earned: earned, ceiling: 0), .propose)
            XCTAssertEqual(FoundryEngine.cappedTier(earned: earned, ceiling: 2), earned, "the top ceiling must not raise or lower")
            XCTAssertLessThanOrEqual(FoundryEngine.cappedTier(earned: earned, ceiling: 1), .autoBuild)
            XCTAssertEqual(FoundryEngine.cappedTier(earned: earned, ceiling: 7), .propose, "an unreadable ceiling fails open")
            XCTAssertEqual(FoundryEngine.cappedTier(earned: earned, ceiling: -1), .propose)
        }
    }

    func test_theAutoLandDecisionGoesThroughTheCeiling() throws {
        let src = try source("Sources/Grux/Foundry/FoundryEngine.swift")
        let r = try XCTUnwrap(src.range(of: "if Self.shouldAutoLand(earnedTier: earned"), "the auto-land call moved")
        let before = String(src[..<r.lowerBound].suffix(600))
        XCTAssertTrue(before.contains("Self.cappedTier(") && before.contains("config.selfUpgradeMaxTier"),
                      "the auto-land decision no longer applies Tuning's ceiling")
    }

    /// New installs start at propose; an install that predates the dial keeps
    /// the autonomy its lanes have already earned.
    func test_theDefaults() throws {
        XCTAssertEqual(GruxConfig.default.dailyDecisionBudget, 0)
        XCTAssertEqual(GruxConfig.default.selfUpgradeMaxTier, 0)
        // A config written before the two dials existed: today's, minus them.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(GruxConfig.default)) as? [String: Any])
        XCTAssertNotNil(json.removeValue(forKey: "dailyDecisionBudget"))
        XCTAssertNotNil(json.removeValue(forKey: "selfUpgradeMaxTier"))
        let old = try JSONDecoder().decode(GruxConfig.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(old.dailyDecisionBudget, 0)
        XCTAssertEqual(old.selfUpgradeMaxTier, 2)
        var c = GruxConfig.default
        c.dailyDecisionBudget = 700; c.selfUpgradeMaxTier = 1
        let back = try JSONDecoder().decode(GruxConfig.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(back.dailyDecisionBudget, 700)
        XCTAssertEqual(back.selfUpgradeMaxTier, 1)
    }

    // MARK: - Where it opens from

    func test_itHasNoRailRow_andEveryDoorOpensIt() throws {
        XCTAssertEqual(LaunchRootView.tab(forKey: "tuning"), .tuning)
        XCTAssertEqual(LaunchRootView.tabKey(for: .tuning), "tuning")
        XCTAssertFalse(SidebarIA.rail(developerUnlocked: true, brands: []).contains { $0.id == "tuning" },
                       "Tuning has a rail row, which the decision ruled out")
        XCTAssertNil(SidebarIA.item(forKey: "tuning"), "Tuning has a rail item")

        let root = try source("Sources/Grux/LaunchRootView.swift")
        let orb = try XCTUnwrap(root.components(separatedBy: ".orbDecisionHelp(listeningTell.help)").dropFirst().first)
        XCTAssertTrue(orb.prefix(300).contains("selection = .tuning"), "the orb does not open Tuning")
        XCTAssertTrue(orb.prefix(300).contains("OptimizeState.shared.isOpen = true"), "the orb does not offer Tell Grux what you want")
        XCTAssertTrue(try source("Sources/Grux/Shell/SurfacePane.swift").contains("case .tuning: TuningView()"), "nothing renders Tuning")
        XCTAssertTrue(try source("Sources/Grux/Home/HomeView.swift").contains("requestedTab = \"tuning\""), "Today does not open Tuning")
        let palette = try source("Sources/Grux/Shell/OrbCommandPalette.swift")
        XCTAssertTrue(palette.contains("id: \"tuning\"") && palette.contains("openLaunchWindow(tab: \"tuning\")"), "the palette does not open Tuning")
        let menu = try source("Sources/Grux/MenuBarView.swift")
        XCTAssertTrue(menu.contains("openLaunchWindow(tab: \"tuning\")"), "the menu bar does not open Tuning")
        XCTAssertTrue(menu.contains("TuningCopy.optimizeTitle"), "the menu bar does not carry Tell Grux what you want")
        XCTAssertTrue(try source("Sources/Grux/Tuning/TuningView.swift").contains("OptimizeState.shared.isOpen = true"),
                      "Tuning's own call to action opens nothing")
    }

    func test_settingsLinksToItFromTheTop_andSearchFindsIt() throws {
        let settings = try source("Sources/Grux/SettingsView.swift")
        let general = try XCTUnwrap(settings.components(separatedBy: "private var generalPane: some View {").dropFirst().first)
        let first = try XCTUnwrap(general.range(of: "sectionVisible(\""))
        XCTAssertTrue(general[first.upperBound...].hasPrefix("general.tuning\""), "Tuning is not the first thing in General")
        XCTAssertEqual(SettingsTabAliases.map["tuning"]?.anchor, "general.tuning")
        for word in ["tuning", "voice speed", "snooze", "active hours", "budget", "self-upgrade", "intelligence tier", "recap"] {
            XCTAssertTrue(SettingsSearchRegistry.matches(word).contains { $0.id == "general.tuning" },
                          "searching Settings for \(word) does not reach the Tuning link")
        }
    }

    // MARK: - The controls that moved left Settings

    /// Every config value a Tuning dial writes, read out of Tuning's source so
    /// a new dial is covered without anybody editing this list.
    private func tuningKeys() throws -> Set<String> {
        let src = try source("Sources/Grux/Tuning/TuningView.swift")
        let rx = try NSRegularExpression(pattern: #"binding\(\\\.(\w+)"#)
        let ns = src as NSString
        var keys = Set(rx.matches(in: src, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) })
        if src.contains("state.config.tier = tier") { keys.insert("tier") }
        return keys
    }

    func test_theScanFindsTheDials() throws {
        let keys = try tuningKeys()
        XCTAssertGreaterThanOrEqual(keys.count, 17, "the scan found fewer dials than Tuning has, so it is not reading them: \(keys.sorted())")
        for k in ["listeningThreshold", "dailyDecisionBudget", "selfUpgradeMaxTier", "tier", "memoryEnabled", "snoozeMinutes"] {
            XCTAssertTrue(keys.contains(k), k)
        }
    }

    /// Settings' save() writes every @State mirror it holds, so a mirror of a
    /// value Tuning owns would put the old value back on the next save.
    func test_settingsWritesNoValueTuningOwns() throws {
        let files = ["Sources/Grux/SettingsView.swift", "Sources/Grux/Settings/ListeningSection.swift"]
        for file in files {
            let src = try source(file)
            let ns = src as NSString
            for k in try tuningKeys() {
                // An assignment (not `==`) or a key path handed to a binding.
                let rx = try NSRegularExpression(pattern: #"((config|\bc)\.\#(k)\s*=(?!=))|(\\\.\#(k)\b)"#)
                let hit = rx.firstMatch(in: src, range: NSRange(location: 0, length: ns.length))
                XCTAssertNil(hit, "\(file) still writes \(k) (\(hit.map { ns.substring(with: $0.range) } ?? "")), beside Tuning")
            }
        }
    }

    /// A dial nothing reads is a switch that does nothing. `bargeInEnabled`
    /// was exactly that from the first commit to P-E-2.
    func test_everyDialIsReadBySomethingOutsideTuningAndSettings() throws {
        let skip = ["Models.swift", "Tuning/TuningView.swift", "SettingsView.swift", "Settings/ListeningSection.swift"]
        let files = (FileManager.default.enumerator(at: Self.root.appendingPathComponent("Sources/Grux"), includingPropertiesForKeys: nil)?
            .allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "swift" && !skip.contains(where: $0.path.hasSuffix) }
        let texts = try files.map { try String(contentsOf: $0, encoding: .utf8) }
        XCTAssertGreaterThan(texts.count, 200, "the scan read too few files to mean anything")
        for k in try tuningKeys() {
            let rx = try NSRegularExpression(pattern: #"(config|cfg|\bc)\.\#(k)\b(?!\s*=[^=])"#)
            let read = texts.contains { t in rx.firstMatch(in: t, range: NSRange(location: 0, length: (t as NSString).length)) != nil }
            XCTAssertTrue(read, "\(k) is a Tuning dial that nothing outside Tuning reads, so moving it does nothing")
        }
    }

    func test_eachMovedSectionPointsAtTuning() throws {
        let settings = try source("Sources/Grux/SettingsView.swift")
        for anchor in ["general.tuning", "general.hours", "voice.replies", "models.tier", "data.memory"] {
            let open = try XCTUnwrap(settings.range(of: "sectionVisible(\"\(anchor)\")"), anchor)
            let close = try XCTUnwrap(settings.range(of: ".id(\"\(anchor)\")", range: open.upperBound..<settings.endIndex), anchor)
            XCTAssertTrue(settings[open.upperBound..<close.lowerBound].contains("TuningPointer("), "\(anchor) moved to Tuning and does not say so")
        }
        let snooze = try XCTUnwrap(settings.components(separatedBy: "Section(\"Snooze\") {").dropFirst().first)
        XCTAssertTrue(snooze.prefix(80).contains("TuningPointer("), "Snooze moved to Tuning and does not say so")
        XCTAssertTrue(try source("Sources/Grux/Settings/ListeningSection.swift").contains("TuningPointer(text: TuningCopy.listeningPointer)"))
        XCTAssertFalse(settings.contains("tierCard"), "the old tier cards are still in Settings beside Tuning's")
    }

    /// Grux does not listen while it talks, so the card says the true way to
    /// interrupt instead of offering a switch for something nothing does.
    func test_theTalksCardSaysHowToInterrupt() throws {
        XCTAssertTrue(TuningCopy.interrupt.contains("microphone") && TuningCopy.interrupt.contains("mute"))
        let tuning = try source("Sources/Grux/Tuning/TuningView.swift")
        XCTAssertTrue(tuning.contains("note(TuningCopy.interrupt)"))
        XCTAssertFalse(try source("Sources/Grux/Models.swift").contains("var bargeInEnabled"))
    }
}
