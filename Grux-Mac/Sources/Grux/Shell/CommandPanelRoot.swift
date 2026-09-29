import SwiftUI
import AppKit
import Combine

/// The tab key that means "no pane, just the panel".
enum PanelKeys {
    static let none = "panel"
}

/// A pane's honest minimum width: the narrowest its surface still renders
/// whole. Every surface is meant to be fluid down to `detailContentMin`, and
/// PaneFitSweepTests holds each one to that at its floor. A surface that truly
/// cannot go that narrow is named in `table` with its reason, and the panel
/// asks the window for it when that pane opens (`PanelModel.sizeForPane`),
/// the same way it grows a short window to a minimum height.
enum PaneMinimum {
    static let table: [LaunchRootView.Tab: CGFloat] = [
        // A radial instrument: its telemetry panels flank the core it reports
        // on, and narrower they cover it.
        .reactor: GruxLayout.reactorPaneMin,
        // A chat rail beside a live preview, which has no one-column form.
        .designStudio: GruxLayout.designStudioPaneMin,
    ]

    static func width(for tab: LaunchRootView.Tab) -> CGFloat {
        max(GruxLayout.detailContentMin, table[tab] ?? 0)
    }
}

/// Selection and Now for the Command Panel. A class rather than view state so
/// the tests can drive it without a window, and so a request that arrives
/// during onboarding can be held and honored afterwards.
@MainActor
final class PanelModel: ObservableObject {
    @Published var pane: LaunchRootView.Tab? = nil
    @Published var now: [PanelItem] = []

    /// Set by the root from `OnboardingModel.isPresenting`. While true, a
    /// requested tab is held, not opened; the last one held opens after.
    var onboardingPresenting = false {
        didSet {
            guard !onboardingPresenting, let held else { return }
            self.held = nil
            apply(held.key, via: held.via)
        }
    }
    private var held: (key: String, via: OpensLog.Via)?

    /// Onboarding started over: whatever was held before it is stale.
    func dropHeldRequest() { held = nil }

    /// Runs `work` after `delay` seconds on the main actor.
    typealias Scheduler = @MainActor (_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> Void
    /// Asks the launch window for a content width and a content minimum width.
    typealias WindowSizer = @MainActor (_ width: CGFloat, _ minWidth: CGFloat) -> Void
    /// Asks the launch window for a content minimum height.
    typealias HeightFloor = @MainActor (_ minHeight: CGFloat) -> Void
    /// Asks the launch window for a content minimum width, growing a
    /// narrower window to it and leaving a wider one alone.
    typealias WidthFloor = @MainActor (_ minWidth: CGFloat) -> Void

    private let stateProvider: (@MainActor () -> RelevanceState)?
    private let slowInputs: @MainActor (Date) -> RelevanceState.SlowInputs
    /// The calendar and setup gaps last read; see `refreshNow(includingSlow:)`.
    private var slow: RelevanceState.SlowInputs?
    private let refreshInterval: TimeInterval
    private let jobExists: @MainActor (String) -> Bool
    private let signIn: @MainActor () -> Void
    private let clock: () -> Date
    private let schedule: Scheduler
    private let sizeWindow: WindowSizer
    private let floorHeight: HeightFloor
    private let floorWidth: WidthFloor
    private let paneMinimum: @MainActor (LaunchRootView.Tab) -> CGFloat
    /// The pane minimum last asked of the window, so a swap between two panes
    /// with the same minimum asks nothing.
    private var paneFloor: CGFloat?
    private var lastRefresh = Date.distantPast
    /// Bumped by every refresh that runs, so a trailing refresh scheduled
    /// before it knows it has been overtaken and does nothing.
    private var refreshGeneration = 0
    private var trailingPending = false
    /// Whether a pane was open at the last resize; nil means "size on the
    /// next pass whatever the state". The window grows when a pane opens and
    /// shrinks when it closes (spec 3.3); swapping one pane for another
    /// keeps whatever width the person gave it.
    private var paneWasOpen: Bool?
    private var observers: Set<AnyCancellable> = []

    /// `stateProvider` is what Now is decided from; tests pass a hand-built
    /// state, and nil means this Mac's stores, with `slowInputs` for the
    /// calendar and setup gaps. `jobExists` says whether a job row still has a
    /// job to open. `clock` and `schedule` drive the refresh throttle, and
    /// `sizeWindow`, `floorHeight` and `floorWidth` the launch window, and
    /// `paneMinimum` names each pane's honest minimum, so tests can run all of
    /// it without a clock or a window.
    init(stateProvider: (@MainActor () -> RelevanceState)? = nil,
         slowInputs: @escaping @MainActor (Date) -> RelevanceState.SlowInputs = { RelevanceState.SlowInputs.live(now: $0) },
         refreshInterval: TimeInterval = 1,
         jobExists: @escaping @MainActor (String) -> Bool = { id in
             AgentService.shared.jobs.contains { $0.id == id }
         },
         signIn: @escaping @MainActor () -> Void = { ClaudeSignInState.shared.startSignIn() },
         clock: @escaping () -> Date = Date.init,
         schedule: Scheduler? = nil,
         sizeWindow: @escaping WindowSizer = { width, minWidth in
             AppDelegate.shared?.setLaunchWindowContentWidth(width, minWidth: minWidth, animated: true)
         },
         floorHeight: @escaping HeightFloor = { minHeight in
             if let win = AppDelegate.shared?.launchWindow {
                 LaunchWindowSizer(window: win).setMinimumHeight(minHeight)
             }
         },
         floorWidth: @escaping WidthFloor = { minWidth in
             if let win = AppDelegate.shared?.launchWindow {
                 LaunchWindowSizer(window: win).setMinimumWidth(minWidth)
             }
         },
         paneMinimum: @escaping @MainActor (LaunchRootView.Tab) -> CGFloat = { PaneMinimum.width(for: $0) }) {
        self.stateProvider = stateProvider
        self.slowInputs = slowInputs
        self.refreshInterval = refreshInterval
        self.jobExists = jobExists
        self.signIn = signIn
        self.clock = clock
        self.schedule = schedule ?? Self.afterDelay
        self.sizeWindow = sizeWindow
        self.floorHeight = floorHeight
        self.floorWidth = floorWidth
        self.paneMinimum = paneMinimum
    }

    static let afterDelay: Scheduler = { delay, work in
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            work()
        }
    }

