import Foundation

/// One proposed action the Optimize card puts up front when it opens. Not a
/// setting: a work order the person copies and gives to their own coding
/// agent, which then builds it. Data only, so the Self-Upgrade pipeline can
/// supply the next one without touching the card.
///
/// It is NOT a handoff of its own. Its `request` and `detail` go through the
/// one work order line (`WorkOrderStore.createAndCopy`), so the agent gets
/// the same stations, reports to a progress log, and ends at live.
struct OptimizeProposal: Identifiable, Equatable {
    let id: String
    /// Five words at most.
    let headline: String
    /// One sentence, fifteen words at most: what it fixes.
    let line: String
    /// The work order's request: what the person is asking for, in a sentence.
    let request: String
    /// What to add, where, and the acceptance checks, for an agent with no
    /// knowledge of this repo. Rides inside the one template.
    let detail: String
    /// The Success card, once the change exists: what is ready (not what is
    /// on, the setting may default off), five words at most, and one line
    /// saying where it lives.
    let successHeadline: String
    let successLine: String
    /// A Settings deep link tag (`SettingsTabAliases`) that lands on the new
    /// setting, or nil when there is none. Drives Open the setting.
    let settingsTag: String?
    /// How Grux tells, live, that the change already exists.
    let alreadyDone: Retirement

    /// A proposal retires itself: the moment its change exists, the card
    /// stops offering it, with no dismissal to remember.
    enum Retirement: Equatable {
        /// Done when the running build's settings know this key.
        case configKey(String)

        var isDone: Bool {
            switch self {
            case .configKey(let key): return Self.configKnows(key)
            }
        }

        /// Encodes the running build's default settings and looks for the
        /// key, so the answer is what this binary does, not what a list says.
        static func configKnows(_ key: String) -> Bool {
            guard let data = try? JSONEncoder().encode(GruxConfig.default),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            return json[key] != nil
        }
    }
}

/// What the card shows for one proposal.
enum ProposalCardState: Equatable {
    /// Not built yet. `station` is where its work order is, once one exists.
    case proposed(station: WorkOrderStage?)
    /// Its change exists: the Success card, until the person says Got it.
    case success
    /// Got it was pressed. Never shown again, across relaunches.
    case hidden
}

/// One proposal and what the card shows for it.
struct ProposalCard: Equatable {
    let proposal: OptimizeProposal
    let state: ProposalCardState
}

/// Where the card asks what to propose: the first shipped proposal whose
/// change does not exist yet. A later source (the Foundry, a work order
/// that finished) plugs in here.
enum OptimizeProposals {
    /// Every proposal this build carries, retired ones included, because a
    /// retired one is how the mechanism is proven.
    static let shipped: [OptimizeProposal] = [.keepOnTop]

    static var current: OptimizeProposal? { current(from: shipped) }

    static func current(from proposals: [OptimizeProposal]) -> OptimizeProposal? {
        proposals.first { !$0.alreadyDone.isDone }
    }

    /// Done is whichever signal comes first: the proposal's own work order
    /// wrote `done`, or the live check sees the change in the running build
    /// (which also catches a change an agent shipped with no done line).
    ///
    /// The live check reads the BUILD, and every build from the one that
    /// added the change has it, so on its own it says nothing about this
    /// install. Success on the live check needs evidence that this install
    /// did the work: an order for the proposal in any state, or the Proposed
    /// card shown here (`seen`). With neither, the change is simply there
    /// and unmentioned: no card for it, the next proposal shows.
    static func state(for proposal: OptimizeProposal, orders: [WorkOrderStore.Order],
                      acknowledged: Set<String>, seen: Set<String> = []) -> ProposalCardState {
        if acknowledged.contains(proposal.id) { return .hidden }
        let mine = orders.filter { $0.proposalId == proposal.id }
        if mine.contains(where: { $0.progress.stage == .done }) { return .success }
        if proposal.alreadyDone.isDone {
            return mine.isEmpty && !seen.contains(proposal.id) ? .hidden : .success
        }
        // The newest order still moving; one that stopped does not hide it.
        if let moving = mine.first(where: { !$0.progress.stage.isFinished }) {
            return .proposed(station: moving.progress.stage)
        }
        return .proposed(station: nil)
    }

    /// The card to show: the first proposal, in shipped order, that is not
    /// hidden and not set aside with Not now this launch.
    static func card(from proposals: [OptimizeProposal], orders: [WorkOrderStore.Order],
                     acknowledged: Set<String>, seen: Set<String> = [], setAside: Set<String> = []) -> ProposalCard? {
        for proposal in proposals where !setAside.contains(proposal.id) {
            let state = state(for: proposal, orders: orders, acknowledged: acknowledged, seen: seen)
            if state != .hidden { return ProposalCard(proposal: proposal, state: state) }
        }
        return nil
    }
}

