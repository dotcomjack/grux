import SwiftUI

struct LaunchRootView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var speech = SpeechEngine.shared
    /// Changes only when hearing starts or stops, never at audio rate.
    @ObservedObject private var micHealth = MicHealth.shared
    // Item 24: canonical shell moments (focus verdicts, workflow runs, agent
    // jobs) fill the gap when no local signal is active.
    @ObservedObject private var shellBus = ShellStateBus.shared
    // Items 23+26: repaint GruxTheme call-sites when the accent palette or
    // appearance commits (revision bumps only on committed changes).
    @ObservedObject private var theme = ThemeConfig.shared
    // Sidebar IA (blueprint section 02): grouped sections with persisted
    // collapse state, pinned favorites, and palette recents all hang off
    // this store.
    @ObservedObject private var sidebarStore = SidebarStateStore.shared
    // Mailbox unread badge on the sidebar row. MailStore publishes message
    // changes, so the count stays live as the IMAP sync engine refreshes.
    @ObservedObject private var mailStore = MailStore.shared
    // First run. Gated here rather than at the window construction site because
    // this is the single view every entry point lands on: the menu bar, the
    // dock icon, `--open-tab=`, and a notification tap all arrive through
    // openLaunchWindow. A gate at those call sites would be four gates.
    @ObservedObject private var onboarding = OnboardingModel.shared
    @State var defaultTab: String = "home"
    @State private var selection: Tab = .home
    // Guards the one-time launch-tab application. Without it, the detail-pane
    // rebuild (theme.revision .id change) re-fired onAppear and yanked the
    // user back to defaultTab ('chat') on every committed appearance change.
    @State private var didApplyLaunchTab = false

    /// CaseIterable so the pane-fit sweep walks every case: a new tab cannot
    /// escape it (PaneFitSweepTests).
    enum Tab: Hashable, CaseIterable { case home, reactor, chat, jaxHQ, jaxCommand, cognitionMap, featureReview, projects, tasks, agents, meetings, calendar, documents, creative, designStudio, compare, cookbook, folders, notes, research, skills, schedules, speakers, contacts, mailbox, roadmap, commands, workflows, metaAds, social, focus, selfUpgrade, integrations, settings, labs, tuning }

    /// The one word this orb, the menu bar, the HUD and the focus card all
    /// show. Resolved in ShellStateBus so no surface can invent its own.
    /// The same helper the Command Panel calls, so the two shells cannot
    /// compute the word differently.
    private var listeningTell: ListeningTell {
        ListeningTell.resolve(state: state, speech: speech, notHearing: micHealth.notHearing)
    }

    private var orbState: GruxOrbState {
        // An alert is the one thing that outranks the listening story on the
        // glow. The pill keeps telling the truth about the microphone.
        if shellBus.current.mode == .alert { return ShellMode.alert.orbState }
        // With listening off there is no microphone story to tell, so the
        // shell bus (focus, workflows, agents) gets the orb back.
        if listeningTell == .off { return shellBus.current.mode.orbState }
        return listeningTell.orbState
    }

    var body: some View {
        // The shared destructive-confirmation dialog is hosted here, once, at the
        // window root. Menu and context-menu items cannot own their own: they
        // dismiss on tap and take an attached dialog with them, so the action
        // would fire unguarded. See DestructiveConfirm.
        content.destructiveConfirmHost()
    }

    @ViewBuilder
    private var content: some View {
        if onboarding.isPresenting {
            // Replaces the shell rather than overlaying it. A sheet over a live
            // Home would render the previous owner's greeting behind the very
            // screen asking the new user their name.
            OnboardingView().environmentObject(state)
        } else {
            shell
        }
    }

    private var shell: some View {
        // Manual HStack layout replaces NavigationSplitView. SwiftUI's
        // split view on macOS renders the sidebar as a translucent
        // overlay that visually extends over the detail pane's leading
        // edge, so the longest row label lost its first 5 characters
        // under the sidebar blur. An explicit HStack gives
        // true non-overlapping columns.
        HStack(spacing: 0) {
            sidebar
                // Deliberately FIXED, and close to the only content width in
                // the app that stays that way. It is global chrome, not tab
                // content: it holds the same rows at every window size and its
                // hero orb is a fixed 68pt, so flexing it would shift the whole
                // app's chrome every time a detail pane resized, for no gain.
                // It also has headroom rather than a clipping risk: at the
                // sidebar row font the longest label ("Feature Review") plus
                // its icon, badge and List insets comes to roughly 165 of the
                // 240. The cost is 29% of the 840pt floor, but the floor is a
                // floor: on an ordinary 1440pt window it is about 17%. Every
                // budget in GruxLayout subtracts this number, which is why it
                // lives there and not here.
                .frame(width: GruxLayout.navRail)
                // THREE modifiers, and each one is load-bearing. `.frame(width:)`
                // alone is a PREFERENCE: when the HStack is over-committed it
                // proposes less to every child, the rail keeps DRAWING at 240
                // inside a smaller slot, and SwiftUI centres an oversized child,
                // so it bleeds off BOTH edges at once. That is why the section
                // header rendered as "OMMAND" with the leading C sliced off,
                // rather than simply looking narrow.
                //
                // fixedSize makes the rail state 240 as its true size so it is
                // never proposed less, and layoutPriority serves it before the
                // detail pane so the squeeze lands on the half that can scroll
                // and truncate. Measured at the 840pt floor before this: 240pt
                // on Calendar and Tasks, 230pt on Chat, 217pt on Home. After:
                // 240pt everywhere.
                //
                // The arithmetic still closes, so this starves nothing:
                // 840 - 240 - 1 = 599, and the widest tab minimum is chat at 560.
                // Serve the rail before the detail pane, so the squeeze lands on
                // the half that can scroll and truncate.
                .layoutPriority(1)
                // The Home overflow this comment used to describe is FIXED, and
                // the fix was exactly where the old note predicted: a child in
                // Home/ that would not shrink. HomeHeroView's backdrop was a
                // ZStack member, so the stack reported the backdrop's width
                // demand as its own; it moved to a .background() modifier, which
                // is sized BY its primary view and contributes nothing to
                // layout. Re-verified by screenshot at 840x560 on 2026-08-11:
                // the rail measures a full 240pt on Home and the section header
                // reads "COMMAND", not "OMMAND".
                //
                // Ruled out by measurement, so do not re-try these if a similar
                // overflow ever returns: the quick action pills' labels,
                // `.clipped()` on this rail (the rail does not overflow its own
                // slot, the whole stack overflows the window), and `.fixedSize()`
                // here, which made it WORSE on other tabs by raising their
                // minimums. Bisect for the child that will not shrink instead.

            Divider()

            SurfacePane(selection: $selection)
        }
        // Window floor MUST be >= nav sidebar (240) + the widest detail pane's
        // min so content never overflows and clips. The chat tab is the widest
        // at 560, so 240 + 560 = 800; 840 adds slack. Every other tab flexes
        // with no hard min, so they reflow freely above this floor. Previously
        // 900 sat BELOW the real chat content min (~1060), which is why
        // narrowing the window clipped the sidebar and chat off both edges.
        // These two numbers are the origin of every width in GruxLayout, which
        // is why they are read from there: a floor lowered here without the
        // panes shrinking to match puts the clipping straight back.
        .frame(minWidth: GruxLayout.windowFloorWidth, minHeight: GruxLayout.windowFloorHeight)
        // Paper cut (Foundry UX audit 2026-06-10): untinted system controls
        // (segmented pickers, checkboxes, sliders, toggles) rendered macOS
        // default blue against the violet brand. One root tint sweeps every
        // surface; views that already set an explicit .tint keep winning.
        .tint(GruxTheme.accentPrimary)
        .onAppear {
            // One-shot: apply the launch tab only the first time. The detail
            // pane's .id(theme.revision) rebuild does not re-fire this onAppear
            // (it lives on the un-keyed HStack), and the guard is belt-and-
            // suspenders against any other re-appear.
            guard !didApplyLaunchTab else { return }
            didApplyLaunchTab = true
            applyTab(defaultTab)
            state.requestedTab = Self.tabKey(for: selection)
        }
        .onChange(of: state.requestedTab) { _, new in
            applyTab(new)
        }
        .onChange(of: selection) { _, new in
            // Feed the palette's recent-tabs section. Fires for sidebar
            // clicks AND programmatic applyTab jumps (both mutate selection).
            sidebarStore.recordRecent(Self.tabKey(for: new))
            // The request follows what is showing. It is only heard on a
            // change, so a stale value (a sidebar click away, or a tab asked
            // for while first run covered the shell) swallowed the next ask
            // for that same tab. Setting it to the key already applied is a
            // no-op round trip through applyTab.
            state.requestedTab = Self.tabKey(for: new)
        }
        .onReceive(NotificationCenter.default.publisher(for: .gruxOpenAgentJobWindow)) { note in
            // Posted by the fire-test-expand-job CLI trigger. Mirrors what
            // the right-click "Expand" menu item does from inside AgentsView.
            if let jobId = note.userInfo?["jobId"] as? String {
                openWindow(id: "agent-job", value: jobId)
            }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            sidebarHero
            List(selection: $selection) {
                // Pinned favorites float above the groups. Right-click any
                // row to pin or unpin; order is pin order.
                if !sidebarStore.pinned.isEmpty {
                    Section {
                        ForEach(sidebarStore.pinned, id: \.self) { key in
                            if let item = SidebarIA.item(forKey: key) {
                                sidebarRow(item)
                            }
                        }
                    } header: {
                        sidebarGroupHeader("Pinned")
                    }
                }
                // THE 3.0 RAIL. Twelve surfaces, then the doors, then
                // Settings, computed from the door recorded on each registry
                // row rather than from a hand-maintained list of 35 keys in
                // five groups. `SidebarIA.groups` is still the source of
                // icons, labels and the locked --open-tab keys, and every one
                // of those keys still resolves: folding changes where a person
                // FINDS something, never whether a script can reach it.
                ForEach(railSplit.scrolling) { row in
                    switch row.kind {
                    case .surface(let key):
                        if let item = railItem(for: row, key: key) {
                            sidebarRow(item)
                        }
                    case .door(let id):
                        Section(isExpanded: expansionBinding("door." + id)) {
                            // Behind the Labs door the door itself says BETA, once.
                            ForEach(doorContents(id), id: \.key) { sidebarRow($0) }
                        } header: {
                            HStack(spacing: 6) {
                                if id == "labs" {
                                    // The door opens its shelf; the chevron still
                                    // lists the eight underneath it.
                                    Button { selection = .labs } label: {
                                        sidebarGroupHeader("\(row.label)  \(row.count)")
                                    }
                                    .buttonStyle(.plain)
                                    .help("Open the Labs shelf")
                                } else {
                                    sidebarGroupHeader("\(row.label)  \(row.count)")
                                }
                                if id == "labs" { BetaBadge() }
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            // The pinned tail. A List of its own rather than a bare row,
            // because a sidebar row outside a List loses both its styling and
            // its part in `selection`, and a Settings row that cannot be
            // selected is worse than one that scrolls away.
            if !railSplit.pinned.isEmpty {
                Divider().opacity(0.35)
                List(selection: $selection) {
                    ForEach(railSplit.pinned) { row in
                        if case .surface(let key) = row.kind,
                           let item = railItem(for: row, key: key) {
                            sidebarRow(item)
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .frame(height: GruxLayout.pinnedRailTailHeight)
            }
            statusBar
        }
        .background(GruxTheme.base.opacity(0.25))
    }

    /// The rail a person sees, recomputed when the brand roster or the
    /// developer switch changes.
    private var rail: [SidebarRow] {
        SidebarIA.rail(developerUnlocked: state.config.developerSurfacesUnlocked,
                       brands: BrandRoster.brands.map(\.label))
    }

    /// The row that is pinned below the scrolling rail rather than inside it.
    private static let pinnedTailId = "settings"

    /// The rail splits in two: everything above scrolls, the last row is
    /// PINNED just above the status bar.
    ///
    /// WHY. `SidebarIA` defines Settings to be last and
    /// `PanelReachabilityTests.test_settingsIsAlwaysLast` holds it there, which
    /// makes Settings the row most likely to fall off the bottom of a
    /// scrolling list. Measured 2026-09-24 in a 1040x732 window, which is what
    /// this Mac opens: the rail ended visibly at the Developer door with the
    /// Labs door AND Settings both below the fold, and a band of dead space
    /// under the last visible row, which reads as the end of a list rather
    /// than the middle of one. Nothing on screen said there was more. Proven
    /// by resizing to 1083pt, where the Labs door appeared, and then scrolling,
    /// where Settings appeared last exactly as the model says.
    ///
    /// Raising the window floor does not fix it. The floor is 560pt, far below
    /// the 732pt that already failed, and on a small display any taller
    /// default still clips. Pinning works at every height.
    ///
    /// This is the same move the status bar below already makes, and the same
    /// one the onboarding footer makes for its primary button.
    ///
    /// IT NEVER DROPS A ROW. If Settings ever stops being last, the guard
    /// below returns the whole rail as scrolling and pins nothing, so the
    /// worst case is the old behaviour rather than a row that exists in the
    /// model and renders nowhere. `SidebarRailSplitTests` proves the two
    /// halves rebuild the model's rail exactly, for every combination of the
    /// developer switch and the brand roster.
    var railSplit: (scrolling: [SidebarRow], pinned: [SidebarRow]) {
        Self.splitRail(rail)
    }

    /// Pure, so the partition is testable without a window.
    static func splitRail(_ all: [SidebarRow]) -> (scrolling: [SidebarRow], pinned: [SidebarRow]) {
        guard let last = all.last, last.id == pinnedTailId else { return (all, []) }
        return (Array(all.dropLast()), [last])
    }

    /// A rail row rendered through the existing row view. The rail owns the
    /// LABEL (Mailbox reads Mail, Design Studio reads Studio) while the key
    /// and icon come from the locked table, so a relabel never moves a key.
    private func railItem(for row: SidebarRow, key: String) -> SidebarItem? {
        guard let base = SidebarIA.item(forKey: key) else { return nil }
        return SidebarItem(key: base.key, label: row.label, icon: row.icon)
    }

    /// What a door opens onto, in registry order, skipping anything that is
    /// not a tab of its own. `FeatureRegistry.tabKey` is what stops a door
    /// listing a row that opens nothing.
    private func doorContents(_ doorId: String) -> [SidebarItem] {
        let disposition: FeatureRow.Disposition = doorId == "developer" ? .developer : .labs
        var items = SidebarIA.behind(disposition).compactMap { row -> SidebarItem? in
            guard let key = FeatureRegistry.tabKey(forRowId: row.id) else { return nil }
            return SidebarIA.item(forKey: key)
        }
        if disposition == .labs {
            items += SidebarIA.labsOnlyKeys.compactMap { SidebarIA.item(forKey: $0) }
        }
        return items
    }

    /// One sidebar row. It never carries a BETA pill: the Labs door is badged
    /// once, and a labs feature outside that door is labelled beside its own
    /// title (`LabsHeaderBadge`).
    @ViewBuilder
    private func sidebarRow(_ item: SidebarItem) -> some View {
        if let tab = Self.tab(forKey: item.key) {
            // A dot, not a count, and never a red one. This marks a tab whose
            // feature is waiting on something, and the contract is explicit that
            // needs-setup is a state rather than a failure, so it wears the
            // accent colour everything optional in this app wears. Red would say
            // broken.
            //
            // It sits beside the TITLE rather than at the trailing edge, and
            // that is a correction rather than a preference. The first version
            // used `.overlay(alignment: .trailing)` with a comment claiming it
            // deliberately avoided the badge slot. It did not: `.badge()` draws
            // at the trailing edge too, so on the Mailbox row the dot landed on
            // top of the unread count and the render showed "205" with a dot
            // through it. The comment described the intent and the code did
            // something else, which is only visible in a screenshot.
            Label {
                HStack(spacing: 5) {
                    Text(item.label)
                    // NO PER-ROW BETA PILL, anywhere. The Labs door carries
                    // one badge for the surfaces behind it, and a labs
                    // feature that lives elsewhere says BETA once beside its
                    // own title (`LabsHeaderBadge`). Decided 2026-09-22.
                    if FeatureRegistry.state(forTab: item.key) == .needsSetup {
                        Circle()
                            .fill(GruxTheme.accentPrimary)
                            .frame(width: 5, height: 5)
                            .accessibilityLabel("needs setup")
                    }
                }
            } icon: {
                Image(systemName: item.icon)
            }
                .badge(railBadge(for: item.key))
                .tag(litTag(for: tab))
                .contextMenu {
                    if sidebarStore.isPinned(item.key) {
                        Button("Unpin from favorites") { sidebarStore.unpin(item.key) }
                    } else {
                        Button("Pin to favorites") { sidebarStore.pin(item.key) }
                    }
                }
        }
    }

    private func sidebarGroupHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(GruxType.microCaps)
            .kerning(GruxType.microCapsTracking)
            .foregroundStyle(.secondary)
    }

    private func expansionBinding(_ groupId: String) -> Binding<Bool> {
        Binding(
            get: { sidebarStore.isExpanded(groupId) },
            set: { sidebarStore.setExpanded(groupId, $0) }
        )
    }

    private var sidebarHero: some View {
        VStack(spacing: 8) {
            // Tapping the orb toggles the mic (mutes/unmutes ambient + wake).
            // Kept as .plain button style so OrbView's custom gradient renders
            // without SwiftUI's default button chrome.
            Button {
                MicController.toggle(source: "orb")
            } label: {
                OrbView(state: orbState, level: speech.outputLevel)
                    .frame(width: 68, height: 68)
            }
            .buttonStyle(.plain)
            .gruxHoverable(lift: 1.06, rimOnHover: 0, fillOnHover: 0)
            .orbDecisionHelp(listeningTell.help)
            // A click mutes; a right click tunes.
            .contextMenu {
                Button(TuningCopy.title) { selection = .tuning }
                Button(TuningCopy.optimizeTitle) { OptimizeState.shared.isOpen = true }
            }
            .padding(.top, 10)

            Text("GRUX OS")
                .font(.headline.weight(.heavy))
                .kerning(3)
            // Optimize Grux: the one front door for changing Grux, through
            // the person's own coding agent. Not a rail row, so the first-run
            // count does not move.
            OptimizeGruxButton()
            // NO LISTENING PILL HERE. It said ARMED directly above the same
            // word in the rail's foot, which is two elements doing one job in
            // one viewpoint. The foot keeps it because the foot is also where
            // you tap to mute. The orb's glow still carries the state.
            // Foundry pending-proposal badge. Renders nothing when the
            // Foundry is quiet (pendingCount == 0), so it adds no chrome.
            FoundryStatusBadge { selection = .selfUpgrade }
            // Running-swarm-jobs count pill. Renders nothing when no jobs
            // are active, same zero-chrome rule as the Foundry badge.
            ActivitySwarmBadge { selection = .agents }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private func applyTab(_ tab: String) {
        // String names are LOCKED: the --open-tab automation and tests
        // depend on them. tab(forKey:) carries the exact same cases the old
        // inline switch did, including the "foundry" alias; unknown strings
        // still fall back to chat.
        selection = Self.tab(forKey: tab) ?? .chat
    }

    /// applyTab key -> Tab. Keys match SidebarIA and the --open-tab CLI
    /// names exactly. Returns nil for unknown keys so callers choose their
    /// own fallback.
    static func tab(forKey key: String) -> Tab? {
        switch key {
        case "home": return .home
        case "reactor": return .reactor
        case "chat": return .chat
        case "jaxHQ": return .jaxHQ
        case "jaxCommand": return .jaxCommand
        case "cognitionMap": return .cognitionMap
        case "featureReview": return .featureReview
        case "settings": return .settings
        case "projects": return .projects
        case "tasks": return .tasks
        case "agents": return .agents
        case "meetings": return .meetings
        case "calendar": return .calendar
        case "documents": return .documents
        case "creative": return .creative
        case "designStudio": return .designStudio
        case "compare": return .compare
        case "cookbook": return .cookbook
        case "folders": return .folders
        case "notes": return .notes
        case "research": return .research
        case "skills": return .skills
        case "schedules": return .schedules
        case "speakers": return .speakers
        case "contacts": return .contacts
        case "mailbox": return .mailbox
        case "roadmap": return .roadmap
        // P-E-3: the Labs shelf, what the Labs door opens.
        case "labs": return .labs
        // P-E-2: Tuning, opened from the orb, Today, the palette and Settings.
        case "tuning": return .tuning
        case "commands": return .commands
        case "workflows": return .workflows
        case "metaAds": return .metaAds
        case "social": return .social
        case "focus": return .focus
        case "selfUpgrade", "foundry": return .selfUpgrade
        case "design": return .designStudio
        case "integrations": return .integrations
        default: return nil
        }
    }

    /// Tab -> applyTab key (inverse of tab(forKey:), canonical names only).
    static func tabKey(for tab: Tab) -> String {
        switch tab {
        case .home: return "home"
        case .reactor: return "reactor"
        case .chat: return "chat"
        case .jaxHQ: return "jaxHQ"
        case .jaxCommand: return "jaxCommand"
        case .cognitionMap: return "cognitionMap"
        case .featureReview: return "featureReview"
        case .settings: return "settings"
        case .projects: return "projects"
        case .tasks: return "tasks"
        case .agents: return "agents"
        case .meetings: return "meetings"
        case .calendar: return "calendar"
        case .documents: return "documents"
        case .creative: return "creative"
        case .designStudio: return "designStudio"
        case .compare: return "compare"
        case .cookbook: return "cookbook"
        case .folders: return "folders"
        case .notes: return "notes"
        case .research: return "research"
        case .skills: return "skills"
        case .schedules: return "schedules"
        case .speakers: return "speakers"
        case .contacts: return "contacts"
        case .mailbox: return "mailbox"
        case .roadmap: return "roadmap"
        case .commands: return "commands"
        case .workflows: return "workflows"
        case .metaAds: return "metaAds"
        case .social: return "social"
        case .focus: return "focus"
        case .selfUpgrade: return "selfUpgrade"
        case .integrations: return "integrations"
        case .labs: return "labs"
        case .tuning: return "tuning"
        }
    }

    // MARK: - Folded surfaces (Phase C)
    //
    // A folded surface keeps its Tab and its locked key, so `--open-tab` and
    // `~/.grux/fire-open-tab` still reach it. What changes is WHERE it
    // renders: its Tab draws the parent with the child showing, and the
    // parent's rail row stays lit, so the person can see where they are.

    /// Child tab to the tab of the rail row that hosts it.
    static let hostedBy: [Tab: Tab] = [
        .projects: .tasks,
        .creative: .designStudio,
        .research: .designStudio,
        .skills: .chat,
        .speakers: .meetings,
        .workflows: .schedules,
        // C11: the Focus log folds into Today, whose Watching card links to it.
        .focus: .home,
    ]

    /// The tab whose rail row a tab lives behind. A tab nobody hosts is its
    /// own host.
    static func host(of tab: Tab) -> Tab {
        hostedBy[tab] ?? tab
    }

    /// Tasks hosts Projects, which is the grouping Tasks already has.
    static let tasksSurfaces: [HostedSurface] = [
        HostedSurface(.tasks, "Tasks"),
        HostedSurface(.projects, "Projects"),
    ]

    /// Meetings hosts Speakers: a voice is only ever learned from a meeting.
    static let meetingsSurfaces: [HostedSurface] = [
        HostedSurface(.meetings, "Meetings"),
        HostedSurface(.speakers, "Speakers"),
    ]

    /// Schedules hosts Workflows: running one is what a schedule does.
    static let schedulesSurfaces: [HostedSurface] = [
        HostedSurface(.schedules, "Schedules"),
        HostedSurface(.workflows, "Workflows"),
    ]

    /// The Studio rail row hosts three surfaces. Its own key is designStudio,
    /// so Design Studio is the one it opens on.
    static let studioSurfaces: [HostedSurface] = [
        HostedSurface(.designStudio, "Design Studio"),
        HostedSurface(.creative, "Media Studio"),
        HostedSurface(.research, "Research"),
    ]

    /// The tag a rail row carries. A host row takes the selection while it
    /// shows one of its folded surfaces, so the row stays highlighted instead
    /// of the rail showing nothing selected at all.
    private func litTag(for tab: Tab) -> Tab {
        Self.host(of: selection) == tab ? selection : tab
    }

    /// The badge a rail row carries. Mail shows what NEEDS YOU rather than how
    /// much mail exists, and Settings carries the setup count that used to be a
    /// standing sentence in the foot.
    private func railBadge(for key: String) -> Int {
        switch key {
        case "mailbox":  return mailStore.needsYouCount
        case "settings": return FeatureRegistry.featuresNeedingSetup.count
        default:         return 0
        }
    }

    /// B18: listening and mute reachable without opening Settings, using the
    /// shared tell so the words match every other surface.
    private var listeningFoot: some View {
        HStack(spacing: 6) {
            Button {
                MicController.toggle(source: "orb")
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: listeningTell == .muted ? "mic.slash.fill" : "mic.fill")
                        .font(.system(size: 9, weight: .bold))
                    Text(listeningTell.label)
                        .font(.caption2)
                }
                .foregroundStyle(listeningTell == .muted || listeningTell == .off
                                 ? GruxTheme.textTertiary : GruxTheme.successMint)
            }
            .buttonStyle(.borderless)
            .help(listeningTell.help)
            Spacer(minLength: 0)
            // C10: the approvals tray, on every tab, drawn only while
            // something waits. Its own view observes the queue.
            ApprovalsTrayButton()
        }
    }

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack(spacing: 6) {
                Circle()
                    .fill(state.watching ? GruxTheme.successMint : Color.secondary)
                    .frame(width: 8, height: 8)
                Text(state.watching ? "Watching" : "Paused")
                    .font(.caption)
                Spacer()
                Button(state.watching ? "Pause" : "Watch") {
                    state.watching ? FocusWatcher.shared.stop() : FocusWatcher.shared.start()
                }.buttonStyle(.borderless).font(.caption)
            }
            // ONE count, replacing two bespoke prompts that used to live here: a
            // "Grant screen recording" button and an "Add Anthropic API key in
            // Settings" line, both rendered in orange.
            //
            // They were the same defect as the four already removed from the
            // tabs, and they survived the sweep because they do not look like
            // setup UI at a glance and the grep for `setupPrompt` could not see
            // them. Two problems with what was there. Both were hardcoded to one
            // capability each, so the other 38 had no representation anywhere
            // central. And orange reads as a warning, while the contract is
            // explicit that needs-setup is a state and not a failure.
            //
            // The count is the honest version: it speaks for every capability,
            // it is a fact rather than an instruction, and it goes to the one
            // place that can act on all of them.
            // B15: the setup count is a BADGE ON SETTINGS now, not a line in
            // the foot. A permanent sentence at the bottom of the rail reads as
            // a nag: it is there on a fresh install, it is there six months
            // later, and it says the same thing either way. A badge on the row
            // that can act on it is the same fact without the pleading.
            listeningFoot
        }
        .padding(10)
    }
}

// How the Task Stack groups its rows. Persisted in @AppStorage so the
// chosen axis survives relaunches. Add new cases here and extend the
// switch in TasksDetailView.body. Bucket computation + header logic are
// separated so each mode stays self-contained.
enum TaskGroupMode: String, CaseIterable, Identifiable {
    case project, priority
    var id: String { rawValue }
    var label: String {
        switch self {
        case .project:  return "By Project"
        case .priority: return "By Priority"
        }
    }
}

struct TasksDetailView: View {
    @EnvironmentObject var state: AppState
    @State private var newTaskText = ""
    @State private var newTaskProject = ""
    @State private var newTaskPriority: TaskPriority = .now
    // Drop-target highlight state, one per grouping axis so hover rings
    // don't leak across modes when the picker is toggled mid-drag.
    @State private var hoveringProjectDrop: String?
    @State private var hoveringPriorityDrop: TaskPriority?
    @AppStorage("taskStackGroupMode") private var groupMode: TaskGroupMode = .project

    /// The empty stack's copy, static so it can be asserted on.
    ///
    /// Names a concrete example phrase rather than saying "ask in chat",
    /// because the tool that adds a task fires on wording like "remind me to",
    /// and an instruction the user has to guess the shape of is one they will
    /// get wrong once and then stop trying.
    static func emptyCopy(assistantName: String) -> String {
        "Nothing active on the stack. Add one above, or tell \(assistantName) in chat, for example \"remind me to ship the pricing page\"."
    }

    // Sentinel key for the fallback "No Project" bucket. Matches
    // AppState.projectKey("") so drops, reorders, and section identity all
    // agree on what an unassigned task's bucket is.
    private static let noProjectKey = ""
    private static let noProjectLabel = "No Project"

    private var newTaskTitleField: some View {
        TextField("New task…", text: $newTaskText)
            .textFieldStyle(.roundedBorder)
            .onSubmit(submit)
    }

    @ViewBuilder
    private var newTaskControls: some View {
        TextField("Project", text: $newTaskProject)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: GruxLayout.searchFieldMin, idealWidth: GruxLayout.taskProjectFieldWidth,
                   maxWidth: GruxLayout.taskProjectFieldWidth)
        Picker("", selection: $newTaskPriority) {
            ForEach(TaskPriority.allCases) { p in Text(p.label).tag(p) }
        }
        .fixedSize()
        Button("Add", action: submit)
            .keyboardShortcut(.return, modifiers: .command)
            .fixedSize()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                // Paper cut: header was system .title2 while sibling tabs use
                // the GruxType scale; align to the shared title token.
                Text("Task Stack")
                    .font(GruxType.title)
                    .foregroundStyle(GruxTheme.textPrimary)
                Spacer()
                if let t = state.currentTask {
                    Label(t.title, systemImage: "target")
                        .foregroundStyle(.purple).lineLimit(1)
                }
            }.padding()

            // One row where the four controls fit at their widths; on a
            // narrow pane the title field takes a row of its own and the
            // three small controls share the next, so "Add" never truncates
            // to "A...".
            ViewThatFits(in: .horizontal) {
                HStack(spacing: GruxSpacing.s) {
                    newTaskTitleField
                    newTaskControls
                }
                VStack(spacing: GruxSpacing.s) {
                    newTaskTitleField
                    HStack(spacing: GruxSpacing.s) {
                        newTaskControls
                    }
                }
            }
            .padding(.horizontal)

            Picker("", selection: $groupMode) {
                ForEach(TaskGroupMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            .padding(.top, 8)

            List {
                // A COMPLETELY BLANK LIST WAS THE FIRST THING A NEW USER SAW HERE.
                //
                // `groupMode` defaults to `.project`, and `projectSections`
                // iterates buckets DERIVED FROM EXISTING TASKS, so with none
                // there are no buckets and nothing renders at all. The priority
                // mode degrades fine, because it iterates the fixed set of
                // priorities and each says "No tasks", but that is not the mode
                // anybody lands in.
                //
                // The add row above meant nobody was stranded, which is why this
                // survived. What was missing is the half that matters for the
                // product: nothing said the assistant fills this for you.
                if state.topLevelActiveTasks.isEmpty {
                    Text(Self.emptyCopy(assistantName: UserIdentity.assistantName))
                        .font(GruxType.caption)
                        .foregroundStyle(GruxTheme.textTertiary)
                        .padding(.vertical, 10)
                }
                switch groupMode {
                case .project:  projectSections
                case .priority: prioritySections
                }
                if !state.completedTasks.isEmpty {
                    Section("COMPLETED") {
                        ForEach(state.completedTasks.prefix(20)) { t in
                            TaskRow(task: t, showsPriorityPill: true).environmentObject(state)
                        }
                    }
                }
            }
            .listStyle(.inset)
            .animation(.spring(response: 0.32, dampingFraction: 0.82), value: state.tasks)
            .animation(.easeInOut(duration: 0.2), value: groupMode)
        }
    }

    // MARK: - Project grouping

    @ViewBuilder private var projectSections: some View {
        ForEach(projectBuckets, id: \.key) { bucket in
            Section {
                ForEach(bucket.items) { t in
                    TaskWithSubtasks(task: t, showsPriorityPill: true)
                        .environmentObject(state)
                        .draggable(t.id.uuidString)
                }
                .onMove { source, destination in
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                        state.reorderTasks(within: bucket.key, from: source, to: destination)
                    }
                }
            } header: {
                projectHeader(key: bucket.key, label: bucket.label)
            }
        }
    }

    // Group top-level active tasks by canonical project key. Sub-tasks render
    // inline under their parents, so the grouping axis is only asked about
    // parents. "No Project" (empty key) is always rendered last; named
    // projects sort case-insensitively for stable alphabetical order.
    private var projectBuckets: [(key: String, label: String, items: [FocusTask])] {
        let grouped = Dictionary(grouping: state.topLevelActiveTasks) { AppState.projectKey($0.project) }
        let namedKeys = grouped.keys
            .filter { $0 != Self.noProjectKey }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        var buckets: [(key: String, label: String, items: [FocusTask])] = namedKeys.map { k in
            (key: k, label: k, items: grouped[k] ?? [])
        }
        if let fallback = grouped[Self.noProjectKey], !fallback.isEmpty {
            buckets.append((key: Self.noProjectKey, label: Self.noProjectLabel, items: fallback))
        }
        return buckets
    }

    private func projectHeader(key: String, label: String) -> some View {
        let isHovering = hoveringProjectDrop == key
        return HStack(spacing: 8) {
            Text(label.uppercased())
                .font(.caption.weight(.heavy))
                .kerning(1.5)
                .foregroundStyle(.secondary)
            Image(systemName: "arrow.up.and.down")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .opacity(isHovering ? 1.0 : 0.0)
            Spacer()
        }
        .padding(.horizontal, 6).padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHovering ? Color.purple.opacity(0.18) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(
                    isHovering ? Color.purple.opacity(0.55) : Color.clear,
                    style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                )
        )
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { items, _ in
            guard let idString = items.first, let id = UUID(uuidString: idString) else { return false }
            withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) {
                state.moveTask(id, toProject: key)
            }
            return true
        } isTargeted: { targeted in
            withAnimation(.easeOut(duration: 0.15)) {
                hoveringProjectDrop = targeted ? key : (hoveringProjectDrop == key ? nil : hoveringProjectDrop)
            }
        }
    }

    // MARK: - Priority grouping

    @ViewBuilder private var prioritySections: some View {
        ForEach(TaskPriority.allCases) { p in
            let items = state.topLevelActiveTasks.filter { $0.priority == p }
            Section {
                // Paper cut: an empty bucket rendered as a bare header with
                // nothing under it. Keep the header (it stays a drop target)
                // but say so, faintly.
                if items.isEmpty {
                    Text("No tasks. Drag one onto the header.")
                        .font(GruxType.caption)
                        .foregroundStyle(GruxTheme.textTertiary)
                        .padding(.vertical, 2)
                }
                // Priority pill suppressed here: the section header already
                // communicates priority, so rendering it again would just be
                // visual noise. TaskRow still shows the project text.
                ForEach(items) { t in
                    TaskWithSubtasks(task: t, showsPriorityPill: false)
                        .environmentObject(state)
                        .draggable(t.id.uuidString)
                }
                .onMove { source, destination in
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                        state.reorderTasks(within: p, from: source, to: destination)
                    }
                }
            } header: {
                priorityHeader(p)
            }
        }
    }

    private func priorityHeader(_ p: TaskPriority) -> some View {
        let isHovering = hoveringPriorityDrop == p
        return HStack(spacing: 8) {
            Text(p.label)
                .font(.caption.weight(.heavy))
                .kerning(1.5)
                .foregroundStyle(.secondary)
            Image(systemName: "arrow.up.and.down")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .opacity(isHovering ? 1.0 : 0.0)
            Spacer()
        }
        .padding(.horizontal, 6).padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHovering ? Color.purple.opacity(0.18) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(
                    isHovering ? Color.purple.opacity(0.55) : Color.clear,
                    style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                )
        )
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { items, _ in
            guard let idString = items.first, let id = UUID(uuidString: idString) else { return false }
            withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) {
                state.moveTask(id, toPriority: p)
            }
            return true
        } isTargeted: { targeted in
            withAnimation(.easeOut(duration: 0.15)) {
                hoveringPriorityDrop = targeted ? p : (hoveringPriorityDrop == p ? nil : hoveringPriorityDrop)
            }
        }
    }

    private func submit() {
        let t = newTaskText.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        state.addTask(t, project: newTaskProject.trimmingCharacters(in: .whitespaces), priority: newTaskPriority)
        newTaskText = ""; newTaskProject = ""
    }
}