    // MARK: Opening and closing

    /// A request through `AppState.requestedTab`: the trigger contract, the
    /// palette, `--open-tab`, and the echo of the panel's own opens. The door
    /// it came through is whatever the caller named in `OpensLog.nextVia`.
    func applyRequested(_ key: String) {
        let via = OpensLog.shared.nextVia ?? .trigger
        OpensLog.shared.nextVia = nil
        apply(key, via: via)
    }

    private func apply(_ key: String, via: OpensLog.Via) {
        if onboardingPresenting { held = (key, via); return }
        if key == PanelKeys.none {
            pane = nil
            // A request that arrived as the new root's launch key (the live
            // shell switch) leaves requestedTab on whatever the old shell last
            // asked for; a later request for that same key would then be no
            // change at all, and nothing would open.
            if AppState.shared.requestedTab != PanelKeys.none { AppState.shared.requestedTab = PanelKeys.none }
            return
        }
        // An unknown key opens Chat, exactly as the legacy shell's applyTab.
        let tab = LaunchRootView.tab(forKey: key) ?? .chat
        // The pane already open: nothing to do, and nothing to record. This is
        // also what the echo of the panel's own `requestedTab` write lands on.
        if tab == pane { return }
        open(tab, via: via)
    }

    /// Every door into a pane ends here. It is the only place an open is
    /// counted. The pane already open counts nothing and moves no recent:
    /// sending from the input while Chat is up is not an open.
    func open(_ tab: LaunchRootView.Tab, via: OpensLog.Via) {
        // A door named for a request that turned out to be no change is spent
        // here, so a later, unrelated open cannot inherit it.
        OpensLog.shared.nextVia = nil
        guard tab != pane else { return }
        show(tab)
        OpensLog.shared.record(key: LaunchRootView.tabKey(for: tab), via: via)
    }

    func openKey(_ key: String, via: OpensLog.Via) {
        guard let tab = LaunchRootView.tab(forKey: key) else { return }
        open(tab, via: via)
    }

    /// A move inside the open pane (a hosted switcher, the activity strip, a
    /// Labs card). Recorded as a recent and written to `requestedTab`, but
    /// not counted as an open: it came through no door.
    func move(to tab: LaunchRootView.Tab) {
        guard tab != pane else { return }
        show(tab)
    }

    /// Writes the key it opened to `requestedTab`, so a later request for the
    /// same key from any source is a change the root sees.
    private func show(_ tab: LaunchRootView.Tab) {
        let key = LaunchRootView.tabKey(for: tab)
        pane = tab
        if AppState.shared.requestedTab != key { AppState.shared.requestedTab = key }
        SidebarStateStore.shared.recordRecent(key)
    }