extension OptimizeProposal {
    /// The first proposal shipped with the app. The panel window dropped
    /// behind whatever the person clicked next. Built on 2026-09-27 as
    /// `GruxConfig.keepOnTop`, so its live check is true in every build from
    /// then on: an install that copied the fix or saw the card gets the
    /// Success card until Got it, and a fresh install sees nothing for it.
    static let keepOnTop = OptimizeProposal(
        id: "keep-on-top",
        headline: "Keep Grux on top",
        line: "Stops the panel dropping behind the next window you click.",
        request: "Add a Keep Grux on top setting, off by default, that keeps the Command Panel above other windows.",
        detail: keepOnTopDetail,
        successHeadline: "Ready: Keep Grux on top",
        successLine: "Turn it on in Settings, General.",
        // The Shell section, where the toggle sits under Classic sidebar.
        settingsTag: "classic",
        alreadyDone: .configKey("keepOnTop")
    )

    /// The detail for `keepOnTop`. Pure text, no view, no path from this Mac.
    /// The rules, the build, the tests and the install come from the template.
    static let keepOnTopDetail: String = """
    Grux's Command Panel is a normal window, so it drops behind whatever the person clicks next. Add one setting that keeps it at the floating window level while it is on, default off.

    ### What to add

    1. A config value. In Sources/Grux/Models.swift, `struct GruxConfig` holds every persisted setting. Add `var keepOnTop: Bool` beside `legacyShell`: the stored property, its CodingKeys case, the init parameter with a default of false, and in the decoding init `keepOnTop = try c.decodeIfPresent(Bool.self, forKey: .keepOnTop) ?? false`, so a config.json written before the key existed decodes to off. Nothing else about persistence changes: `AppState.shared.saveConfig()` already writes the whole struct.

    2. A Settings toggle. In Sources/Grux/SettingsView.swift, the General pane has a `Section("Shell")` with a `Toggle("Classic sidebar", ...)` bound to `state.config.legacyShell` that calls `state.saveConfig()` in its setter. Add `Toggle("Keep Grux on top", ...)` right after it, bound the same way to `state.config.keepOnTop`, with one caption line under it: "The panel stays above other windows. Off by default." Use the same modifiers the Classic sidebar caption uses (`GruxType.caption`, `GruxTheme.textTertiary`).

    3. The window level. The panel window is created once in `AppDelegate.openLaunchWindow(tab:)` in Sources/Grux/GruxApp.swift: an NSWindow titled "Grux OS", hosting `ShellRootView`, which shows `CommandPanelRoot` (the Command Panel) or `LaunchRootView` (the classic sidebar shell) depending on `legacyShell`. The delegate keeps it as `launchWindow`, and `LaunchWindowSizer` (Sources/Grux/Shell/LaunchWindowSizer.swift) does its sizing. Add a pure mapping, for example on `LaunchWindowSizer`:

       static func level(keepOnTop: Bool, legacyShell: Bool) -> NSWindow.Level

       It returns `.floating` when keepOnTop is on and legacyShell is off, and `.normal` in every other case. The classic sidebar shell is unaffected: with legacyShell on, the level is `.normal` whatever the toggle says.

    4. Apply it twice. On launch: in `openLaunchWindow`, right after `launchWindow = win`, set `win.level` from the mapping using `AppState.shared.config`. On toggle: add `func applyLaunchWindowLevel()` to AppDelegate that reads the two config values and sets `launchWindow?.level` from the same mapping, and call it whenever either value changes. `ShellRootView` already observes `AppState.shared.$config.map(\\.legacyShell).removeDuplicates()` and calls `AppDelegate.shared?.applyLaunchWindowShell(legacy:)`; observe `keepOnTop` the same way (its own `.onReceive`, `removeDuplicates()`), and also call `applyLaunchWindowLevel()` from the legacyShell branch so switching shells re-applies the level. Only `launchWindow` changes level. The Settings window, the chat window, the pairing window and every NSPanel keep the levels they have.

    ### Acceptance checks

    - Toggle on: click another app's window. The Grux panel stays visible above it.
    - Toggle off: click another app's window. The panel drops behind it, as today.
    - Toggle on, quit Grux, relaunch. The panel is on top from the first frame, with no toggle press.
    - Classic sidebar on, Keep Grux on top on: the classic shell window behaves as it always did (normal level).
    - Settings > General shows the toggle under Classic sidebar, off on a fresh install.

    ### Tests, red first

    XCTest, in Tests/GruxTests/. Follow Tests/GruxTests/ConfigLegacyShellTests.swift for the config shape:

    - `LaunchWindowLevelTests`: the mapping. (on, panel) is `.floating`; (off, panel), (on, classic) and (off, classic) are `.normal`.
    - `ConfigKeepOnTopTests`: `GruxConfig.default.keepOnTop` is false; a config JSON with the key removed decodes to false; the key round trips through JSONEncoder and JSONDecoder.

    Smallest change that does the job. Do not restyle the Settings pane, move the window code, or touch the classic shell.
    """
}
