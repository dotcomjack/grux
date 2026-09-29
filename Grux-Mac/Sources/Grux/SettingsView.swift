import SwiftUI

// Settings consolidation (blueprint section 02, proposal 5): the old 12-tab
// bar is now 5 panes: General, Voice & Ambient, Models, Appearance,
// Data & Security. Every control from the old tabs survives; sections moved,
// they were not rebuilt. A search field at the top filters visible sections
// and jumps panes via SettingsSearchRegistry. The --open-settings-tab seam
// keeps working through SettingsTabAliases (old tags resolve to the new
// pane + sub-pane + scroll anchor).
struct SettingsView: View {
    @EnvironmentObject var state: AppState
    // The Workday Log's two switches. @AppStorage rather than @State because the keys ARE
    // the storage: WorkdayLogStore reads the same two strings, so there is no copy to keep
    // in sync and no save step to forget. Defaults match WorkdayLogStore exactly.
    @AppStorage(WorkdayLogStore.enabledKey) private var workdayLogEnabled: Bool = true
    @AppStorage(WorkdayLogStore.iCloudMirrorKey) private var workdayLogMirrorsToICloud: Bool = false

    @State private var apiKey: String = ""
    @State private var model: String = ""
    @State private var interval: Double = 30
    @State private var drift: Double = 2
    @State private var auto: Bool = true
    @State private var notify: Bool = true
    @State private var screen: Bool = true
    @State private var wakeWord: Bool = true
    @State private var autoSendWake: Bool = true
    @State private var useEleven: Bool = true
    @State private var elevenKey: String = ""
    @State private var elevenVoiceId: String = ""
    @State private var elevenModelId: String = ""
    @State private var showElevenKey: Bool = false
    @State private var voices: [ElevenLabsVoice] = []
    @State private var loadingVoices = false
    @State private var showKey: Bool = false
    @State private var savedAt: Date?

    // Web + Brave key (formerly the Upgrades tab, now in Data & Security).
    // The tier and the memory switch moved to Tuning in P-E-2, and so did
    // active hours, snooze, speak aloud and voice speed: no @State mirror of
    // any of them may come back here, because save() writes every mirror it
    // holds, and a mirror loaded before Tuning changed the value would put
    // the old one back.
    @State private var webResearchEnabled: Bool = true
    @State private var premiumNoiseCancellation: Bool = true
    @State private var braveKey: String = ""
    @State private var showBraveKey: Bool = false
    @State private var replicateKey: String = ""
    @State private var showReplicateKey: Bool = false
    @State private var musicStrategy: MusicStrategy = .libraryFirst
    @State private var developerTeamId: String = ""
    @State private var developerBundlePrefix: String = "com.example"
    @State private var memoryCounts: [SemanticMemoryKind: Int] = [:]
    @ObservedObject private var semanticMemory = SemanticMemory.shared
    @ObservedObject private var wake = WakeWordListener.shared
    @ObservedObject private var speech = SpeechEngine.shared
    @ObservedObject private var ambient = AmbientState.shared

    // Bumped by toggles in the Microphones section so SwiftUI re-evaluates
    // the computed `micsSection` (which reads non-@Published UserDefaults).
    @State private var micsRefreshTick: Int = 0

    // Last status string for the local-LLM Ping button in the Ambient sub-pane.
    @State private var localLLMStatus: String? = nil

    // Offline mode (Phase 1, Model Foundation) mirrors. offlineMode itself is
    // transient on AppState (not persisted); the model + base URL persist in
    // config.json. Discovery state is read live from ModelRegistry.
    @State private var offlineMode: Bool = false
    /// What the last "Hand setup to your agent" press wrote, in the legacy
    /// shell only (the panel shell opens the hub instead).
    @State private var handoffNote: String? = nil
    @State private var offlineLLMModel: String = "llama3.1"
    @State private var ollamaBaseURL: String = "http://localhost:11434"
    @ObservedObject private var modelRegistry = ModelRegistry.shared

    // Settings pane automation hook: tag-driven selection so the
    // --open-settings-tab=<name> launch arg (and anything else that sets
    // AppState.requestedSettingsTab) can land on a specific pane. Old tag
    // names resolve through SettingsTabAliases. Defaults to "general",
    // which is the first pane, so normal opens are unchanged.
    @State private var selectedTab: String = SettingsPane.general.rawValue

    // Sub-pane selections for the consolidated panes.
    @State private var voiceAmbientSub: String = "voice"
    @State private var modelsSub: String = "models"
    @State private var dataSecuritySub: String = "backup"

    // Scroll target consumed by the pane ScrollViewReaders.
    @State private var pendingAnchor: String? = nil

    // Search filter (per-pane keyword registry in SettingsSearchRegistry).
    @State private var searchQuery: String = ""

    // Re-running the first-run flow is confirmed, not one-click. OnboardingModel
    // .reset() lands the user back on the model key gate the instant it is
    // called, and that gate replaces the whole shell, Settings included, until
    // the flow is finished. It offers "Keep the key I have" to anyone who
    // already has one, so this is no longer a lock, but it is still a whole
    // window changing under someone who may have only been reading labels.
    @State private var confirmingOnboardingReset = false

    /// State files that existed, held bytes, and did not decode on this launch.
    ///
    /// Mirrored because `Persistence.decodeFailures` is a plain static behind an
    /// NSLock and SwiftUI is not watching it. Seeded in `loadFromState()` and
    /// re-read after each acknowledgement, which is every moment it can change:
    /// the decode itself happened at launch, long before this pane existed.
    @State private var decodeFailures: [Persistence.DecodeFailure] = []

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            if !searchResultEntries.isEmpty {
                searchResults
            } else if searchIsFiltering {
                noSearchMatches
            }
            // A segmented Picker, NOT a TabView, and the difference is the
            // whole reason this was rewritten.
            //
            // macOS paints a TabView's tab bar with the SYSTEM accent and does
            // not honour SwiftUI's `.tint`. LaunchRootView already sets
            // `.tint(GruxTheme.accentPrimary)` at line 198, which is why every
            // sub-pane picker in this file renders purple, while this one alone
            // came out system blue. On Data and Security the two sat stacked in
            // one screenshot, blue above purple.
            //
            // REFUTED beforehand, so it is not worth retrying: adding another
            // `.tint` at the SettingsView root does nothing, measured twice on
            // rebuilt binaries. The tab bar is not a tintable control. A Picker
            // is, and it is the same control the sub-panes already use, so this
            // removes a second mechanism rather than adding one.
            // ViewThatFits, because the segmented form does not fit at every
            // window size and this was a regression I introduced.
            //
            // Replacing the native TabView fixed the system-blue accent, since a
            // macOS tab bar is painted with the system accent and ignores .tint.
            // But a tab bar can compress, and a segmented Picker with five long
            // labels cannot: "General | Voice & Ambient | Models | Appearance |
            // Data & Security" demands more than the 599pt detail pane at the
            // 840pt floor, so it pushed the whole Form wider and cut its own last
            // segment plus the text of every section below it. Measured: the
            // dominant band of right-edge overflow sat at y 92 to 115pt, which is
            // this row, not any section.
            //
            // A menu picker still wears the tint, so the fix keeps the accent
            // that motivated the original change.
            ViewThatFits(in: .horizontal) {
                panePicker.pickerStyle(.segmented)
                panePicker.pickerStyle(.menu).frame(maxWidth: GruxLayout.settingsMenuPickerMax)
            }
            .labelsHidden()
            .padding(.horizontal, GruxSpacing.l)
            .padding(.top, GruxSpacing.s)