    /// `requestedTab` is a String and `onChange` fires only on a change, so
    /// the close resets it; otherwise the same key could not open twice.
    func closePane() {
        pane = nil
        AppState.shared.requestedTab = PanelKeys.none
    }

    /// The title bar button: an open pane closes back to the panel; with none
    /// open, the most recent pane comes back (Settings is its own window, so
    /// never that one), and Chat when there is nothing recent.
    func togglePane() {
        if pane != nil { closePane(); return }
        let key = SidebarStateStore.shared.recents.first {
            $0 != "settings" && LaunchRootView.tab(forKey: $0) != nil
        } ?? LaunchRootView.tabKey(for: .chat)
        openKey(key, via: .recent)
    }

    // MARK: Actions

    func perform(_ action: PanelAction) {
        switch action {
        case .open(let key):
            openKey(key, via: .now)
        case .openApprovals:
            ApprovalsTrayState.shared.isOpen = true
        case .openWorkOrder(let id):
            OptimizeHubState.shared.highlightedOrder = id
            OptimizeHubState.shared.isExpanded = true
        case .setup(let featureId):
            openSetup(featureId)
        case .openOptimize:
            OptimizeHubState.shared.isExpanded = true
        case .openJob(let id):
            if jobExists(id) {
                NotificationCenter.default.post(name: .gruxOpenAgentJobWindow, object: nil,
                                                userInfo: ["jobId": id])
            } else {
                openKey("agents", via: .now)
            }
        case .claudeSignIn:
            signIn()
        case .revealClaudeSettings:
            let settings = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/settings.json")
            if WindowFacade.isHeadless {
                WindowFacade.withhold("reveal \(settings.path) in Finder")
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([settings])
            }
        }
    }

    /// A setup gap opens the surface, whose capability gate shows the card.
    /// The four registry rows with no tab of their own open where they live.
    private func openSetup(_ featureId: String) {
        if let key = FeatureRegistry.tabKey(forRowId: featureId) {
            openKey(key, via: .now)
        } else if featureId == "approvals" {
            ApprovalsTrayState.shared.isOpen = true
        } else if featureId == "phone" {
            AppDelegate.shared?.openPhonePairingWindow()
        } else if let parent = featureId.split(separator: ".").first {
            openKey(String(parent), via: .now)
        }
    }

    // MARK: Now

    /// At most once per `refreshInterval`; the stores publish far more often.
    /// A request inside the window is never dropped: it schedules one
    /// trailing refresh at the window's end. `includingSlow` re-reads the
    /// calendar and the setup gaps too: on appear and on the 60 s timer only
    /// (R5.10), so a burst of store changes costs no EventKit fetch.
    func refreshNow(force: Bool = false, includingSlow: Bool = false) {
        let since = clock().timeIntervalSince(lastRefresh)
        if force || since >= refreshInterval {
            refreshGeneration += 1
            trailingPending = false
            lastRefresh = clock()
            now = Relevance.now(state(includingSlow: includingSlow))
            return
        }
        guard !trailingPending else { return }
        trailingPending = true
        let generation = refreshGeneration
        schedule(refreshInterval - since) { [weak self] in
            guard let self, self.refreshGeneration == generation else { return }
            self.refreshNow(force: true)
        }
    }

    private func state(includingSlow: Bool) -> RelevanceState {
        if let stateProvider { return stateProvider() }
        let at = clock()
        if includingSlow || slow == nil { slow = slowInputs(at) }
        return RelevanceState.live(now: at, slow: slow ?? RelevanceState.SlowInputs())
    }

    // MARK: Window

    /// The shell's width for the pane state: `panelWidth` with no pane,
    /// `panelWidth + paneWidth` with one, and the minimum to match: the
    /// panel plus the open pane's own minimum (`PaneMinimum`). Resized only
    /// when the open state flips, or on the first pass, which also gives the
    /// panel its height floor back after onboarding raised it. Swapping one
    /// pane for another keeps the person's width and only moves the floor,
    /// growing the window when the new pane needs more than it has.
    func sizeForPane() {
        let open = pane != nil
        let floor = pane.map(paneMinimum) ?? 0
        guard open != paneWasOpen else {
            guard open, floor != paneFloor else { return }
            paneFloor = floor
            floorWidth(GruxLayout.panelWidth + floor)
            return
        }
        if paneWasOpen == nil { floorHeight(GruxLayout.panelMinHeight) }
        paneWasOpen = open
        paneFloor = open ? floor : nil
        sizeWindow(open ? GruxLayout.panelWidth + max(GruxLayout.paneWidth, floor) : GruxLayout.panelWidth,
                   open ? GruxLayout.panelWidth + floor : GruxLayout.panelWidth)
    }

