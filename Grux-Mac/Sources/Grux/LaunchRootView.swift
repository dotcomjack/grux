import SwiftUI

struct LaunchRootView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var speech = SpeechEngine.shared
    @ObservedObject private var wake = WakeWordListener.shared
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

    enum Tab: Hashable { case home, reactor, chat, jaxHQ, jaxCommand, cognitionMap, featureReview, projects, tasks, agents, meetings, calendar, documents, creative, designStudio, compare, cookbook, folders, notes, research, skills, schedules, speakers, contacts, mailbox, roadmap, commands, workflows, metaAds, social, focus, terminalFocus, selfUpgrade, integrations, settings }

    private var orbState: GruxOrbState {
        // Muted wins over everything so the user always sees their tap reflected.
        if state.micMuted { return .muted }
        if speech.isSpeaking || speech.isBuffering { return .speaking }
        if state.isThinking { return .thinking }
        if wake.isListening { return .listening }
        return shellBus.current.mode.orbState
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
        // edge, so "Terminal Focus" showed as "nal Focus" with the first
        // 5 characters under the sidebar blur. An explicit HStack gives
        // true non-overlapping columns.
        HStack(spacing: 0) {
            sidebar
                // Deliberately FIXED, and close to the only content width in
                // the app that stays that way. It is global chrome, not tab
                // content: it holds the same rows at every window size and its
                // hero orb is a fixed 68pt, so flexing it would shift the whole
                // app's chrome every time a detail pane resized, for no gain.
                // It also has headroom rather than a clipping risk: at the
                // sidebar row font the longest label ("Terminal Focus") plus
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

            VStack(spacing: 0) {
                Group {
                    switch selection {
                    // NOT gated, deliberately. Home is a COMPOSITE of
                    // independent tiles, so a tab-level gate would hide a dozen
                    // working sections because one registrar credential is
                    // missing. It gates per SECTION instead, which is why the
                    // domain monitor renders its own card.
                    case .home: HomeView()
                    case .reactor: ReactorView().capabilityGated("reactor")
                    case .chat: ChatView().capabilityGated("chat")
                    case .jaxHQ: JaxHQView().capabilityGated("jaxHQ")
                    case .jaxCommand: JaxCommandView().capabilityGated("jaxCommand")
                    case .cognitionMap: CognitionMapView().capabilityGated("cognitionMap")
                    case .featureReview: FeatureReviewView().capabilityGated("featureReview")
                    case .projects: ProjectsView().capabilityGated("projects")
                    case .tasks: TasksDetailView().capabilityGated("tasks")
                    case .agents: AgentsView().capabilityGated("agents")
                    case .meetings: MeetingsView().capabilityGated("meetings")
                    case .calendar: CalendarView().capabilityGated("calendar")
                    case .documents: DocumentLibraryView().capabilityGated("documents")
                    case .creative: CreativeStudioView().capabilityGated("creative")
                    case .designStudio: DesignStudioView().capabilityGated("designStudio")
                    case .compare: CompareView().capabilityGated("compare")
                    case .cookbook: CookbookView().capabilityGated("cookbook")
                    case .folders: FoldersManagementView().capabilityGated("folders")
                    case .notes: NotesView().capabilityGated("notes")
                    case .research: ResearchView().capabilityGated("research")
                    case .skills: SkillsView().capabilityGated("skills")
                    case .schedules: UserCronEditorView().capabilityGated("schedules")
                    case .speakers: SpeakersView().capabilityGated("speakers")
                    case .contacts: ContactsView().capabilityGated("contacts")
                    case .mailbox: MailboxView().capabilityGated("mailbox")
                    case .roadmap: RoadmapView()
                    case .commands: CommandsView().capabilityGated("commands")
                    case .workflows: CommandsV2View().capabilityGated("workflows")
                    case .metaAds: MetaAdsView().capabilityGated("metaAds")
                    case .social: SocialView().capabilityGated("social")
                    case .focus: FocusLogView().capabilityGated("focus")
                    case .terminalFocus: TerminalFocusSettingsView().capabilityGated("terminalFocus")
                    case .selfUpgrade: SelfUpgradeView().capabilityGated("selfUpgrade")
                    case .integrations: IntegrationsView().capabilityGated("integrations")
                    // NEVER gated, and this one is a hard rule rather than a
                    // preference. Settings is where every capability is fixed,
                    // so gating it on a capability would be a deadlock: the card
                    // would tell somebody to go to Settings while standing in
                    // front of the Settings they cannot reach.
                    case .settings: SettingsView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                // Items 23+26: rebuild ONLY the detail pane when a theme change
                // commits so GruxTheme computed-color call-sites repaint. Keyed
                // here (not on the whole HStack) so the sidebar's
                // List(selection:) and the @State selection survive: keying the
                // root subtree forced a full rebuild that re-fired onAppear and
                // reset the active tab to chat on every appearance commit.
                .id(theme.revision)

                // Live swarm + Foundry activity strip pinned under the
                // content area. Collapses to zero height when idle. Dot or
                // background click jumps to Agents; the Foundry chip jumps
                // to Self-Upgrade.
                ActivityStripView { kind in
                    selection = (kind == .foundry) ? .selfUpgrade : .agents
                }
            }
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
        }
        .onChange(of: state.requestedTab) { _, new in
            applyTab(new)
        }
        .onChange(of: selection) { _, new in
            // Feed the palette's recent-tabs section. Fires for sidebar
            // clicks AND programmatic applyTab jumps (both mutate selection).
            sidebarStore.recordRecent(Self.tabKey(for: new))
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
                // Four blueprint groups (Command, Workspace, Intelligence,
                // Ambient) plus System for the remaining tabs. Collapse
                // state persists via SidebarStateStore.
                ForEach(SidebarIA.groups) { group in
                    Section(isExpanded: expansionBinding(group.id)) {
                        ForEach(group.items, id: \.key) { item in
                            sidebarRow(item)
                        }
                    } header: {
                        sidebarGroupHeader(group.title)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            statusBar
        }
        .background(Color.black.opacity(0.25))
    }

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
                    // BETA sits before the needs-setup dot on purpose. They are
                    // different claims and both can be true at once: labs says
                    // "this is experimental", the dot says "this one is waiting
                    // on you". Reading label, then maturity, then status keeps
                    // the row parseable when a feature carries both.
                    if FeatureRegistry.isLabs(forTab: item.key) {
                        BetaBadge()
                    }
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
                .badge(item.key == "mailbox" ? mailStore.unreadCount() : 0)
                .tag(tab)
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
            .font(.caption2.weight(.heavy))
            .kerning(1.2)
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
                MicController.toggle()
            } label: {
                OrbView(state: orbState, level: speech.outputLevel)
                    .frame(width: 68, height: 68)
            }
            .buttonStyle(.plain)
            .gruxHoverable(lift: 1.06, rimOnHover: 0, fillOnHover: 0)
            .help(state.micMuted ? "Mic muted, tap to resume" : "Tap to mute the mic")
            .padding(.top, 10)

            Text("GRUX OS")
                .font(.headline.weight(.heavy))
                .kerning(3)
            OrbStatusPill(state: orbState)
                .help(shellBus.current.detail.isEmpty
                    ? shellBus.current.headline
                    : "\(shellBus.current.headline): \(shellBus.current.detail)")
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
        case "commands": return .commands
        case "workflows": return .workflows
        case "metaAds": return .metaAds
        case "social": return .social
        case "focus": return .focus
        case "terminalFocus": return .terminalFocus
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
        case .terminalFocus: return "terminalFocus"
        case .selfUpgrade: return "selfUpgrade"
        case .integrations: return "integrations"
        }
    }

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack(spacing: 6) {
                Circle()
                    .fill(state.watching ? Color.green : Color.secondary)
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
            let waiting = FeatureRegistry.featuresNeedingSetup.count
            if waiting > 0 {
                Button {
                    state.requestedSettingsTab = "capabilities"
                    state.requestedTab = "settings"
                } label: {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(GruxTheme.accentPrimary)
                            .frame(width: 5, height: 5)
                        Text(waiting == 1
                             ? "1 feature needs setup"
                             : "\(waiting) features need setup")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.borderless)
                .help("Open the capabilities list in Settings")
            }
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

            HStack(spacing: 8) {
                TextField("New task…", text: $newTaskText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submit)
                TextField("Project", text: $newTaskProject)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                Picker("", selection: $newTaskPriority) {
                    ForEach(TaskPriority.allCases) { p in Text(p.label).tag(p) }
                }.frame(width: 100)
                Button("Add", action: submit)
                    .keyboardShortcut(.return, modifiers: .command)
            }.padding(.horizontal)

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
