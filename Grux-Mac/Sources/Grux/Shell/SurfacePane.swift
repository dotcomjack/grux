import SwiftUI

/// The surface a tab key names, rendered. One switch, hosted by both shells:
/// the Command Panel opens it as the pane beside the panel, and the legacy
/// sidebar shell fills its detail column with it. Every `case` here is a
/// locked `--open-tab` key, and `RenderedTab.note` reports which one drew.
struct SurfacePane: View {
    @Binding var selection: LaunchRootView.Tab
    // Items 23+26: repaint GruxTheme call-sites when the accent palette or
    // appearance commits (revision bumps only on committed changes).
    @ObservedObject private var theme = ThemeConfig.shared

    init(selection: Binding<LaunchRootView.Tab>) {
        _selection = selection
    }

    var body: some View {
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
                // Skills is a picker in the Chat composer now, and its
                // key opens Chat with Skills open. One clause, so moving
                // between the two never rebuilds the conversation.
                case .chat, .skills: ChatView(opensSkills: selection == .skills).capabilityGated("chat")
                case .jaxHQ: JaxHQView().capabilityGated("jaxHQ")
                case .jaxCommand: JaxCommandView().capabilityGated("jaxCommand")
                case .cognitionMap: CognitionMapView().capabilityGated("cognitionMap")
                case .featureReview: FeatureReviewView().capabilityGated("featureReview")
                // Phase C fold: Projects lives inside Tasks, behind the
                // switch at the top, and the projects key opens it there.
                case .tasks, .projects:
                    HostedSurfaces(LaunchRootView.tasksSurfaces, selection: $selection) { shown in
                        if shown == .projects {
                            ProjectsView().capabilityGated("projects")
                        } else {
                            TasksDetailView().capabilityGated("tasks")
                        }
                    }
                case .agents: AgentsView().capabilityGated("agents")
                // Speakers lives inside Meetings, behind the switch at the top.
                case .meetings, .speakers:
                    HostedSurfaces(LaunchRootView.meetingsSurfaces, selection: $selection) { shown in
                        if shown == .speakers {
                            SpeakersView().capabilityGated("speakers")
                        } else {
                            MeetingsView().capabilityGated("meetings")
                        }
                    }
                case .calendar: CalendarView().capabilityGated("calendar")
                case .documents: DocumentLibraryView().capabilityGated("documents")
                // The Studio row hosts Design Studio, Media Studio and
                // Research, behind the switch at the top. Each key still
                // opens its own surface, there.
                case .designStudio, .creative, .research:
                    HostedSurfaces(LaunchRootView.studioSurfaces, selection: $selection) { shown in
                        switch shown {
                        case .creative: CreativeStudioView().capabilityGated("creative")
                        case .research: ResearchView().capabilityGated("research")
                        default: DesignStudioView().capabilityGated("designStudio")
                        }
                    }
                case .compare: CompareView().capabilityGated("compare")
                case .cookbook: CookbookView().capabilityGated("cookbook")
                case .folders: FoldersManagementView().capabilityGated("folders")
                case .notes: NotesView().capabilityGated("notes")
                // Workflows lives inside Schedules, behind the switch at the top.
                case .schedules, .workflows:
                    HostedSurfaces(LaunchRootView.schedulesSurfaces, selection: $selection) { shown in
                        if shown == .workflows {
                            CommandsV2View().capabilityGated("workflows")
                        } else {
                            UserCronEditorView().capabilityGated("schedules")
                        }
                    }
                case .contacts: ContactsView().capabilityGated("contacts")
                case .mailbox: MailboxView().capabilityGated("mailbox")
                case .roadmap: RoadmapView()
                case .commands: CommandsView().capabilityGated("commands")
                case .metaAds: MetaAdsView().capabilityGated("metaAds")
                case .social: SocialView().capabilityGated("social")
                case .focus: FocusLogView().capabilityGated("focus")
                case .selfUpgrade: SelfUpgradeView().capabilityGated("selfUpgrade")
                case .integrations: IntegrationsView().capabilityGated("integrations")
                // Tuning: no rail row; the orb, Today, the palette and Settings open it.
                case .tuning: TuningView()
                // The Labs door's page: eight cards, the accepted shape A.
                case .labs:
                    LabsShelfView { key in
                        if let key, let tab = LaunchRootView.tab(forKey: key) { selection = tab }
                        else { AppDelegate.shared?.openPhonePairingWindow() }
                    }
                // NEVER gated, and this one is a hard rule rather than a
                // preference. Settings is where every capability is fixed,
                // so gating it on a capability would be a deadlock: the card
                // would tell somebody to go to Settings while standing in
                // front of the Settings they cannot reach.
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // What actually rendered, for scripts that must not trust the
            // ack: `fire-open-tab` acks when the tab is REQUESTED, before
            // SwiftUI repaints (trap 1 in tools/grux-sweep.sh). A task keyed
            // on the selection runs after the pane has updated for it.
            .task(id: selection) {
                await Task.yield()
                RenderedTab.note(LaunchRootView.tabKey(for: selection))
            }
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
}