    /// Onboarding needs more than the panel, in both directions. The shell's
    /// next pass sizes the window back, whatever the pane state was before.
    func sizeForOnboarding() {
        paneWasOpen = nil
        floorHeight(GruxLayout.onboardingMinHeight)
        sizeWindow(GruxLayout.onboardingMinWidth, GruxLayout.onboardingMinWidth)
    }

    /// Refresh when any input to Now changes: approvals, mail, agent jobs,
    /// work orders, tasks, workflow runs, proposals, the Claude sign-in and an old hook left
    /// for the person. Calendar, setup gaps
    /// and brands have no publisher worth trusting, so a 60 s timer covers them.
    func startObserving() {
        guard observers.isEmpty else { return }
        let changes: [AnyPublisher<Void, Never>] = [
            ApprovalQueue.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            MailStore.shared.$messages.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            AgentService.shared.$jobs.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            WorkOrderStore.shared.$orders.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            AppState.shared.$tasks.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            CommandV2Engine.shared.$activeRuns.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            // The count Now shows is the dashboard's, as the Improve door's.
            FoundryDashboardModel.shared.$proposals.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            ClaudeSignInState.shared.$expired.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            // Follows ~/.claude/settings.json live, so a hook removed by hand clears the row.
            TerminalFocusHookState.shared.$needsManualRemoval.dropFirst().map { _ in () }.eraseToAnyPublisher(),
        ]
        // Delivered on the next turn of the main queue: the publishers fire
        // before the new value is stored, and Now must read the new value.
        Publishers.MergeMany(changes)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.refreshNow() }
            .store(in: &observers)
        Timer.publish(every: 60, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.refreshNow(force: true, includingSlow: true) }
            .store(in: &observers)
    }
}