            Group {
                switch SettingsPane(rawValue: selectedTab) ?? .general {
                case .general:      generalPane
                case .voiceAmbient: voiceAmbientPane
                case .models:       modelsPane
                case .appearance:   appearancePane
                case .dataSecurity: dataSecurityPane
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Flexible, NOT fixed. This view has two call sites with opposite needs:
        // the macOS Settings scene (GruxApp.swift), where an ideal size is what
        // sizes the standalone window, and the `settings` tab inside the main
        // window (LaunchRootView.swift), where it must fill whatever the detail
        // pane gives it. A hard `.frame(width: 680, height: 620)` served the
        // first and broke the second: the main window's floor is 840 wide minus
        // a 240 sidebar, so the detail pane can be 600, and a 680 demand
        // overflowed by 80pt and clipped the content off BOTH edges (SwiftUI
        // centres an oversized child). Same story vertically at the 560 floor.
        // Cap the CONTENT column, then let the view itself still fill whatever
        // the pane gives it. The frame below is a floor guard, against the
        // detail pane starving this view at the 840pt window. This one is the
        // opposite guard and was missing: at a 2400pt window every row stretched
        // to the full width, so "Start: 5 AM" sat at the far left with its
        // slider running about 1700pt away, and the first-run paragraph became a
        // single line roughly 1700pt wide. Inert below 1200, so narrow layout
        // and the standalone Settings window (680 ideal) are both unchanged.
        // CENTRED, not leading, and that is a global decision rather than a
        // per-tab taste call. Left-aligning a 1200pt column inside a 2400pt pane
        // strands roughly 960pt of dead space on one side and reads as a broken
        // layout; centring the same column reads as deliberate. Every capped tab
        // centres, so they agree with each other at every window size.
        // CLAMPED to the real pane width, not merely offered it.
        //
        // `.frame(maxWidth:)` PROPOSES a width, it does not enforce one: a child
        // that demands more still draws wider and SwiftUI centres the overflow,
        // which is why content bled off both edges. Reading the actual available
        // width and proposing it EXACTLY makes every child that respects a
        // proposal compress instead.
        //
        // Bisected rather than guessed. Removing the whole credentials section
        // moved right-edge overflow from 238px to 202px, so no single section
        // was the cause; 144 of the remainder was the pane picker row itself.
        // Three narrower hypotheses were refuted by measurement first: the
        // credential rows, the Brave and fal.ai labelled rows, and the picker
        // alone.
        // THE CONSENT ALERT USED TO LIVE HERE, AND THAT WAS THE BUG.
        //
        // Ambient can also be switched on from the menu bar row and from the
        // ambient HUD's capture pill, neither of which is inside this view, so
        // two of the three doors took the microphone with no disclosure. The
        // gate now sits inside `AmbientState.enable()` and
        // `WakeWordListener.enable()`, which every door goes through, and it is
        // an NSAlert precisely because those doors have no view to attach a
        // SwiftUI alert to. Turning either feature OFF is never gated.
        .modifier(ClampToAvailableWidth())
        .frame(maxWidth: GruxLayout.contentMax, alignment: .top)
        // The floor is the Command Panel pane's floor, not the classic
        // sidebar's: at 520 this overflowed a 360pt pane by 160pt and SwiftUI
        // centred it, so the search field drew over the panel column and the
        // toggles ran off the window edge (measured at an 820pt window).
        .frame(minWidth: GruxLayout.detailContentMin, idealWidth: GruxLayout.paneWidth, maxWidth: .infinity,
               minHeight: 400, idealHeight: 620, maxHeight: .infinity,
               alignment: .top)
        .onAppear {
            loadFromState()
            applyRequestedSettingsTab()
        }
        .onChange(of: state.requestedSettingsTab) { _, _ in
            applyRequestedSettingsTab()
        }
    }

    // MARK: - Deep links (legacy-tag compatible)

    // Consumes AppState.requestedSettingsTab: resolves old or new tag names
    // through the alias map, switches the pane (+ sub-pane + scroll anchor),
    // and clears the request so it never re-fires on a later Settings open.
    private func applyRequestedSettingsTab() {
        guard let tab = state.requestedSettingsTab, !tab.isEmpty else { return }
        navigate(to: SettingsTabAliases.resolve(tab))
        state.requestedSettingsTab = nil
    }

    private func navigate(to loc: SettingsLocation) {
        selectedTab = loc.pane.rawValue
        if let sub = loc.sub {
            switch loc.pane {
            case .voiceAmbient: voiceAmbientSub = sub
            case .models: modelsSub = sub
            case .dataSecurity: dataSecuritySub = sub
            default: break
            }
        }
        pendingAnchor = loc.anchor
    }

    /// When a deep link's scroll is attempted, in seconds.
    ///
    /// MORE THAN ONCE, and that is the fix. One attempt at 80ms assumes the
    /// destination pane has finished building its rows by then. A long pane
    /// (Data and Capabilities is the longest in the app) has not, so
    /// `scrollTo` addressed an id that did not exist yet, did nothing, and the
    /// single attempt then cleared the request: the reader landed at the top
    /// of the right pane with no sign that anything was meant to be there.
    /// Reported against `settings:memory` and `settings:brands`.
    ///
    /// The later attempts are free when the first one worked, because
    /// scrolling to where you already are moves nothing.
    static let anchorScrollAttempts: [TimeInterval] = [0.08, 0.35, 0.8]

    private func scrollToPendingAnchor(_ proxy: ScrollViewProxy) {
        guard let anchor = pendingAnchor else { return }
        for (i, delay) in Self.anchorScrollAttempts.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo(anchor, anchor: .top)
                }
                // Cleared only after the last attempt, so a pane that mounts
                // late still has a request to honour.
                if i == Self.anchorScrollAttempts.count - 1 { pendingAnchor = nil }
            }
        }
    }

    // MARK: - Search

    private var trimmedQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var searchResultEntries: [SettingsSearchEntry] {
        SettingsSearchRegistry.matches(trimmedQuery)
    }

    /// Whether the field is actually filtering anything.
    ///
    /// Two characters, because that is the same floor
    /// `SettingsSearchRegistry.matches` and `sectionVisible` both apply. Reading
    /// `!trimmedQuery.isEmpty` here instead would claim a one-character query
    /// filtered the panes when it does not, and print a no-matches line over a
    /// screen that is showing everything.
    private var searchIsFiltering: Bool { trimmedQuery.count >= 2 }

    /// What a query that matches nothing has to say, static so it can be
    /// asserted on without standing up the view.
    ///
    /// THE BLANK PANE THIS REPLACES. `sectionVisible` hides every registered
    /// section while a query is active, and the results list above renders
    /// nothing when there are no matches, so any query of two or more characters
    /// the keyword registry does not know emptied the whole surface: a search
    /// field, a pane picker, and then nothing at all. Every section in General
    /// sits behind that check, so the pane Settings opens on went completely
    /// blank. Typing a word this app has never heard of is not a fault, and a
    /// screen with nothing on it is the one reading that says it is.
    static func noMatchesCopy(query: String) -> String {
        // Names the sections that stay put, because SettingsSearchRegistry
        // .sectionVisible fails OPEN: any anchor with no registry entry keeps
        // rendering. So this line could sit directly above visible settings
        // asserting that nothing matched, which reads as a broken search.
        "No settings match \"\(query)\". Anything still listed below has no search "
            + "keywords yet. Clear the search to see every section again."
    }

    private var noSearchMatches: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(Self.noMatchesCopy(query: trimmedQuery))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Clear") { searchQuery = "" }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(GruxTheme.accentPrimary)
        }
        .padding(.horizontal, GruxSpacing.l)
        .padding(.bottom, GruxSpacing.s)
    }

    /// The pane chooser's content, shared by both fitted forms above.
    ///
    private var panePicker: some View {
        Picker("", selection: $selectedTab) {
            ForEach(SettingsPane.allCases, id: \.rawValue) { pane in
                Text(pane.label).tag(pane.rawValue)
            }
        }
    }

    /// One sentence describing what the handoff prompt currently contains.
    ///
    /// Reads live capability state, so on a fully configured Mac it says so
    /// rather than offering to hand over an empty list.
    private var handoffSummary: String {
        let split = AgentHandoff.outstanding()
        if split.agent.isEmpty && split.human.isEmpty {
            return "Everything Grux asks for is already set up on this Mac, so the prompt just says so."
        }
        if split.agent.isEmpty {
            return "Nothing left that an agent can do. \(split.human.count) item\(split.human.count == 1 ? "" : "s") still need you, and the prompt lists them."
        }
        let mine = split.human.isEmpty ? "" : ", and the \(split.human.count) that need you"
        return "Right now it lists \(split.agent.count) thing\(split.agent.count == 1 ? "" : "s") your agent can do\(mine)."
    }

    private func sectionVisible(_ anchor: String) -> Bool {
        SettingsSearchRegistry.sectionVisible(anchor: anchor, query: trimmedQuery)
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField("Search settings", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.18), lineWidth: 1))
        )
        .padding(.horizontal, GruxSpacing.l)
        .padding(.top, GruxSpacing.m)
        .padding(.bottom, GruxSpacing.s)
    }

    private var searchResults: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(searchResultEntries.prefix(8)) { entry in
                Button {
                    navigate(to: entry.location)
                    searchQuery = ""
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: entry.location.pane.systemImage)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                        Text(entry.location.pane.label)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(entry.title)
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if searchResultEntries.count > 8 {
                Text("\(searchResultEntries.count - 8) more match below; matching sections stay visible, others hide")
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
            }
        }
        .padding(GruxSpacing.xs + 2)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.05))
        )
        .padding(.horizontal, GruxSpacing.l)
        .padding(.bottom, GruxSpacing.s)
    }

    // MARK: - Pane 1: General (old General + About)

    private var generalPane: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Form {
                    if sectionVisible("general.tuning") {
                        Section(TuningCopy.title) {
                            TuningPointer(text: TuningCopy.settingsLink)
                        }
                        .id("general.tuning")
                    }
                    if sectionVisible("general.screen") {
                        Section("Screen awareness") {
                            Toggle("Enable screen analysis", isOn: $screen)
                            Toggle("Send reminder notifications", isOn: $notify)
                            Toggle("Auto-promote detected task to NOW", isOn: $auto)
                            HStack { Text("Permission:")
                                if state.screenPermissionGranted {
                                    Label("Granted", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                                } else {
                                    Button("Request screen recording…") { _ = ScreenCapturer.shared.requestPermission() }
                                }
                            }
                        }
                        .id("general.screen")
                    }
                    if sectionVisible("general.notifications") {
                        TriageMatrixSection()
                            .id("general.notifications")
                    }
                    if sectionVisible("general.hours") {
                        Section("Active hours") {
                            TuningPointer()
                        }
                        .id("general.hours")
                    }
                    // The only door back into the first-run flow. Without it
                    // OnboardingModel.reset() had no caller anywhere outside
                    // Onboarding/, so the one-time flow was exactly the trap
                    // its own doc comment describes: click through once and it
                    // is gone for good, including the privacy proof on gate 3
                    // that is the one screen worth re-reading. Same shape as
                    // "Recording consent" above, for the same reason.
                    if sectionVisible("general.identity") {
                        Section("Names") {
                            // Neither of these had a control anywhere. The user's
                            // name was set once during onboarding and then
                            // unreachable, and the assistant's name was a config
                            // key nothing read. Both are here now, because a
                            // setting you cannot find is not a setting.
                            TextField("What Grux calls you", text: Binding(
                                get: { state.config.userName },
                                set: { v in
                                    state.config.userName = v
                                    state.saveConfig()
                                }
                            ))
                            Text("Used in your briefing and when the assistant addresses you. Leave it empty and it simply will not use a name. It stays on this Mac.")
                                .font(.caption).foregroundStyle(.secondary)

                            TextField("What you call the assistant", text: Binding(
                                get: { state.config.assistantName },
                                set: { v in
                                    state.config.assistantName = v
                                    state.saveConfig()
                                }
                            ))
                            Text("Defaults to Jax, which is the assistant. The app itself is Grux, and renaming the assistant does not rename the app or its tabs. Takes effect on the next message.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .id("general.identity")
                    }
                    if sectionVisible("general.doors") {
                        Section("Sidebar doors") {
                            // The Developer door had no switch anywhere: the
                            // config key was read by the rail and written by
                            // nothing, so a new install could never show the
                            // five surfaces behind it. This is its permanent
                            // home; first run opens it for somebody who says
                            // they write code (`IntentToFeatures.apply`).
                            Toggle(DoorsCopy.developer.title, isOn: Binding(
                                get: { state.config.developerSurfacesUnlocked },
                                set: { v in
                                    state.config.developerSurfacesUnlocked = v
                                    state.saveConfig()
                                }
                            ))
                            Text(DoorsCopy.developer.body)
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .id("general.doors")
                    }
                    if sectionVisible("general.shell") {
                        Section("Shell") {
                            // The pre-3.0 frame, kept for one release. The
                            // shell root reads legacyShell live, so the
                            // switch rebuilds the window on the spot.
                            Toggle("Classic sidebar", isOn: Binding(
                                get: { state.config.legacyShell },
                                set: { v in
                                    state.config.legacyShell = v
                                    state.saveConfig()
                                }
                            ))
                            Text("The 240pt sidebar from before 3.0, in place of the Command Panel. Switches right away. Goes away in the release after this one.")
                                .font(GruxType.caption).foregroundStyle(GruxTheme.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                            // Only the Command Panel floats (`LaunchWindowSizer.level`), so
                            // the classic shell shows the row switched off with the reason.
                            Toggle("Keep Grux on top", isOn: Binding(
                                get: { state.config.keepOnTop && KeepOnTopRow.isEnabled(legacyShell: state.config.legacyShell) },
                                set: { v in
                                    state.config.keepOnTop = v
                                    state.saveConfig()
                                }
                            ))
                            .disabled(!KeepOnTopRow.isEnabled(legacyShell: state.config.legacyShell))
                            Text(KeepOnTopRow.caption(legacyShell: state.config.legacyShell))
                                .font(GruxType.caption).foregroundStyle(GruxTheme.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .id("general.shell")
                    }
                    if sectionVisible("general.handoff") {
                        Section("Hand setup to your agent") {
                            // Setup is nine credentials, eight permissions and a
                            // few installs. A good part of it is mechanical, and
                            // everybody running Grux already has an agent that
                            // does mechanical work. So rather than walking them
                            // through it, give them one paragraph to paste.
                            Text("Grux can write a prompt describing exactly what this Mac still needs. Paste it into your coding agent and it will do the parts it can.")
                                .font(.caption).foregroundStyle(.secondary)

                            Button("Hand setup to your agent") {
                                handoffNote = SettingsHandoff.run(legacyShell: state.config.legacyShell)
                            }
                            if let handoffNote {
                                Text(handoffNote)
                                    .font(GruxType.caption).foregroundStyle(GruxTheme.textSecondary)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else if !state.config.legacyShell {
                                Text("Now under Optimize Grux, as the Hand it over door.")
                                    .font(GruxType.caption).foregroundStyle(GruxTheme.textTertiary)
                            }

                            // Live counts rather than a vague promise. It reads
                            // the same capability state the sidebar does, so it
                            // cannot claim work that is already done.
                            Text(handoffSummary)
                                .font(.caption).foregroundStyle(.secondary)

                            Text("It never asks your agent for a credential or a permission, because it cannot get either, and it explicitly tells it not to answer the consent questions for you. Grux records setup steps as checkboxes rather than detecting them, so when your agent is done you tick off what it installed.")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        .id("general.handoff")
                    }
                    if sectionVisible("general.permissions") {
                        PermissionsSection()
                    }
                    if sectionVisible("general.about") {
                        Section("About") {
                            Text("Grux OS").font(GruxType.title).foregroundStyle(GruxTheme.textPrimary)
                            Text("Focus assistant for solo founders who juggle too many things.").foregroundStyle(.secondary)
                            Text("Support dir: \(Persistence.supportDir.path)")
                                .font(.caption).textSelection(.enabled)
                            Text("Events stored: \(state.events.count) • Tasks: \(state.tasks.count)")
                                .font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("Reveal support dir") { NSWorkspace.shared.open(Persistence.supportDir) }
                                // Was labelled "Reset onboarding" and never
                                // touched OnboardingModel: it puts every config
                                // value back to its default. Renamed rather than
                                // rewired, because the button people wanted
                                // under that name now exists above it and two
                                // controls sharing one name is worse than the
                                // gap it was standing in for.
                                DestructiveButton(
                                    "Reset all settings",
                                    question: "Reset every setting to its default?",
                                    detail: "Your model key, your name, notification routing, "
                                        + "voice, appearance and capture exclusions all go back "
                                        + "to how Grux shipped. Your chats, notes, documents and "
                                        + "memory are not touched. This cannot be undone.",
                                    confirmLabel: "Reset everything"
                                ) { state.config = .default; state.saveConfig() }
                            }
                        }
                        .id("general.about")
                    }
                    if sectionVisible("general.firstRun") {
                        Section("Restart onboarding") {
                            HStack {
                                Text("Connect a model, set what Grux calls you, and on the two longer paths see one real captured frame.")
                                Spacer()
                                Button("Restart onboarding") { confirmingOnboardingReset = true }
                            }
                            Text("The frame comes with the exact redacted text Grux would send, and it is the step that lets Grux start watching your screen at all. The one minute path skips it, so choose one of the longer two if that is what you came back for. Grux goes back to the tier picker right away and stays there until the flow is finished. The model key gate offers \"Keep the key I have\", so your saved key gets you straight past it. Nothing already saved is deleted.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .id("general.firstRun")
                    }
                    saveBar
                }
                .modifier(SettingsFormChrome())
            }
            .onAppear { scrollToPendingAnchor(proxy) }
            .onChange(of: pendingAnchor) { _, _ in scrollToPendingAnchor(proxy) }
            // Attached to the pane, not to the row, so it survives the section
            // being filtered out from under it while the search field is live.
            .confirmationDialog(
                "Restart onboarding?",
                isPresented: $confirmingOnboardingReset,
                titleVisibility: .visible
            ) {
                Button("Restart onboarding", role: .destructive) { OnboardingModel.shared.reset() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The main window switches to the first-run screens immediately. The first gate asks for a model key, and offers \"Keep the key I have\" so the one you already saved gets you past it. Your saved key, name and settings are left alone unless you change them on the way through.")
            }
        }
    }

    private var voiceAmbientSubPicker: some View {
        Picker("", selection: $voiceAmbientSub) {
            Text("Voice").tag("voice")
            Text("Ambient").tag("ambient")
            Text("Focus").tag("focus")
            // The session engine spawns sessions and spends a credential, so it
            // gets its own home.
            Text("Sessions").tag("sessions")
        }
    }

    // MARK: - Pane 2: Voice & Ambient (old Voice + Ambient + Focus)

    private var voiceAmbientPane: some View {
        VStack(spacing: 0) {
            // Segmented where the segments fit, a menu where they do not: at
            // the pane's 360pt floor the segmented row ran past both edges.
            ViewThatFits(in: .horizontal) {
                voiceAmbientSubPicker.pickerStyle(.segmented)
                voiceAmbientSubPicker.pickerStyle(.menu).frame(maxWidth: GruxLayout.settingsMenuPickerMax)
            }
            .labelsHidden()
            .padding(.horizontal, GruxSpacing.l)
            .padding(.top, GruxSpacing.m)
            Group {
                switch voiceAmbientSub {
                case "ambient": ambientSub
                case "focus": focusSub
                case "sessions": sessionsSub
                default: voiceSub
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var voiceSub: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Form {
                    if sectionVisible("voice.mics") {
                        micsSection
                            .id("voice.mics")
                    }

                    if sectionVisible("voice.engine") {
                        VoiceEnginePickerView()
                            .id("voice.engine")
                    }

                    if sectionVisible("voice.wake") {
                        ListeningSection()
                            .id("voice.wake")
                    }

                    if sectionVisible("voice.replies") {
                        Section("Spoken replies") {
                            TuningPointer(text: TuningCopy.spokenPointer)
                            Toggle("Use ElevenLabs voice (Jarvis-grade)", isOn: $useEleven)
                                .onChange(of: useEleven) { _, new in
                                    state.config.useElevenLabs = new
                                    state.saveConfig()
                                }
                            Toggle("Read me a briefing at 7 AM and 9 PM", isOn: Binding(
                                get: { state.config.spokenBriefingsEnabled },
                                set: { v in
                                    state.config.spokenBriefingsEnabled = v
                                    state.saveConfig()
                                }
                            ))
                            Text("Off by default. When on, Grux speaks a short summary of what is waiting and how the day went, twice a day. It needs a mail account to have anything to say. With it off the briefing is still written and still there to read, it just does not talk.")
                                .font(.caption).foregroundStyle(.secondary)

                            Toggle("Turn Apple Music down while Grux talks", isOn: Binding(
                                get: { state.config.musicDuckingEnabled },
                                set: { v in
                                    state.config.musicDuckingEnabled = v
                                    state.saveConfig()
                                }
                            ))
                            Text("Off by default, and takes effect on next launch. When on, Grux drops Music to 50% while it speaks and puts it back afterwards. The first time it does, macOS asks whether Grux may control Music, because changing another app's volume is done by sending that app an instruction.")
                                .font(.caption).foregroundStyle(.secondary)
                            Button {
                                SpeechEngine.shared.speak("Grux online. I'm listening, boss. Talk to me.")
                            } label: {
                                Label(speech.isSpeaking ? "Speaking…" : "Test voice",
                                      systemImage: speech.isSpeaking ? "waveform" : "play.circle.fill")
                            }.disabled(useEleven && elevenKey.isEmpty)
                        }
                        .id("voice.replies")
                    }

                    if sectionVisible("voice.eleven") {
                        Section("ElevenLabs") {
                            HStack {
                                if showElevenKey {
                                    TextField("sk_…", text: $elevenKey).textFieldStyle(.roundedBorder)
                                } else {
                                    SecureField("sk_…", text: $elevenKey).textFieldStyle(.roundedBorder)
                                }
                                Button(showElevenKey ? "Hide" : "Show") { showElevenKey.toggle() }
                            }
                            HStack {
                                Picker("Voice", selection: $elevenVoiceId) {
                                    // Featured voices first; always selectable even
                                    // before the API list loads (or if no
                                    // ElevenLabs key has been pasted).
                                    Section(header: Text("Featured")) {
                                        ForEach(FeaturedVoices.all) { v in
                                            Text(v.name).tag(v.voiceId)
                                        }
                                    }
                                    // User's library, merged + deduped.
                                    let featuredIds = Set(FeaturedVoices.all.map { $0.voiceId })
                                    let extra = voices.filter { !featuredIds.contains($0.voiceId) }
                                    if !extra.isEmpty {
                                        Section(header: Text("Your library")) {
                                            ForEach(extra) { v in
                                                Text("\(v.name)\(v.category == "cloned" ? " · cloned" : "")").tag(v.voiceId)
                                            }
                                        }
                                    }
                                }
                                Button {
                                    Task { await refreshVoices() }
                                } label: {
                                    if loadingVoices { ProgressView().controlSize(.small) }
                                    else { Image(systemName: "arrow.clockwise") }
                                }.help("Refresh voice list")
                                Button {
                                    SpeechEngine.shared.speak("Preview voice check. If you can hear me, I sound right.")
                                } label: {
                                    Image(systemName: "play.circle")
                                }.help("Preview selected voice")
                            }
                            if let selected = FeaturedVoices.all.first(where: { $0.voiceId == elevenVoiceId }),
                               let desc = selected.description {
                                Text(desc).font(.caption).foregroundStyle(.secondary)
                            }
                            Picker("Model", selection: $elevenModelId) {
                                Text("Turbo v2.5 (fastest)").tag("eleven_turbo_v2_5")
                                Text("Multilingual v2").tag("eleven_multilingual_v2")
                                Text("Flash v2.5").tag("eleven_flash_v2_5")
                            }
                            Text("Grux ships with one built-in voice. Paste your ElevenLabs key to browse the full catalogue and switch.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .id("voice.eleven")
                    }
                    saveBar
                }
                .modifier(SettingsFormChrome())
            }
            .onAppear { scrollToPendingAnchor(proxy) }
            .onChange(of: pendingAnchor) { _, _ in scrollToPendingAnchor(proxy) }
        }
    }

    private var ambientSub: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Form {
                    if sectionVisible("ambient.passive") {
                        ListeningSection()
                            .id("ambient.passive")
                    }

                    if sectionVisible("ambient.behaviors") {
                        Section("Behaviors") {
                            Toggle("Auto-promote detected actions into task stack", isOn: Binding(
                                get: { state.config.ambientAutoPromoteActions },
                                set: { v in
                                    state.config.ambientAutoPromoteActions = v
                                    state.saveConfig()
                                }
                            ))
                            Toggle("Voice coach: speak nudges when I drift", isOn: Binding(
                                get: { state.config.ambientCoachEnabled },
                                set: { v in
                                    state.config.ambientCoachEnabled = v
                                    state.saveConfig()
                                }
                            ))
                            Toggle("Show floating HUD", isOn: Binding(
                                get: { state.config.ambientHUDVisible },
                                set: { v in
                                    state.config.ambientHUDVisible = v
                                    state.saveConfig()
                                    if v { AmbientPanelController.shared.show() }
                                    else { AmbientPanelController.shared.hide() }
                                    ambient.hudVisible = v
                                }
                            ))
                        }
                        .id("ambient.behaviors")
                    }

                    // The "Orb & overlays" toggles live in the Appearance pane
                    // (items 23+26) so all visual identity controls stay together.

                    if sectionVisible("meeting.consent") {
                        Section("Recording consent") {
                            HStack {
                                Image(systemName: state.config.recordingConsentAcknowledged
                                      ? "checkmark.circle.fill" : "exclamationmark.circle")
                                    .foregroundStyle(state.config.recordingConsentAcknowledged
                                                     ? Color.green : Color.orange)
                                Text(state.config.recordingConsentAcknowledged
                                     ? "You confirmed you will tell people on the call."
                                     : "Grux will ask before the first recording.")
                                Spacer()
                                if state.config.recordingConsentAcknowledged {
                                    Button("Ask me again") { RecordingConsent.reset() }
                                }
                            }
                            Text("Grux records all sides of a call and transcribes it on your Mac. The other people on the call are recorded too and Grux cannot tell them, so it asks you to confirm once that you will. Some places require it.")
                                .font(.caption).foregroundStyle(.secondary)

                            Divider()

                            Toggle("Offer to record when I open a call app", isOn: Binding(
                                get: { state.config.meetingAutoDetectEnabled },
                                set: { v in
                                    state.config.meetingAutoDetectEnabled = v
                                    if v { MeetingAppDetector.shared.start() }
                                    else { MeetingAppDetector.shared.stop() }
                                    state.saveConfig()
                                }
                            ))
                            Text("Off by default. When on, Grux watches which app you bring to the front and shows a floating hint offering to record when it is FaceTime, Zoom, Teams, Meet or Webex. It never starts recording on its own. With it off, Grux does not look at which app is in front for this.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .id("meeting.consent")
                    }

                    if sectionVisible("ambient.nightly") {
                        Section("Nightly passes over the transcript") {
                            Text("Two jobs can read the day's ambient transcript overnight. Both are off, both need ambient listening on to have anything to read, and both send that transcript to a model: the local one when it is running, otherwise the cloud model you configured.")
                                .font(.caption).foregroundStyle(.secondary)

                            Toggle("Keep notes on people I talk about", isOn: Binding(
                                get: { state.config.personMemoryEnabled },
                                set: { v in
                                    state.config.personMemoryEnabled = v
                                    state.saveConfig()
                                }
                            ))
                            Text("Off by default. Around 4 AM, Grux reads the day's transcript and writes a file per person it heard named, holding who they are to you, what they are working on, dated facts and things they said word for word. They live in your home folder under .grux/people. These are notes about other people, so Grux does not keep them unless you say so.")
                                .font(.caption).foregroundStyle(.secondary)

                            Toggle("Extract the decisions I made", isOn: Binding(
                                get: { state.config.decisionLogEnabled },
                                set: { v in
                                    state.config.decisionLogEnabled = v
                                    state.saveConfig()
                                }
                            ))
                            Text("Off by default. Around 3 AM, Grux reads the same transcript for decisions you stated out loud and writes them to .grux/decisions, so it can later answer \"why did I switch to that\" with your own words and the day you said them.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .id("ambient.nightly")
                    }

                    if sectionVisible("ambient.crashsafe") {
                        Section("Crash-safe meeting capture") {
                            Toggle("Keep a rolling audio safety-net on disk", isOn: Binding(
                                get: { state.config.crashSafeAudioEnabled },
                                set: { v in
                                    state.config.crashSafeAudioEnabled = v
                                    state.saveConfig()
                                }
                            ))
                            Text("Writes the last ~90 seconds of mixed meeting audio to ~/Library/Application Support/Grux/audio-wal while a meeting is live. If Grux crashes or is force-quit mid-call, the next launch replays the PCM through Whisper and recovers the utterances you would have lost. Files are auto-deleted on clean finalize, no disk bloat.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .id("ambient.crashsafe")
                    }

                    if sectionVisible("ambient.qwen") {
                        Section("Local Qwen ambient brain") {
                            Toggle("Use local Qwen for ambient summaries", isOn: Binding(
                                get: { state.config.useLocalQwenForAmbient },
                                set: { v in
                                    state.config.useLocalQwenForAmbient = v
                                    state.saveConfig()
                                }
                            ))
                            LabeledContent("Endpoint") {
                                TextField("", text: Binding(
                                    get: { state.config.localLLMEndpoint },
                                    set: { v in state.config.localLLMEndpoint = v; state.saveConfig() }
                                ), prompt: Text("http://localhost:3849/api/llm/local"))
                                .textFieldStyle(.roundedBorder)
                            }
                            LabeledContent("Model") {
                                HStack {
                                    TextField("", text: Binding(
                                        get: { state.config.localLLMModel },
                                        set: { v in state.config.localLLMModel = v; state.saveConfig() }
                                    ), prompt: Text(GruxConfig.defaultLocalModel))
                                    .textFieldStyle(.roundedBorder)
                                    Button("Ping") {
                                        Task { @MainActor in await pingLocalLLM() }
                                    }
                                }
                            }
                            if let status = localLLMStatus {
                                Text(status).font(.caption).foregroundStyle(.secondary)
                            }
                            Text("Routes hourly ambient summaries, workday log outcomes, and folder classification through a local LLM proxy on your own network (Ollama-backed Qwen3). Claude is the fallback when the LAN endpoint is unreachable. Cuts API spend on bulk background jobs while keeping cloud responsiveness for live chat.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .id("ambient.qwen")
                    }

                    // Offline mode, custom model endpoints, and MCP servers
                    // moved to the Models pane.

                    if sectionVisible("ambient.data") {
                        Section("Data") {
                            HStack {
                                Label("\(ambient.recentChunks.count) transcript chunks", systemImage: "text.bubble")
                                    .font(.caption).foregroundStyle(.secondary)
                                Spacer()
                            }
                            HStack {
                                Label("\(ambient.memories.count) memories", systemImage: "brain")
                                    .font(.caption).foregroundStyle(.secondary)
                                Spacer()
                            }
                            HStack {
                                Label("\(ambient.detectedActions.count) detected actions", systemImage: "checklist")
                                    .font(.caption).foregroundStyle(.secondary)
                                Spacer()
                            }
                            HStack {
                                Button("Run extraction now") {
                                    Task { @MainActor in await AmbientMemoryExtractor.shared.runExtraction() }
                                }
                                Button("Speak nudge now") {
                                    Task { @MainActor in await AmbientCoach.shared.nudgeNow() }
                                }
                                Spacer()
                                DestructiveButton(
                                    "Clear all ambient data",
                                    question: "Delete everything ambient mode has captured?",
                                    detail: "Every stored frame, transcript and observation from "
                                        + "ambient sessions is removed from this Mac. Ambient mode "
                                        + "keeps working and starts collecting again. This cannot "
                                        + "be undone.",
                                    confirmLabel: "Delete ambient data"
                                ) { ambient.clearAll() }
                            }
                        }
                        .id("ambient.data")
                    }
                }
                .modifier(SettingsFormChrome())
            }
            .onAppear { scrollToPendingAnchor(proxy) }
            .onChange(of: pendingAnchor) { _, _ in scrollToPendingAnchor(proxy) }
        }
    }

    /// The session engine's pane, wrapped the way every other deep-linkable
    /// pane is: without the reader its two anchors could not be scrolled to
    /// however many times the scroll was tried.
    private var sessionsSub: some View {
        ScrollViewReader { proxy in
            ScrollView {
                TerminalSessionsSettingsView()
            }
            .onAppear { scrollToPendingAnchor(proxy) }
            .onChange(of: pendingAnchor) { _, _ in scrollToPendingAnchor(proxy) }
        }
    }

    private var focusSub: some View {
        Form {
            Section("Cadence") {
                // Read-only, and that is the fix. This was a 15-to-180-second
                // slider that wrote `captureIntervalSeconds`, a field the focus
                // watcher never reads: it schedules on the tier's cadence. So
                // the control moved, the number saved, the label updated, and
                // the capture rate did not change by one second. Dragging it
                // felt like tuning and tuned nothing.
                LabeledContent("Capture cadence") {
                    Text("every \(max(1, state.config.tier.cadenceSeconds))s")
                        .foregroundStyle(.secondary)
                }
                Text("Set by how often Grux looks, in Tuning. Higher tiers look more often.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("Drift threshold: \(Int(drift)) checks")
                    Slider(value: $drift, in: 1...5, step: 1)
                }
                Text("Grux waits for this many consecutive off-task checks before nudging you.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Snooze") {
                TuningPointer()
            }
            saveBar
        }
        .modifier(SettingsFormChrome())
    }

    private var modelsSubPicker: some View {
        Picker("", selection: $modelsSub) {
            Text("Configuration").tag("models")
            Text("Presets").tag("presets")
        }
    }

    // MARK: - Pane 3: Models (old Model & API + tier picker + offline +
    // custom endpoints + MCP servers + Presets)

    private var modelsPane: some View {
        VStack(spacing: 0) {
            // Segmented where the segments fit, a menu where they do not: at
            // the pane's 360pt floor the segmented row ran past both edges.
            ViewThatFits(in: .horizontal) {
                modelsSubPicker.pickerStyle(.segmented)
                modelsSubPicker.pickerStyle(.menu).frame(maxWidth: GruxLayout.settingsMenuPickerMax)
            }
            .labelsHidden()
            .padding(.horizontal, GruxSpacing.l)
            .padding(.top, GruxSpacing.m)
            Group {
                switch modelsSub {
                case "presets": presetsSub
                default: modelsConfigSub
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// What is wrong with the Base URL field AS TYPED, ready to print beside it,
    /// or nil when the field is fine.
    ///
    /// THE FORM REFUSES THE VALUE, which is the half that was missing. The field
    /// used to write `state.config.ollamaBaseURL` and call `saveConfig()` on
    /// every keystroke with no check at all, so "localhost:11434" with no scheme
    /// or a half-typed "htt" was persisted as the chat route, while the custom
    /// endpoint form two sections down has parsed its own URL before saving
    /// since the day it was written. The two forms write the same kind of value
    /// and only one of them looked at it.
    ///
    /// An EMPTY field reports nothing. It is what a fresh field looks like
    /// mid-edit and the prompt already says what belongs there, so complaining
    /// would put a warning on screen for somebody who has done nothing wrong.
    /// It is still refused for saving, so clearing the field cannot silently
    /// remove the route.
    ///
    /// The message names the value still in use on purpose: a refusal that does
    /// not say what is running instead reads as the app having lost the setting.
    private var ollamaBaseURLIssue: String? {
        guard !ollamaBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard let issue = ModelRegistry.baseURLIssue(ollamaBaseURL) else { return nil }
        let saved = state.config.ollamaBaseURL
        return saved.isEmpty
            ? "\(issue) Not saved, so there is no local base URL set."
            : "\(issue) Not saved, so chat still uses \(saved)."
    }

    private var modelsConfigSub: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Form {
                    // What the models did today and what it cost, above where
                    // they are chosen.
                    if sectionVisible("models.usage") {
                        UsageCard()
                            .id("models.usage")
                    }

                    if sectionVisible("models.api") {
                        Section("Anthropic API") {
                            // labelsHidden, because a macOS Form promotes a
                            // field's PLACEHOLDER to a label and renders it in a
                            // leading column outside the content area. That is
                            // what put "sk-ant-..." and "Model ID" to the left of
                            // the pane and widened the whole form past the detail
                            // pane, measured at 912 content pixels pressed into
                            // the right edge at the 1040pt default. The
                            // placeholder still shows inside an empty field,
                            // which is where it is useful.
                            VStack(alignment: .leading, spacing: 4) {
                                Text("API key")
                                    .font(.caption).foregroundStyle(.secondary)
                                HStack {
                                    if showKey {
                                        TextField("sk-ant-...", text: $apiKey)
                                            .textFieldStyle(.roundedBorder).labelsHidden()
                                    } else {
                                        SecureField("sk-ant-...", text: $apiKey)
                                            .textFieldStyle(.roundedBorder).labelsHidden()
                                    }
                                    Button(showKey ? "Hide" : "Show") { showKey.toggle() }
                                }
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Model ID")
                                    .font(.caption).foregroundStyle(.secondary)
                                TextField("claude-haiku-4-5-20251001", text: $model)
                                    .textFieldStyle(.roundedBorder).labelsHidden()
                            }
                            Text("Default: claude-haiku-4-5-20251001. Use sonnet/opus for higher quality (more cost).")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("Test API key") { Task { await testKey() } }
                        }
                        .id("models.api")
                    }

                    if sectionVisible("models.tier") {
                        Section("Intelligence tier") {
                            TuningPointer(text: TuningCopy.tierPointer(state.config.tier))
                        }
                        .id("models.tier")
                    }

                    if sectionVisible("models.offline") {
                        Section("Offline mode (local model)") {
                            Toggle("Route chat to a local model", isOn: Binding(
                                get: { state.offlineMode },
                                set: { v in
                                    state.offlineMode = v   // didSet re-runs discovery + telemetry
                                }
                            ))
                            // The field holds a DRAFT, and only a value that
                            // parses reaches the config. `ollamaBaseURL` was
                            // already declared and already seeded in
                            // `loadFromState()`; it was simply never read,
                            // because the field bound straight through to the
                            // config it was supposed to mirror.
                            LabeledContent("Base URL") {
                                TextField("", text: Binding(
                                    get: { ollamaBaseURL },
                                    set: { v in
                                        ollamaBaseURL = v
                                        guard ModelRegistry.baseURLIssue(v) == nil else { return }
                                        state.config.ollamaBaseURL = v
                                        state.saveConfig()
                                    }
                                ), prompt: Text("http://localhost:11434"))
                                .textFieldStyle(.roundedBorder)
                            }
                            // Resyncs the draft when something ELSE writes the
                            // route, which Use on a custom endpoint does. A
                            // clean keystroke writes the same value it just
                            // read, so this cannot loop; a refused keystroke
                            // never reaches the config, so the bad text and its
                            // message stay on screen where the user left them.
                            .onChange(of: state.config.ollamaBaseURL) { _, v in
                                ollamaBaseURL = v
                            }
                            if let issue = ollamaBaseURLIssue {
                                // INLINE, BESIDE THE FIELD, AND DELIBERATELY NOT
                                // AN ALERT. The value the message is about is a
                                // string the user is in the middle of comparing
                                // against something they copied, and a sheet
                                // covers it at exactly that moment. Same colour
                                // and weight as the custom endpoint form's
                                // `validationMessage`, because it is the same
                                // event reported by the same kind of form.
                                Text(issue)
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            LabeledContent("Model") {
                                HStack {
                                    TextField("", text: Binding(
                                        get: { state.config.offlineLLMModel },
                                        set: { v in state.config.offlineLLMModel = v; state.saveConfig() }
                                    ), prompt: Text("llama3.1"))
                                    .textFieldStyle(.roundedBorder)
                                    Button("Discover local models") {
                                        Task { @MainActor in await ModelRegistry.shared.discoverLocal() }
                                    }
                                }
                            }
                            if let status = modelRegistry.localStatus {
                                Text(status).font(.caption)
                                    .foregroundStyle(modelRegistry.local != nil ? Color.secondary : Color.orange)
                            }
                            if !modelRegistry.localTags.isEmpty {
                                Text("Installed: " + modelRegistry.localTags.joined(separator: ", "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if state.offlineMode && modelRegistry.local == nil {
                                Text("Offline mode is on but no local model was found. Chat falls back to the cloud until a local server is reachable.")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                            Text("Offline mode routes chat to a local model; web research and cloud voice are disabled. The model and base URL persist; the on/off switch resets to cloud on relaunch so a flaky local server never strands you. Works with Ollama (default), vLLM, or llama.cpp on the OpenAI-compatible endpoint.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .id("models.offline")
                    }

                    if sectionVisible("models.endpoints") {
                        ModelConfigSection()
                            .id("models.endpoints")
                    }

                    if sectionVisible("models.mcp") {
                        MCPServersSection()
                            .id("models.mcp")
                    }

                    saveBar
                }
                .modifier(SettingsFormChrome())
            }
            .onAppear { scrollToPendingAnchor(proxy) }
            .onChange(of: pendingAnchor) { _, _ in scrollToPendingAnchor(proxy) }
        }
    }

    // Item 22: chat/swarm/cron preset editor lives inside Settings rather
    // than its own sidebar tab. Presets are configuration, not a workspace.
    private var presetsSub: some View {
        PresetsView()
    }

    // MARK: - Pane 4: Appearance

    // Items 23+26: consolidated Appearance pane (accent hue with WCAG gate,
    // dark/light/auto, glass intensity, reduce motion, orb/glow/stage toggles).
    private var appearancePane: some View {
        AppearanceSettingsView()
    }

    private var dataSecuritySubPicker: some View {
        Picker("", selection: $dataSecuritySub) {
            Text("Backup").tag("backup")
            Text("Security").tag("security")
            Text("Folders").tag("folders")
            Text("Data & Capabilities").tag("capabilities")
        }
    }

    // MARK: - Pane 5: Data & Security (old Backup + Security + the
    // non-model parts of Upgrades + Telemetry)

    private var dataSecurityPane: some View {
        VStack(spacing: 0) {
            // Folders is the FILES ALLOWLIST, so Data and Security is where a
            // person goes looking for it. Phase C fold: it had its own rail row
            // and is now a sub-pane here. A fourth segment rather than a sixth
            // top-level pane on purpose, because the comment above records what
            // a fifth long label already cost this picker at the 840pt floor.
            // Segmented where the segments fit, a menu where they do not: at
            // the pane's 360pt floor the segmented row ran past both edges.
            ViewThatFits(in: .horizontal) {
                dataSecuritySubPicker.pickerStyle(.segmented)
                dataSecuritySubPicker.pickerStyle(.menu).frame(maxWidth: GruxLayout.settingsMenuPickerMax)
            }
            .labelsHidden()
            .padding(.horizontal, GruxSpacing.l)
            .padding(.top, GruxSpacing.m)
            Group {
                switch dataSecuritySub {
                case "security": securitySub
                case "folders": foldersSub
                case "capabilities": capabilitiesSub
                default: backupSub
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // Items 32/33: backup now, auto-backup cadence, restore with manifest
    // preview, selective memory/commands export-import.
    private var backupSub: some View {
        BackupView()
    }

    // Items 30/31: injection screening, URL guard policy, Touch ID gates.
    private var securitySub: some View {
        SecuritySettingsView()
    }

    /// Folders, folded in from its own rail row. It is the allowlist of places
    /// Grux may read and write, which is a security question, so it lives with
    /// the other security questions rather than beside Notes and Documents.
    private var foldersSub: some View {
        FoldersManagementView()
    }

    private var capabilitiesSub: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Form {
                    // ONLY WHEN SOMETHING IS ACTUALLY BROKEN. A recovery section
                    // that renders empty on every healthy launch is a section
                    // everybody learns to scroll past, which is how it comes to
                    // be scrolled past on the one launch it matters.
                    //
                    // WHAT THIS IS FOR. `Persistence.load` quarantines a state
                    // file that exists and does not decode, then refuses every
                    // write to that path until somebody acknowledges it, which
                    // is what stops a debounced save replacing the user's data
                    // with an empty default seconds later. All of that already
                    // worked and none of it was visible: the only report was an
                    // NSLog line, so the recovery path existed for whoever
                    // happened to be reading Console at the time and for nobody
                    // else.
                    if !decodeFailures.isEmpty {
                        Section("Files Grux could not read") {
                            Text("""
                                 Grux found one of its own files, could not read it, and has not \
                                 written to it since. Nothing has been replaced. Each one below \
                                 says where your file is and where the copy of it went.
                                 """)
                            .fixedSize(horizontal: false, vertical: true)

                            ForEach(decodeFailures, id: \.path) { failure in
                                decodeFailureRow(failure)
                            }
                        }
                        .id("data.recovery")
                    }

                    // Every credential Grux can hold, generated from the contract
                    // rather than written out. Before this, 8 of the 14 key
                    // capabilities had no field anywhere in the app while their
                    // remediation told the reader to add them "in Settings", so
                    // more than half the credentials were a dead end. The Usage
                    // tab was pointing at a query-key field that did not exist.
                    Section {
                        CapabilityCredentialsSection()
                    }
                    // Anchored so the sidebar's "N features need setup" count
                    // can land here. Without an id the tag resolved through
                    // SettingsSearchRegistry's final fallback to the General
                    // pane, so the one control that speaks for every capability
                    // would have opened the one pane that mentions none of them.
                    .id("data.credentials")
                    if sectionVisible("data.brands") {
                        Section("Brands") {
                            AddBrandRow()
                        }
                        .id("data.brands")
                    }
                    if sectionVisible("data.memory") {
                        Section("Persistent memory") {
                            TuningPointer(text: TuningCopy.memoryPointer)
                            Text("Local-only: embeddings generated on-device via Apple NLEmbedding, stored in ~/Library/Application Support/Grux/. No data leaves your Mac.")
                                .font(.caption).foregroundStyle(.secondary)
                            if state.config.memoryEnabled {
                                HStack(spacing: GruxSpacing.l) {
                                    memoryStat("chats", (memoryCounts[.chatUser] ?? 0) + (memoryCounts[.chatAssistant] ?? 0))
                                    memoryStat("ambient", memoryCounts[.ambient] ?? 0)
                                    memoryStat("focus", memoryCounts[.focus] ?? 0)
                                    memoryStat("web", memoryCounts[.web] ?? 0)
                                    Spacer()
                                    DestructiveButton(
                                        "Clear memory",
                                        question: "Delete everything Grux has remembered?",
                                        detail: "Removes every stored fact, person, decision and "
                                            + "web note. Grux keeps working and starts learning "
                                            + "again from your next conversation, but what it "
                                            + "knows about you now is gone. This cannot be undone.",
                                        confirmLabel: "Delete memory"
                                    ) {
                                        SemanticMemory.shared.clearAll()
                                        memoryCounts = SemanticMemory.shared.countByKind()
                                    }.buttonStyle(.borderless).font(.caption)
                                }
                            }
                        }
                        .id("data.memory")
                    }

                    if sectionVisible("data.phone") {
                        Section("Grux Phone companion") {
                            Toggle("Let the Grux Phone app connect to this Mac", isOn: Binding(
                                get: { state.config.phoneCompanionEnabled },
                                set: { v in
                                    state.config.phoneCompanionEnabled = v
                                    state.saveConfig()
                                }
                            ))
                            Text("Off by default. When on, Grux opens a WebSocket listener that the Grux Phone app connects to over your local network. Traffic is ChaCha20-Poly1305 encrypted end to end. The phone has to be on this same network: Grux does not publish a public address for your Mac, so pairing over cellular or from another network will not work. Leave it off unless you actually pair a phone. Takes effect on next launch.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .id("data.phone")
                    }
                    if sectionVisible("data.prInbox") {
                        Section("Digest inbox") {
                            Toggle("Let a companion service push digests to this Mac", isOn: Binding(
                                get: { state.config.prInboxEnabled },
                                set: { v in
                                    state.config.prInboxEnabled = v
                                    state.saveConfig()
                                }
                            ))
                            Text("Off by default, and takes effect on next launch. When on, Grux opens a token-guarded HTTP listener on port 3852 across your local network so a service you run can push pull-request and test digests in. With it off, Grux opens no listening socket at all. Leave it off unless you are running that companion service.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .id("data.prInbox")
                    }
                    if sectionVisible("data.asc") {
                        Section("App Store Connect") {
                            Toggle("Watch the review state of your apps", isOn: Binding(
                                get: { state.config.ascMonitorEnabled },
                                set: { v in
                                    state.config.ascMonitorEnabled = v
                                    state.saveConfig()
                                }
                            ))
                            Text("Off by default, and takes effect on next launch. When on, Grux looks for an App Store Connect API key in a ship-config.json under your projects, then asks Apple for the review state of your apps every 12 hours and tells you when one is rejected. It uses a key you supply and sends nothing anywhere else. With it off, Grux never scans for that file and never contacts Apple.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .id("data.asc")
                    }
                    if sectionVisible("data.controlSocket") {
                        Section("Command line") {
                            Toggle("Let the grux command talk to this app", isOn: Binding(
                                get: { state.config.controlSocketEnabled },
                                set: { v in
                                    state.config.controlSocketEnabled = v
                                    state.saveConfig()
                                }
                            ))
                            Text("On by default, and takes effect on next launch. Grux listens on two files in your home folder that only your account can open, never a network port: one the grux command uses to ask this app things and change settings, and one you can drop a line of text into to send Grux a message. Any program running as you can use both, including to ask Grux to bring up a permission dialog or to run a tool. Turning it off leaves the grux command able to read files Grux has written, and unable to change anything.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .id("data.controlSocket")
                    }
                    if sectionVisible("data.foundry") {
                        Section("Self-upgrade loop") {
                            Toggle("Let Grux propose changes to itself", isOn: Binding(
                                get: { state.config.foundryEnabled },
                                set: { v in
                                    state.config.foundryEnabled = v
                                    state.saveConfig()
                                }
                            ))
                            Text("Off by default, and takes effect on next launch. When on, Grux looks over how you have been using it once a night, writes up changes it thinks would help, and asks you before building any of them. That nightly pass sends what it found to a model, so it spends against your key. With it off Grux never proposes anything and never spends on this.")
                                .font(.caption).foregroundStyle(.secondary)
                            TuningPointer(text: TuningCopy.selfUpgradePointer)
                        }
                        .id("data.foundry")
                    }

                    if sectionVisible("data.screenControl") {
                        Section("Screen control") {
                            Toggle("Let Grux click, type, and scroll for you", isOn: Binding(
                                get: { state.config.screenControlEnabled },
                                set: { v in
                                    state.config.screenControlEnabled = v
                                    state.saveConfig()
                                    // THE EXPLICIT GRANT PATH, which shipped with no
                                    // call site anywhere. Turning this on is the one
                                    // moment the user has said they want Grux driving
                                    // the screen, so it is the only place the system
                                    // Accessibility prompt belongs. Without it the
                                    // switch wrote a flag that could never take effect
                                    // and asked the user to walk to System Settings
                                    // themselves.
                                    if ScreenControlEngine.shouldPromptForAccessibility(
                                        turningOn: v,
                                        alreadyGranted: ScreenControlEngine.hasAccessibility()) {
                                        ScreenControlEngine.promptAccessibility()
                                    }
                                }
                            ))
                            Text("Off by default. When on, Grux can move the pointer, click, type, and scroll on your behalf through the macOS Accessibility API, so it can finish a task hands-free once it can see the screen. It also needs Accessibility granted (System Settings → Privacy & Security → Accessibility → Grux). With it off, Grux never touches your pointer or keyboard. Every action is written to the security audit log; typed text is never logged. Leave it off unless you want Grux operating the screen for you.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .id("data.screenControl")
                    }

                    if sectionVisible("data.web") {
                        Section("Real-time web research") {
                            Toggle("Let Grux answer questions by searching the web (Brave + Haiku summarize)", isOn: $webResearchEnabled)
                                .onChange(of: webResearchEnabled) { _, new in
                                    state.config.webResearchEnabled = new
                                    state.saveConfig()
                                }
                            Text("Replaces the old 'open a Google tab' flow with an inline conversational answer. Uses Brave Search (free tier ~1,000 queries/month) + Haiku to summarize. Browser tab-search still works separately.")
                                .font(.caption).foregroundStyle(.secondary)

                            // Caption above rather than LabeledContent, because a Form puts a
                            // LabeledContent label in a leading column OUTSIDE the
                            // content area. "Brave API key" plus a field plus Hide and
                            // Save on one row is the widest shape in this Form, and
                            // the Form is only as narrow as its widest row, which is
                            // what pushed the credentials list past the pane at 840pt.
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Brave API key")
                                    .font(.caption).foregroundStyle(.secondary)
                                HStack {
                                    if showBraveKey {
                                        TextField("", text: $braveKey, prompt: Text("brv_..."))
                                            .textFieldStyle(.roundedBorder)
                                    } else {
                                        SecureField("", text: $braveKey, prompt: Text("brv_..."))
                                            .textFieldStyle(.roundedBorder)
                                    }
                                    Button(showBraveKey ? "Hide" : "Show") { showBraveKey.toggle() }
                                        .buttonStyle(.borderless).font(.caption)
                                    Button("Save") {
                                        let trimmed = braveKey.trimmingCharacters(in: .whitespacesAndNewlines)
                                        _ = KeychainStore.set(.braveApiKey, trimmed)
                                        savedAt = Date()
                                    }
                                    .buttonStyle(.borderless).font(.caption)
                                }
                            }
                            Link("Get a Brave Search API key →", destination: URL(string: "https://api.search.brave.com/app/subscriptions/subscribe")!)
                                .font(.caption)
                                .gruxLink()
                        }
                        .id("data.web")
                    }

                    if sectionVisible("data.replicate") {
                        Section("Media generation") {
                            // Caption above rather than LabeledContent, because a Form puts a
                            // LabeledContent label in a leading column OUTSIDE the
                            // content area. "Replicate API token" plus a field plus Hide and
                            // Save on one row is the widest shape in this Form, and
                            // the Form is only as narrow as its widest row, which is
                            // what pushed the credentials list past the pane at 840pt.
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Replicate API token")
                                    .font(.caption).foregroundStyle(.secondary)
                                HStack {
                                    if showReplicateKey {
                                        TextField("", text: $replicateKey, prompt: Text("token"))
                                            .textFieldStyle(.roundedBorder)
                                    } else {
                                        SecureField("", text: $replicateKey, prompt: Text("token"))
                                            .textFieldStyle(.roundedBorder)
                                    }
                                    Button(showReplicateKey ? "Hide" : "Show") { showReplicateKey.toggle() }
                                        .buttonStyle(.borderless).font(.caption)
                                    Button("Save") {
                                        let trimmed = replicateKey.trimmingCharacters(in: .whitespacesAndNewlines)
                                        _ = KeychainStore.set(.replicateApiKey, trimmed)
                                        savedAt = Date()
                                    }
                                    .buttonStyle(.borderless).font(.caption)
                                }
                            }
                            Text("Media Studio generates images through Replicate, using a token you supply. Product-in-scene renders still route through the render service instead, so a real product is composited byte-exact rather than imagined.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .id("data.replicate")
                    }

                    if sectionVisible("data.music") {
                        Section("Music picking") {
                            Text("How Grux handles vague song requests like 'play a hype song by Green Day'. All strategies still use Apple Music for playback when possible.")
                                .font(.caption).foregroundStyle(.secondary)
                            Picker("", selection: $musicStrategy) {
                                ForEach(MusicStrategy.allCases) { s in
                                    Text(s.label).tag(s)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .onChange(of: musicStrategy) { _, new in
                                state.config.musicStrategy = new
                                state.saveConfig()
                                savedAt = Date()
                            }
                            Text(musicStrategy.shortHelp)
                                .font(.caption).foregroundStyle(.secondary)
                            if musicStrategy == .webFirst && braveKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Label("Web-first needs a Brave Search API key (above).", systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption2).foregroundStyle(.orange)
                            }
                        }
                        .id("data.music")
                    }

                    if sectionVisible("data.ios") {
                        // iOS developer settings, used by ios_scaffold when Grux builds iPhone apps.
                        Section("iOS developer") {
                            Text("Used when Grux scaffolds iPhone apps. Bundle prefix becomes the reverse-DNS root for new apps (e.g. '\(developerBundlePrefix).projecto'). Team ID is only needed to install on a physical device. Simulator builds don't require it.")
                                .font(.caption).foregroundStyle(.secondary)
                            LabeledContent("Bundle prefix") {
                                TextField("", text: $developerBundlePrefix, prompt: Text("com.example"))
                                    .textFieldStyle(.roundedBorder)
                                    .onSubmit {
                                        state.config.developerBundlePrefix = developerBundlePrefix.trimmingCharacters(in: .whitespacesAndNewlines)
                                        state.saveConfig(); savedAt = Date()
                                    }
                            }
                            LabeledContent("Team ID") {
                                TextField("", text: $developerTeamId, prompt: Text("ABCDE12345 (optional)"))
                                    .textFieldStyle(.roundedBorder)
                                    .onSubmit {
                                        state.config.developerTeamId = developerTeamId.trimmingCharacters(in: .whitespacesAndNewlines)
                                        state.saveConfig(); savedAt = Date()
                                    }
                            }
                            Button("Save iOS settings") {
                                state.config.developerTeamId = developerTeamId.trimmingCharacters(in: .whitespacesAndNewlines)
                                state.config.developerBundlePrefix = developerBundlePrefix.trimmingCharacters(in: .whitespacesAndNewlines)
                                state.saveConfig(); savedAt = Date()
                            }
                            .controlSize(.small)
                        }
                        .id("data.ios")
                    }

                    if sectionVisible("data.capturePrivacy") {
                        Section("Privacy and capture") {
                            Text("Grux photographs your screen on a timer and sends the frame to a vision model. These are the things it refuses to look at. Excluded windows are removed before the frame is composited, so their pixels are never captured, even when the app is not in front.")
                                .font(.caption).foregroundStyle(.secondary)

                            LabeledContent("Frames sent to a model") {
                                Text(state.lastFrameSentAt == nil
                                     ? "\(state.framesSentToModel) this launch"
                                     : "\(state.framesSentToModel) this launch, last \(state.lastFrameSentAt!, style: .relative) ago")
                                    .foregroundStyle(.secondary)
                            }
                            LabeledContent("Captures blocked") {
                                Text(state.captureBlockedCount == 0
                                     ? "none"
                                     : "\(state.captureBlockedCount), last was \(state.lastCaptureBlockedApp)")
                                    .foregroundStyle(.secondary)
                            }
                            if state.lastCaptureExcludedWindowCount > 0 {
                                LabeledContent("Windows cut from last frame") {
                                    Text("\(state.lastCaptureExcludedWindowCount)").foregroundStyle(.secondary)
                                }
                            }

                            Text("Excluded apps, one bundle id per line")
                                .font(.caption.weight(.semibold))
                            TextEditor(text: Binding(
                                get: { state.config.captureExcludedBundleIds.joined(separator: "\n") },
                                set: { v in
                                    state.config.captureExcludedBundleIds = Self.linesToList(v)
                                    state.saveConfig()
                                }
                            ))
                            .font(.system(.caption, design: .monospaced))
                            .frame(minHeight: 110)

                            Text("Excluded window titles, one pattern per line, matched anywhere in the title")
                                .font(.caption.weight(.semibold))
                            TextEditor(text: Binding(
                                get: { state.config.captureExcludedTitlePatterns.joined(separator: "\n") },
                                set: { v in
                                    state.config.captureExcludedTitlePatterns = Self.linesToList(v)
                                    state.saveConfig()
                                }
                            ))
                            .font(.system(.caption, design: .monospaced))
                            .frame(minHeight: 90)

                            HStack {
                                Button("Restore defaults") {
                                    state.config.captureExcludedBundleIds = CapturePrivacy.defaultExcludedBundleIds
                                    state.config.captureExcludedTitlePatterns = CapturePrivacy.defaultExcludedTitlePatterns
                                    state.saveConfig()
                                }
                                .controlSize(.small)
                                Spacer()
                                Text("Grux always excludes itself.")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .id("data.capturePrivacy")
                    }

                    if sectionVisible("data.workdayLog") {
                        Section("Workday log") {
                            Text("Every morning Grux writes a private record of the day before: which projects you worked in, which branches, and the commit messages you wrote. It reads them from your own machine.")
                                .font(.caption).foregroundStyle(.secondary)

                            Toggle("Write a workday log each morning", isOn: $workdayLogEnabled)
                                .onChange(of: workdayLogEnabled) { _, on in
                                    // The scheduler polls every 60 seconds, so stopping the
                                    // timer is what makes OFF take effect now rather than
                                    // at the next launch. checkAndFire reads the same key,
                                    // which is what makes the off survive a restart.
                                    if on { WorkdayLogScheduler.shared.start() }
                                    else { WorkdayLogScheduler.shared.stop() }
                                }

                            Toggle("Also copy it to iCloud Drive", isOn: $workdayLogMirrorsToICloud)
                                .disabled(!workdayLogEnabled)
                            // NAMES THE FOLDER AND NAMES WHAT LEAVES THE MAC. This used to
                            // be on with no switch and no mention anywhere: a GruxAI folder
                            // simply appeared in iCloud Drive and on the person's iPhone.
                            Text("Off by default. Turning it on writes a markdown copy to iCloud Drive > GruxAI > workday-logs, which Apple then syncs to every device signed in to your Apple ID. Your meetings and chat threads are never copied there.")
                                .font(.caption2).foregroundStyle(.secondary)

                            if !workdayLogEnabled {
                                Text("Logs already written stay on this Mac in Application Support. Nothing is deleted.")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .id("data.workdayLog")
                    }

                    if let s = savedAt {
                        Text("Saved \(s, style: .relative) ago")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .modifier(SettingsFormChrome())
            }
            .onAppear { scrollToPendingAnchor(proxy) }
            .onChange(of: pendingAnchor) { _, _ in scrollToPendingAnchor(proxy) }
        }
    }

    // MARK: - Shared pieces

    /// One corrupt state file, named, located, and acknowledgeable.
    ///
    /// NAMES THE QUARANTINE PATH IN FULL, and that is the point of the row
    /// rather than a detail of it. The copy is the only thing standing between
    /// the user and the loss the guard just prevented, and a copy nobody can
    /// find is the same as no copy. The path is selectable so it can be pasted
    /// into a terminal or an open dialog.
    ///
    /// THE BUTTON IS HONEST ABOUT WHAT IT COSTS. Acknowledging is not
    /// "dismiss": it lifts the write refusal, so the next save replaces the
    /// user's file with whatever the store came up holding, which after a
    /// failed decode is usually the empty default. Somebody who reads the
    /// button as closing a notification loses exactly the data the quarantine
    /// just saved, so the sentence under it says the cost before the click
    /// rather than after.
    @ViewBuilder
    private func decodeFailureRow(_ failure: Persistence.DecodeFailure) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(URL(fileURLWithPath: failure.path).lastPathComponent)
                .font(.system(size: 13, weight: .semibold))

            VStack(alignment: .leading, spacing: 2) {
                Text("Could not read")
                    .font(.caption).foregroundStyle(.secondary)
                Text(failure.path)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // READ FROM THE GUARD, not inferred from the presence of this row.
            // The record and the refusal are written and cleared together, so
            // this says the same thing every time in practice. It is asked
            // anyway because the refusal is the half that actually protects the
            // file, and a row that ASSERTS protection it never checked is worth
            // less than one that reports what the guard says, especially on the
            // day the two disagree.
            if Persistence.isWriteRefused(URL(fileURLWithPath: failure.path)) {
                Text("Grux is refusing to write to it.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Grux is NOT refusing writes to this file, so the next save can replace it. Get what you need out of the copy now.")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 2) {
                if failure.quarantined.isEmpty {
                    // The copy is what makes acknowledging safe, so its absence
                    // changes the advice rather than being a footnote.
                    Text("The copy could not be written, so the file itself is the only version there is. Copy it somewhere of your own before you acknowledge this.")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Copy kept at")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(failure.quarantined)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("What went wrong")
                    .font(.caption).foregroundStyle(.secondary)
                Text(failure.error)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button("Let Grux overwrite this file") {
                Persistence.acknowledgeDecodeFailure(URL(fileURLWithPath: failure.path))
                // Re-read rather than remove locally, because acknowledging is
                // the one operation that changes the list and the store is the
                // only place that knows the result.
                decodeFailures = Persistence.decodeFailures
            }
            Text("That allows the next save to replace this file with whatever Grux is holding now, which after a failed read is usually nothing. Get anything you need out of the copy first. The copy is never deleted, but the file at the top of this row will be gone.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func refreshVoices() async {
        loadingVoices = true
        defer { loadingVoices = false }
        // Keychain-backed write, NEVER route the key through config.json.
        _ = KeychainStore.set(.elevenLabsApiKey, elevenKey.trimmingCharacters(in: .whitespacesAndNewlines))
        let v = await SpeechEngine.shared.fetchVoices()
        await MainActor.run {
            self.voices = v.sorted { $0.name < $1.name }
        }
    }

    // MARK: - Microphones (voice-processing whitelist + preferred input)
    //
    // Why this UI exists: enabling VPIO was believed to flip the whole output
    // chain into narrow-band
    // "communications" codec whenever an audio unit uses VoiceProcessingIO.
    // Grux enables VPIO on Ambient + Dictation by default. For mics that
    // don't need our echo cancellation (DJI Mic Mini etc.), the user can tick
    // "Preserve speaker fidelity" and Grux will skip VPIO on that mic,
    // keeping Music/Safari/YouTube in full stereo.
    //
    // The "Use as default input" radio sets the system default input device
    // (via CoreAudio, no 3rd-party tools), and "Revert to MacBook built-in"
    // clears it + restores the internal mic.

    private var micsSection: some View {
        Section("Microphones") {
            let devices = MicDevices.listInputs()
            let activeUID = MicDevices.systemDefaultInputUID() ?? ""
            let preferredUID = MicWhitelist.preferredInputUID ?? ""
            let whitelist = MicWhitelist.current()

            // The master switch. Until 2026-08-22 the only way to escape voice
            // processing was the per-device checkbox one row down, which meant
            // the default (on) quietly degraded every new user's music and video
            // audio the first time they tapped the mic, and the fix was a box
            // they had no reason to look for. The per-device toggles below still
            // override this for a single mic; this turns it off everywhere.
            // The on line used to say voice processing runs for as long as Grux
            // listens. Since 2026-09-21 it runs only when the microphone could
            // hear the Mac's output (VoiceProcessingPolicy), and since
            // 2026-09-23 ambient listening never asks for it at all, because it
            // closes the microphone while Grux speaks and so has no echo to
            // cancel. The copy also used to promise other audio would play "at
            // call quality"; that was never measured and is not true. Measured
            // on built-in speakers: output stays 48000 Hz and a 12 kHz tone
            // survives 73 dB above the noise floor while voice processing runs,
            // and a playback-only app is untouched. What it really costs is
            // other apps that are RECORDING, whose microphone capture stops
            // dead the moment it starts.
            Toggle("Use Apple voice processing (echo cancellation, noise suppression, level control)",
                   isOn: $premiumNoiseCancellation)
                .onChange(of: premiumNoiseCancellation) { _, new in
                    state.config.premiumNoiseCancellation = new
                    state.saveConfig()
                }
            Text(premiumNoiseCancellation
                 ? "On for dictation, and only when your speakers could be heard by the microphone. It cancels your music and room noise out of what Grux hears and evens out your level. Always off for background listening, which closes the microphone whenever Grux speaks and so has nothing to cancel. Your music and video keep full quality either way, but while it runs another app that is recording, a call or a screen capture, can lose its microphone."
                 : "Off. Nothing Grux does takes the microphone away from another app that is recording. Dictation loses noise suppression and level control, so a quiet voice on a built-in mic may transcribe a little less accurately.")
                .font(.caption).foregroundStyle(.secondary)

            if devices.isEmpty {
                // A genuine problem state, not an empty list, so it says what
                // to do about it. "No input devices detected." alone left the
                // reader unable to tell a broken Grux from an unplugged mic.
                Text("No input devices detected. Connect a microphone, or check Privacy and Security, Microphone in System Settings, then press Refresh.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(devices) { dev in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(dev.uid == activeUID ? Color.green : Color.secondary.opacity(0.4))
                                .frame(width: 8, height: 8)
                            Text(dev.name).font(.callout)
                            if dev.uid == activeUID {
                                Text("active")
                                    .font(.caption2).foregroundStyle(.secondary)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(.green.opacity(0.15), in: Capsule())
                            }
                            Spacer()
                        }
                        HStack(spacing: 16) {
                            Toggle("Preserve speaker fidelity (skip voice processing)",
                                   isOn: Binding(
                                    get: { whitelist.contains(dev.uid) },
                                    set: { new in
                                        MicWhitelist.setWhitelisted(dev.uid, new)
                                        micsRefreshTick &+= 1
                                    }
                                   ))
                                .toggleStyle(.checkbox)
                                .font(.caption)
                            Spacer()
                            Toggle("Use as default input",
                                   isOn: Binding(
                                    get: { preferredUID == dev.uid },
                                    set: { new in
                                        if new {
                                            MicWhitelist.preferredInputUID = dev.uid
                                            _ = MicDevices.setSystemDefaultInput(toUID: dev.uid)
                                        } else {
                                            MicWhitelist.preferredInputUID = nil
                                        }
                                        micsRefreshTick &+= 1
                                    }
                                   ))
                                .toggleStyle(.checkbox)
                                .font(.caption)
                        }
                        Text("UID: \(dev.uid)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.vertical, 4)
                }
            }

            HStack(spacing: 12) {
                Button {
                    MicWhitelist.revertToBuiltIn()
                    micsRefreshTick &+= 1
                } label: {
                    Label("Revert to MacBook built-in mic", systemImage: "arrow.counterclockwise")
                }
                Spacer()
                Button {
                    micsRefreshTick &+= 1
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            .padding(.top, 4)

            Text("Dictation turns on Apple's voice processing (echo cancellation and noise suppression) when you listen on speakers. Background listening never does, because it closes the microphone while Grux speaks and so has no echo to cancel. Your music and video keep full quality either way. What voice processing does cost is other apps: while it runs, an app that is recording, a call or a screen capture, can lose its microphone. Tick \"Preserve speaker fidelity\" on any external mic that already cleans up its own sound, like the DJI Mic, to skip it entirely.")
                .font(.caption).foregroundStyle(.secondary)
                .id(micsRefreshTick) // force caption redraw when toggles change
        }
        // Auto-whitelist (DJI Mic etc.) and a mid-session reconnect both
        // post .gruxMicWhitelistChanged. Bump the tick so the toggles
        // redraw without the user clicking Refresh.
        .onReceive(NotificationCenter.default.publisher(for: .gruxMicWhitelistChanged)) { _ in
            micsRefreshTick &+= 1
        }
    }

    @ViewBuilder
    private func memoryStat(_ label: String, _ count: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(count)").font(.caption.monospacedDigit().bold())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var saveBar: some View {
        HStack {
            if let s = savedAt {
                Text("Saved \(s, style: .relative) ago").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Save") { save() }.keyboardShortcut(.defaultAction)
        }
    }

    /// Split an editor buffer into a clean list: trimmed, no blanks, no dupes.
    /// A stray empty line would otherwise become an empty pattern, and an empty
    /// pattern matched as a substring matches every title, which would silently
    /// block all capture. Guarded here and again in CapturePrivacy.
    static func linesToList(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    private func loadFromState() {
        let c = state.config
        // API keys load from Keychain, the config.json fields hold only the
        // legacy plaintext (pre-migration) or the "[MIGRATED]" sentinel.
        apiKey = KeychainStore.get(.anthropicApiKey)
        model = c.model
        interval = Double(c.captureIntervalSeconds)
        drift = Double(c.driftThreshold)
        auto = c.autoPromoteDetectedTask
        notify = c.notificationsEnabled
        screen = c.screenAnalysisEnabled
        wakeWord = c.wakeWordEnabled
        autoSendWake = c.autoSendOnWake
        useEleven = c.useElevenLabs
        elevenKey = KeychainStore.get(.elevenLabsApiKey)
        elevenVoiceId = c.elevenLabsVoiceId
        elevenModelId = c.elevenLabsModelId
        webResearchEnabled = c.webResearchEnabled
        premiumNoiseCancellation = c.premiumNoiseCancellation
        musicStrategy = c.musicStrategy
        developerTeamId = c.developerTeamId
        developerBundlePrefix = c.developerBundlePrefix
        braveKey = KeychainStore.get(.braveApiKey)
        replicateKey = KeychainStore.get(.replicateApiKey)
        offlineMode = state.offlineMode
        offlineLLMModel = c.offlineLLMModel
        ollamaBaseURL = c.ollamaBaseURL
        memoryCounts = SemanticMemory.shared.countByKind()
        decodeFailures = Persistence.decodeFailures
        SpeechEngine.shared.applyPlaybackRate(c.voicePlaybackRate)
    }

    private func save() {
        var c = state.config
        // API keys go to the Keychain, NOT into config.json. The plaintext
        // fields stay at "[MIGRATED]" so a stray reader sees a sentinel, not
        // a real key.
        let trimmedAnthropic = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedAnthropic.isEmpty {
            _ = KeychainStore.set(.anthropicApiKey, trimmedAnthropic)
            c.anthropicApiKey = "[MIGRATED]"
        }
        let trimmedEleven = elevenKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedEleven.isEmpty {
            _ = KeychainStore.set(.elevenLabsApiKey, trimmedEleven)
            c.elevenLabsApiKey = "[MIGRATED]"
        }
        c.model = model
        c.captureIntervalSeconds = Int(interval)
        c.driftThreshold = Int(drift)
        c.autoPromoteDetectedTask = auto
        c.notificationsEnabled = notify
        c.screenAnalysisEnabled = screen
        c.wakeWordEnabled = wakeWord
        c.autoSendOnWake = autoSendWake
        c.useElevenLabs = useEleven
        c.elevenLabsVoiceId = elevenVoiceId.trimmingCharacters(in: .whitespacesAndNewlines)
        c.elevenLabsModelId = elevenModelId.trimmingCharacters(in: .whitespacesAndNewlines)
        state.config = c
        state.saveConfig()
        savedAt = Date()
    }

    /// A person verifying a key they may have just fixed. Never gated on our
    /// cached belief about the OLD key, and a success here clears the breaker.
    private func testKey() async {
        // No longer needs an exemption: background is now opt-in, so a person
        // pressing Test Key is permissive by default. A success still clears the
        // latch, and credentialChanged() clears it for a DIFFERENT key.
        ProviderHealth.shared.credentialChanged()
        await testKeyInner()
    }

    private func testKeyInner() async {
        // DELIBERATELY NOT ROUTED, and the one place in the app that should not
        // be. This button answers "is the Anthropic key you just pasted good",
        // so sending it through the provider router would test whichever backend
        // happens to be active and report success on a key it never used.
        // `BackendSweepTests` now carries this file in its sweep set with
        // `testKeyInner` named as the one exempted site, and pins the count at
        // one, so a second `ClaudeClient()` anywhere in this file turns the
        // suite red. That sentence used to say the exception was recorded and it
        // was not: the sweep set deliberately excluded this file, so the comment
        // pointed at a machine-checked list this site was never in, which is the
        // same invisible drift the sweep exists to stop.
        do {
            let reply = try await ClaudeClient().complete(
                apiKey: apiKey, model: model.isEmpty ? "claude-haiku-4-5-20251001" : model,
                system: "Reply with just: OK",
                messages: [ClaudeMessage(role: "user", content: "ping")],
                maxTokens: 50, temperature: 0
            )
            // actionRequired so the Test button always banners immediately
            // despite the system-category silent default in the triage matrix.
            NotificationManager.shared.sendCategorized(.system, actionRequired: true, title: "API key OK", body: "Got reply: \(reply.prefix(60))")
        } catch {
            NotificationManager.shared.sendInfo(title: "API key failed", body: error.localizedDescription)
        }
    }

    private func pingLocalLLM() async {
        localLLMStatus = "pinging…"
        let endpoint = state.config.localLLMEndpoint
        let modelName = state.config.localLLMModel.isEmpty ? GruxConfig.defaultLocalModel : state.config.localLLMModel
        let started = Date()
        do {
            let client = LocalLLMClient(timeoutSeconds: 30)
            let reply = try await client.complete(
                endpoint: endpoint,
                model: modelName,
                system: "Reply with exactly: pong",
                messages: [ClaudeMessage(role: "user", content: "ping")],
                maxTokens: 16,
                temperature: 0.0,
                feature: "settings_ping"
            )
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            localLLMStatus = "ok (\(ms)ms) reply: \(reply.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))"
        } catch {
            localLLMStatus = "failed: \(error.localizedDescription)"
        }
    }
}

/// Proposes the container's OWN width to its content, so nothing can render
/// wider than the pane it lives in.
///
/// `.frame(maxWidth:)` is a proposal and not a clamp. A child whose intrinsic
/// demand exceeds the proposal draws at its demand anyway, and SwiftUI centres
/// an oversized child, which is how Settings bled off both edges at the 840pt
/// floor: content under the nav rail on the left and cut text on the right.
///
/// Reading the real width with a GeometryReader and handing it back as an exact
/// frame gives every child that respects a proposal, which is most of them, a
/// number it must fit. Deliberately not `.clipped()`, which would hide the cut
/// text rather than prevent it.
/// THE one place a Settings pane's chrome is defined.
///
/// Nine sub-panes had grown four different container shapes and six hand-written
/// `.padding()` calls, so "all the settings tabs should be consistent
/// padding/margin" was not a thing anybody could fix by adjusting a number: the
/// panes did not share a number to adjust. They share this instead.
///
/// `.formStyle(.grouped)` is the load-bearing half, and it is a bug fix rather
/// than a taste call. Without a style a macOS `Form` uses the COLUMNS layout,
/// which puts every label in a leading column sized to the widest label and then
/// asks for the width that requires. When that exceeds the pane, SwiftUI centres
/// the overflow and both edges bleed: measured on the Mini at 2026-08-30, "What
/// Grux calls you" and "What you call the assistant" rendered right-aligned in a
/// column that ended at the pane's leading edge, drawn over the sidebar, while
/// body text on the same rows was clipped on the right. One cause, both symptoms.
///
/// The three settings views that already looked right (Security, Terminal
/// sessions, Appearance) all live in their own files and all already set
/// `.formStyle(.grouped)`. This is not a new convention, it is the existing one
/// finally applied to the six Forms that never got it.
private struct SettingsFormChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .formStyle(.grouped)
            // Grouped supplies its own row insets, so the old bare `.padding()`
            // would double them. Leading, so a pane narrower than its content
            // clips predictably on one edge instead of bleeding off both.
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ClampToAvailableWidth: ViewModifier {
    func body(content: Content) -> some View {
        GeometryReader { geo in
            content.frame(width: geo.size.width, alignment: .top)
        }
    }
}

/// The Keep Grux on top row. Its caption never promises what the current shell
/// does not do: the classic sidebar never floats (`LaunchWindowSizer.level`).
enum KeepOnTopRow {
    nonisolated static func isEnabled(legacyShell: Bool) -> Bool { !legacyShell }

    nonisolated static func caption(legacyShell: Bool) -> String {
        legacyShell
            ? "Only the Command Panel can stay on top. Turn off Classic sidebar to use this."
            : "The panel stays above other windows. Off by default."
    }
}

/// Settings' "Hand setup to your agent". The panel shell opens the Optimize
/// hub, where the Hand it over door lives. The legacy shell hosts no hub, so
/// it writes the bundle right here and returns the line to show under the
/// button: where it went, or why it could not.
@MainActor
enum SettingsHandoff {
    static func run(legacyShell: Bool,
                    write: @MainActor () -> Result<URL, Swift.Error> = { HandoffBundle.writeLive() }) -> String? {
        guard legacyShell else {
            OptimizeHubState.shared.isExpanded = true
            // Settings is its own window, often over the panel or with the
            // launch window closed: bring the panel forward, as the palette's
            // Optimize Grux does, or the card expands where nobody sees it.
            AppState.shared.requestedTab = PanelKeys.none
            AppDelegate.shared?.openLaunchWindow(tab: PanelKeys.none)
            return nil
        }
        switch write() {
        case .success(let url):
            return OptimizeCopy.handoffWritten + " " + (url.path as NSString).abbreviatingWithTildeInPath
        case .failure(let error):
            return OptimizeCopy.handoffFailed(error.localizedDescription)
        }
    }
}