// Wraps a top-level TaskRow + the parent's active sub-tasks + an inline
// "add sub-task" affordance. Kept separate from TaskRow so the menu-bar
// dropdown (which also uses TaskRow) doesn't get sub-task rendering. Full
// sub-task UX is deliberately on the Tasks tab only.
struct TaskWithSubtasks: View {
    @EnvironmentObject var state: AppState
    let task: FocusTask
    var showsPriorityPill: Bool = false

    @State private var addingSubtask = false
    @State private var newSubtaskTitle = ""
    @State private var expanded: Bool = true
    @FocusState private var subtaskFieldFocused: Bool

    private var subtasks: [FocusTask] { state.subtasks(of: task.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                if !subtasks.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                    } label: {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(width: 14)
                    }
                    .buttonStyle(.plain)
                    .help(expanded ? "Collapse sub-tasks" : "Expand sub-tasks")
                } else {
                    Color.clear.frame(width: 14, height: 14)
                }
                TaskRow(task: task, showsPriorityPill: showsPriorityPill)
                    .environmentObject(state)
            }
            if !subtasks.isEmpty && expanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(subtasks) { sub in
                        SubtaskRow(task: sub)
                            .environmentObject(state)
                    }
                }
                .padding(.leading, 28)
            }
            if expanded {
                addSubtaskRow
                    .padding(.leading, 28)
            }
            if !subtasks.isEmpty || expanded {
                let active = subtasks.count
                let completed = state.subtasks(of: task.id, includeCompleted: true).count - active
                if active + completed > 0 {
                    Text(subtaskSummary(active: active, completed: completed))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 42)
                        .padding(.bottom, 2)
                }
            }
        }
    }

    private var addSubtaskRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.turn.down.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            if addingSubtask {
                TextField("Sub-task title", text: $newSubtaskTitle)
                    .textFieldStyle(.plain)
                    .focused($subtaskFieldFocused)
                    .font(.caption)
                    .onSubmit(commitSubtask)
                    .onExitCommand(perform: cancelSubtask)
                Button("Add", action: commitSubtask)
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.small)
                    .disabled(newSubtaskTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel", action: cancelSubtask)
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.small)
            } else {
                Button {
                    addingSubtask = true
                    DispatchQueue.main.async { subtaskFieldFocused = true }
                } label: {
                    Text("Add sub-task")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private func commitSubtask() {
        let title = newSubtaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { cancelSubtask(); return }
        _ = state.addSubtask(parentId: task.id, title: title)
        newSubtaskTitle = ""
        addingSubtask = false
    }

    private func cancelSubtask() {
        newSubtaskTitle = ""
        addingSubtask = false
        subtaskFieldFocused = false
    }

    private func subtaskSummary(active: Int, completed: Int) -> String {
        let total = active + completed
        guard total > 0 else { return "" }
        if completed == 0 { return "\(active) sub-task\(active == 1 ? "" : "s")" }
        if active == 0 { return "\(completed)/\(total) complete ✓" }
        return "\(completed)/\(total) complete"
    }
}

// Lighter row for sub-tasks. Reuses AppState mutations (complete/delete)
// via the same paths as TaskRow but with compact typography and an indent
// that makes the nesting visually obvious.
struct SubtaskRow: View {
    @EnvironmentObject var state: AppState
    let task: FocusTask
    @State private var hovering = false
    @State private var isEditing = false
    @State private var editTitle = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Button {
                task.completed
                    ? state.uncompleteTask(task.id)
                    : state.completeTask(task.id)
            } label: {
                Image(systemName: task.completed ? "checkmark.circle.fill" : "circle")
                    .font(.caption)
                    .foregroundStyle(task.completed ? Color.secondary : Color.primary.opacity(0.7))
            }
            .buttonStyle(.plain)
            if isEditing {
                TextField("Sub-task title", text: $editTitle)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .focused($fieldFocused)
                    .onSubmit(commit)
                    .onExitCommand(perform: cancel)
            } else {
                Text(task.title)
                    .font(.caption)
                    .strikethrough(task.completed, color: .secondary)
                    .foregroundStyle(task.completed ? .secondary : .primary)
                    .lineLimit(2)
            }
            Spacer()
            if hovering && !isEditing {
                Menu {
                    Button("Rename…") { beginEdit() }
                    Button("Promote to top-level") {
                        state.promoteSubtask(task.id)
                    }
                    Divider()
                    DestructiveMenuButton(
                        "Delete",
                        question: "Delete this task?",
                        detail: "The task and its notes are removed. This cannot be undone.",
                        confirmLabel: "Delete task"
                    ) {
                        state.deleteTask(task.id)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.caption2)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { beginEdit() }
    }

    private func beginEdit() {
        editTitle = task.title
        isEditing = true
        DispatchQueue.main.async { fieldFocused = true }
    }

    private func commit() {
        let t = editTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { cancel(); return }
        state.renameTask(task.id, title: t)
        isEditing = false
    }

    private func cancel() {
        isEditing = false
        editTitle = ""
    }
}

struct FocusLogView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Focus Log")
                    .font(GruxType.title)
                    .foregroundStyle(GruxTheme.textPrimary)
                Spacer()
                Text("\(state.events.count) events")
                    .font(GruxType.caption)
                    .foregroundStyle(GruxTheme.textTertiary)
                Button("Run Check Now") { FocusWatcher.shared.runOnceNow() }
            }.padding(.horizontal).padding(.top)

            adminBanner
                .padding(.horizontal)
                .padding(.top, 10)

            List(state.events) { e in
                FocusEventRow(event: e)
            }.listStyle(.inset)
        }
    }

    /// 9 becomes "9:00 AM", 17 becomes "5:00 PM". This banner printed
    /// "9:00-17:00", which is military time and reads as a bug to anyone in the
    /// US whether or not they can say why.
    static func clockLabel(_ hour24: Int) -> String {
        let h = max(0, min(23, hour24))
        let suffix = h < 12 ? "AM" : "PM"
        let display = h % 12 == 0 ? 12 : h % 12
        return "\(display):00 \(suffix)"
    }

    // Dashboard-style banner explaining what the Focus log is doing right
    // now: capture cadence, drift threshold, active-hours window, and the
    // live watching state, so the tab isn't an unexplained feed of events.
    private var adminBanner: some View {
        let cfg = state.config
        // Read from the tier, which is what FocusWatcher actually schedules on.
        // This said "every \(captureIntervalSeconds)s" while the watcher ticked
        // on tier.cadenceSeconds, so on the default tier the banner claimed 30s
        // and the real cadence was 8. A status line that reports a number the
        // system does not use is worse than no status line.
        let intervalLabel = "every \(max(1, cfg.tier.cadenceSeconds))s"
        let driftLabel = "\(cfg.driftThreshold) check\(cfg.driftThreshold == 1 ? "" : "s")"
        let hoursLabel = "\(Self.clockLabel(cfg.activeHoursStart)) to \(Self.clockLabel(cfg.activeHoursEnd))"
        // Was `cfg.focusUseVision ? "vision" : "OCR"`, a toggle that selected
        // nothing. The tier decides whether a local OCR prescreen runs before
        // the cloud vision call, so report that instead.
        let modelLabel = cfg.tier.useLocalPrescreen ? "OCR prescreen, then vision" : "vision"
        let cooldownLabel = "\(cfg.focusCooldownMinutes)m"

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "eye.fill")
                    .foregroundStyle(state.watching ? Color.green : Color.secondary)
                Text(state.watching ? "Watching" : "Paused")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(state.watching ? Color.green : Color.secondary)
                Spacer()
                if !state.screenPermissionGranted {
                    Label("Needs screen recording permission", systemImage: "lock.shield")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Text("Grux samples your active window \(intervalLabel) during \(hoursLabel). Each sample is classified against your current task using \(modelLabel) analysis. After \(driftLabel) consecutive off-task samples, Grux nudges (respecting a \(cooldownLabel) cooldown per app). Entries below are those samples, newest first.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 14) {
                statChip("Cadence", intervalLabel)
                statChip("Drift", driftLabel)
                statChip("Hours", hoursLabel)
                statChip("Model", modelLabel)
                statChip("Cooldown", cooldownLabel)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func statChip(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

struct FocusEventRow: View {
    let event: FocusEvent
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                pill
                Text(event.activeApp).font(.headline)
                if !event.windowTitle.isEmpty {
                    Text("| \(event.windowTitle)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text(event.timestamp, style: .relative).font(.caption2).foregroundStyle(.tertiary)
            }
            Text(event.rationale).font(.caption)
            if let s = event.suggestedTaskTitle, !s.isEmpty {
                Text("Suggested: \(s)").font(.caption).foregroundStyle(.blue)
            }
        }.padding(.vertical, 4)
    }

    private var pill: some View {
        let (label, color): (String, Color) = {
            switch event.verdict {
            case .onTask: return ("on", .green)
            case .drifting: return ("drift", .yellow)
            case .offTask: return ("off", .red)
            case .ambiguous: return ("amb", .gray)
            }
        }()
        return Text(label)
            .font(.caption2.bold())
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(color.opacity(0.2)).foregroundStyle(color)
            .clipShape(Capsule())
    }
}

/// `~/.grux/rendered-tab.txt`: the key of the tab whose pane last rendered.
/// Written after the pane updates, so a script waiting on it (the Phase C gate
/// fires all 35 locked keys through `fire-open-tab`) checks what the person
/// would see rather than what was asked for.
enum RenderedTab {
    static var fileURL: URL { Persistence.gruxDir.appendingPathComponent("rendered-tab.txt") }
    static func note(_ key: String) {
        try? key.write(to: fileURL, atomically: true, encoding: .utf8)
        Task { @MainActor in HeadlessWorkspace.noteRendered(key) }
    }
}