/// The Command Panel shell: one column at rest, one pane beside it on demand.
struct CommandPanelRoot: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow
    @StateObject private var model: PanelModel
    @ObservedObject private var onboarding = OnboardingModel.shared
    @ObservedObject private var theme = ThemeConfig.shared
    private let defaultTab: String
    // Guards the one-time launch-tab application, as in LaunchRootView.
    @State private var didApplyLaunchTab = false

    /// `model` is for tests; the app lets the root own a fresh one.
    init(defaultTab: String = PanelKeys.none, model: PanelModel? = nil) {
        self.defaultTab = defaultTab
        _model = StateObject(wrappedValue: model ?? PanelModel())
    }

    var body: some View {
        // The shared destructive-confirmation dialog is hosted once, at the
        // window root, for the reason LaunchRootView gives.
        content
            .destructiveConfirmHost()
            // Requests are handled HERE, on the view that stays mounted while
            // onboarding presents, so a request made during onboarding is
            // held by the model and opened the moment onboarding finishes.
            .onAppear {
                model.onboardingPresenting = onboarding.isPresenting
                // The panel's 420 would clip the first-run flow.
                if onboarding.isPresenting { model.sizeForOnboarding() }
                guard !didApplyLaunchTab else { return }
                didApplyLaunchTab = true
                model.applyRequested(defaultTab)
                model.startObserving()
                model.refreshNow(force: true, includingSlow: true)
            }
            .onChange(of: onboarding.isPresenting) { _, presenting in
                model.onboardingPresenting = presenting
                if presenting {
                    // Starting over from a pane must not leave its key to
                    // reopen after the flow; requests made during it are
                    // still held and opened after, as before.
                    model.dropHeldRequest()
                    if state.requestedTab != PanelKeys.none { state.requestedTab = PanelKeys.none }
                    model.sizeForOnboarding()
                } else {
                    // The flow may have picked features: their gaps are new.
                    model.refreshNow(force: true, includingSlow: true)
                }
            }
            .onChange(of: state.requestedTab) { _, key in
                model.applyRequested(key)
            }
            .onReceive(NotificationCenter.default.publisher(for: .gruxTogglePane)) { _ in
                // Posted by the title bar button. Onboarding owns the window
                // while it presents, so the button waits for it.
                guard !onboarding.isPresenting else { return }
                model.togglePane()
            }
            .onReceive(NotificationCenter.default.publisher(for: .gruxOpenAgentJobWindow)) { note in
                // Posted by a job row and by the fire-test-expand-job trigger.
                if let jobId = note.userInfo?["jobId"] as? String {
                    openWindow(id: "agent-job", value: jobId)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if onboarding.isPresenting {
            OnboardingView().environmentObject(state)
        } else {
            shell
        }
    }

    private var shell: some View {
        HStack(spacing: 0) {
            // Both columns are contained (PaneSlot): each takes the width it is
            // offered and draws nowhere else, so neither can spill over the
            // other or past the window edge, whatever a surface demands.
            panel
                .containedInOffer()
                .frame(width: GruxLayout.panelWidth)
                .layoutPriority(1)
            if let tab = model.pane {
                Divider()
                paneColumn(tab)
                    .containedInOffer()
                    .frame(minWidth: PaneMinimum.width(for: tab), idealWidth: GruxLayout.paneWidth,
                           maxWidth: .infinity)
            }
        }
        .frame(minWidth: GruxLayout.panelWidth, maxWidth: .infinity,
               minHeight: GruxLayout.panelMinHeight, maxHeight: .infinity, alignment: .topLeading)
        .tint(GruxTheme.accentPrimary)
        .background(GruxTheme.base)
        .task(id: model.pane) {
            // With no pane the panel reports itself, so sweeps that read
            // rendered-tab.txt can tell "closed" from "never opened". An open
            // pane reports its own key from SurfacePane.
            if model.pane == nil {
                await Task.yield()
                RenderedTab.note(PanelKeys.none)
            }
            model.sizeForPane()
        }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: GruxSpacing.l) {
            // The head's orb menu and badges count as `.now`: they are status
            // the panel surfaces, like a Now row, and `OpensLog.Via` has no
            // closer case (its seven cases are fixed, R3.4).
            PanelHead(onOpen: { model.openKey($0, via: .now) },
                      onOptimize: { model.perform(.openOptimize) })
                .id(theme.revision)
            // Not keyed on the theme: a remount would take focus from an open
            // pane and drop the draft. The input observes the theme instead.
            PanelInput(onTuning: { model.openKey("tuning", via: .input) },
                       onSend: { text in
                model.open(.chat, via: .input)
                Task { await ChatService.shared.send(userText: text) }
            })
            // The middle scrolls (R9.6): an expanded Optimize card is taller
            // than a short window, and the head, input and foot stay put.
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: GruxSpacing.l) {
                    PanelNowList(items: model.now, onAction: { model.perform($0) })
                    OptimizeHubCard()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
            .id(theme.revision)
            // Grux Settings stays its own window (spec 3.6), the same one the
            // menu bar opens; the settings key still renders in a pane when a
            // trigger asks for it.
            PanelFoot(onOpen: { model.openKey($0, via: .recent) },
                      onSettings: { WindowOpener.openSettings() })
                .id(theme.revision)
        }
        .padding(GruxSpacing.l)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func paneColumn(_ tab: LaunchRootView.Tab) -> some View {
        let binding = Binding<LaunchRootView.Tab>(
            get: { model.pane ?? tab },
            set: { model.move(to: $0) })
        return VStack(spacing: 0) {
            // Spec 3.3: the surface name on the left, a close control on the right.
            HStack(spacing: GruxSpacing.s) {
                Text(SidebarIA.railLabel(forKey: LaunchRootView.tabKey(for: LaunchRootView.host(of: tab))))
                    .font(GruxType.title)
                    .foregroundStyle(GruxTheme.textPrimary)
                    .lineLimit(1)
                Spacer()
                Button {
                    model.closePane()
                } label: {
                    Image(systemName: "xmark")
                        .font(GruxType.caption)
                        .foregroundStyle(GruxTheme.textSecondary)
                }
                .buttonStyle(.borderless)
                .help(PanelCopy.closePane)
                .accessibilityLabel(PanelCopy.closePane)
            }
            .padding(.horizontal, GruxSpacing.l)
            .frame(height: GruxLayout.paneBarHeight)
            Divider()
            SurfacePane(selection: binding)
                .environment(\.hostedInPane, true)
        }
        // Escape closes the pane when focus is in it. Not a window-wide
        // cancel shortcut: surfaces inside the pane bind their own (Tasks,
        // Calendar, Contacts), and a nearer handler keeps its Escape.
        .onExitCommand { model.closePane() }
    }
}
