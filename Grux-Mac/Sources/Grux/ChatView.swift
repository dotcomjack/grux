import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ChatView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var voice = VoiceInput.shared
    @StateObject private var speech = SpeechEngine.shared
    /// Changes only when hearing starts or stops, never at audio rate.
    @ObservedObject private var micHealth = MicHealth.shared
    @StateObject private var wake = WakeWordListener.shared
    @ObservedObject private var presets = PresetStore.shared
    @State private var draft = ""
    @State private var draftBeforeVoice = ""
    // Debounces the pre-send cost estimate refresh. Composer edits reschedule
    // this ~600ms task instead of re-pricing on every keystroke; the estimate
    // is what makes the cost line appear BEFORE the session's first send.
    @State private var estimateDebounce: Task<Void, Never>?
    @FocusState private var inputFocused: Bool
    // Drag-dropped image staged for the next send. Cleared after send() or
    // manual removal. Both the raw bytes (for the outgoing Claude payload)
    // and a decoded NSImage (for the inline preview chip) are held together
    // so a failed decode short-circuits attachment.
    @State private var pendingImageData: Data?
    @State private var pendingImageMediaType: String?
    @State private var pendingImagePreview: NSImage?
    @State private var dropTargeted: Bool = false
    @State private var attachmentError: String?
    // Tracks whether the message-list scroll position is pinned to (or near)
    // the bottom. When the user scrolls up, this flips false and the floating
    // "jump to latest" chip fades in. A hidden sentinel at the end of the
    // LazyVStack toggles this via onAppear/onDisappear.
    @State private var isAtBottom: Bool = true
    // Whether the transcript follows the newest message. True on open, on a
    // new message and on Latest. Only the person's own scrolling turns it
    // off or on (TranscriptScrollIntent); layout and size changes never do,
    // they only re-anchor while it is true. A reference, so a re-anchor
    // scheduled a moment before the person scrolled reads their choice when
    // it fires, not the value when it was scheduled (it read a stale true
    // and pulled them back down mid-resize).
    @State private var follow = ChatFollow()
    // How many of the newest messages the transcript lays out. A whole thread
    // measured 1715 ms and 220 MB to open at 500 messages, and nothing bounds
    // a thread's length (compaction needs a model route, and loading a thread
    // sets every message), so it lays out one page and "Show earlier" adds
    // more. A page of 16 opened 500 and 1000 message threads in 128 ms and
    // about 10 MB on the Mini (2026-09-28), against 85 ms for an empty one.
    @State private var shownCount = ChatView.transcriptPage

    // Item 24: shell bus fills the idle gap with canonical moments.
    @ObservedObject private var shellBus = ShellStateBus.shared
    // Observed so the conversation can re-pin itself when the live rail
    // appears underneath it and takes height the messages were using.
    @ObservedObject private var voiceRouter = VoiceCommandRouter.shared

    // Cost meter: the pre-run estimate published right before each send, plus
    // the model sources the composer chip picks from (discovered local tags +
    // saved custom endpoints).
    @ObservedObject private var costMeter = CostMeter.shared
    @ObservedObject private var registry = ModelRegistry.shared
    @ObservedObject private var endpoints = CustomEndpointStore.shared

    // Skills live in the composer (Phase C fold). The chip beside the model
    // chip opens them above the draft, and the `skills` tab opens Chat with
    // them already open, so the locked key still lands on Skills.
    @ObservedObject private var skillStore = SkillStore.shared
    @State private var skillsOpen = false
    private let opensSkills: Bool

    /// True inside the Command Panel's pane: the threads column folds into
    /// a popover behind a button in the header, so Chat is one column.
    @Environment(\.hostedInPane) private var hostedInPane
    @State private var threadsPopover = false
    /// The conversation alone, when the threads column is folded.
    static let paneMinWidth: CGFloat = 350
    /// The folded threads list's height. No layout token names a popover
    /// height, so it is named here.
    static let threadsPopoverHeight: CGFloat = 420

    /// The active thread and every thread id, as one value, so a change that
    /// moves both (a pick, "+", a delete) arrives as one change.
    struct ThreadsSnapshot: Equatable {
        let active: UUID?
        let ids: [UUID]
    }

    /// True when a change is a pick of a thread that already existed and the
    /// list holds the same threads. "+" (a new id) and a delete (the list
    /// changed) keep the folded list open, so a new chat can be named and a
    /// delete does not close the list mid-edit (R7.4).
    static func pickClosesThreads(from old: ThreadsSnapshot, to new: ThreadsSnapshot) -> Bool {
        guard let id = new.active, id != old.active else { return false }
        return old.ids.contains(id) && Set(old.ids) == Set(new.ids)
    }

    init(opensSkills: Bool = false) {
        self.opensSkills = opensSkills
    }

    /// Same resolver as the sidebar orb, the menu bar and the HUD. Push to
    /// talk (voice.isRecording) counts as speaking into Grux, so it reads as
    /// armed even when always-on listening is off.
    private var listeningTell: ListeningTell {
        let pushToTalk = voice.isRecording || voice.isTranscribing
        return ListeningTell.resolve(
            mode: pushToTalk ? .alwaysOn : state.config.listeningModeInEffect,
            micMuted: state.micMuted && !pushToTalk,
            isSpeaking: speech.isSpeaking || speech.isBuffering,
            isThinking: state.isThinking,
            notHearing: !pushToTalk && micHealth.notHearing)
    }

    /// How many rows the collapsed rail is about to draw. The conversation
    /// watches this: a rail that appears without re-pinning pushes the last
    /// message out of sight, which reads as Grux having eaten the reply.
    private var railRowCount: Int {
        VoiceLiveRailModel.visible(events: voiceRouter.events, tell: listeningTell, expanded: false).count
    }

    private var orbState: GruxOrbState {
        if shellBus.current.mode == .alert { return ShellMode.alert.orbState }
        if listeningTell == .off { return shellBus.current.mode.orbState }
        return listeningTell.orbState
    }

    var body: some View {
        HStack(spacing: 0) {
            if !hostedInPane {
                ChatThreadsSidebar()
                    .environmentObject(state)
                Rectangle()
                    .fill(GruxTheme.iridescentRim.opacity(0.4))
                    .frame(width: 1)
            }
            ZStack {
                backdrop
                VStack(spacing: 0) {
                    heroHeader
                    themedHairline
                    SessionsStrip()
                    messagesScroll
                    VoiceLiveRail()
                    if voice.isRecording || voice.isTranscribing {
                        liveVoiceStrip
                    }
                    if let err = voice.error {
                        errorStrip(err)
                    }
                    if let recovery = state.chatRecovery {
                        recoveryBanner(recovery)
                    }
                    inputBar
                }
            }
        }
        // Was minWidth 820, which (plus the 240 nav sidebar) forced a ~1060
        // content floor while the window floor was only 900, so narrowing the
        // window pushed the over-wide content off both edges and clipped it.
        // 560 = the threads column min (210) + a comfortable conversation min
        // (~350), letting the whole app reflow down to the window floor cleanly.
        // In a pane the threads column is folded, so the floor is the
        // conversation alone.
        .frame(minWidth: hostedInPane ? Self.paneMinWidth : 560, minHeight: 520)
        .onChange(of: state.offlineMode) { _, _ in readiness = ChatReadiness.current() }
        .onAppear {
            readiness = ChatReadiness.current()
            inputFocused = true
            // Consume a prompt staged by the Meta Ads "Send to Claude" button if
            // it was set before this tab appeared. Pre-fill only, never auto-send.
            if let p = state.pendingChatPrompt, !p.isEmpty {
                draft = draft.isEmpty ? p : draft + "\n\n" + p
                inputFocused = true
                state.pendingChatPrompt = nil
            }
            // Price the pending context once on appear so the composer's cost
            // line is present on a fresh session BEFORE the first send (it used
            // to only publish inside send(), so a new session showed just the
            // model chip until the user had sent at least once).
            ChatService.shared.refreshChatEstimate()
        }
        .onChange(of: draft) { _, _ in
            // Debounce ~600ms: re-price the pending send after the user pauses
            // typing rather than on every keystroke.
            estimateDebounce?.cancel()
            estimateDebounce = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard !Task.isCancelled else { return }
                ChatService.shared.refreshChatEstimate()
            }
        }
        .onChange(of: state.pendingChatPrompt) { _, new in
            guard let p = new, !p.isEmpty else { return }
            draft = draft.isEmpty ? p : draft + "\n\n" + p
            inputFocused = true
            state.pendingChatPrompt = nil
        }
        .onChange(of: voice.transcript) { _, new in
            let cleaned = new.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return }
            draft = draftBeforeVoice.isEmpty ? cleaned : "\(draftBeforeVoice) \(cleaned)"
        }
        .onChange(of: voice.autoSendRequested) { _, req in
            guard req else { return }
            voice.autoSendRequested = false
            let t = voice.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                draft = draftBeforeVoice.isEmpty ? t : "\(draftBeforeVoice) \(t)"
            }
            send()
        }
        .onReceive(NotificationCenter.default.publisher(for: .gruxWakeDetected)) { _ in
            draftBeforeVoice = ""
            draft = ""
            inputFocused = true
        }
    }

    // MARK: - Hero

    // A faint iridescent hairline used to separate the themed strips instead of
    // the stock macOS Divider, so the seams read as part of the glass HUD.
    private var themedHairline: some View {
        Rectangle()
            .fill(GruxTheme.iridescentRim.opacity(0.35))
            .frame(height: 1)
    }

    // Chat-tab sub-header. The orb + GRUX + status pill moved to the sidebar
    // (which is always visible across tabs); duplicating them here just
    // doubled the visual weight. This header now focuses on chat-specific
    // context: current task + wake/TTS indicators + clear button.
    /// The thread a person is actually in. Falls back to the same neutral
    /// default the store uses, so the header and the rail never disagree
    /// about what an untitled thread is called.
    private var activeThreadTitle: String {
        guard let id = state.activeThreadId,
              let entry = state.threads.first(where: { $0.id == id }),
              !entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return ChatTitleHygiene.neutralDefault }
        return entry.title
    }

    private var heroHeader: some View {
        VStack(alignment: .leading, spacing: GruxSpacing.s) {
            HStack(alignment: .center, spacing: GruxSpacing.m) {
                if hostedInPane {
                    Button { threadsPopover.toggle() } label: {
                        Image(systemName: "sidebar.left").font(GruxType.caption)
                    }
                    .buttonStyle(.plain)
                    .help("Threads")
                    .accessibilityLabel("Threads")
                    .popover(isPresented: $threadsPopover, arrowEdge: .bottom) {
                        ChatThreadsSidebar().environmentObject(state)
                            .frame(width: GruxLayout.listColumnIdeal, height: Self.threadsPopoverHeight)
                    }
                    // A pick of an existing thread closes the folded list;
                    // "+" and a delete keep it open (R7.4).
                    .onChange(of: ThreadsSnapshot(active: state.activeThreadId, ids: state.threads.map(\.id))) { old, new in
                        if Self.pickClosesThreads(from: old, to: new) { threadsPopover = false }
                    }
                }
            // WAS the current task and its empty state, on the tab whose job
            // is the conversation. The task stack has its own tab, and a
            // person reading Chat wants to know which thread they are in.
            VStack(alignment: .leading, spacing: GruxSpacing.xs + 2) {
                Text(activeThreadTitle)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(GruxTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()
            presetMenu
            muteVoiceButton
            Button { state.clearChat() } label: {
                Label("Clear", systemImage: "trash")
                    .labelStyle(.iconOnly)
                    .font(.callout)
                    .foregroundStyle(GruxTheme.textSecondary)
                    .padding(GruxSpacing.s)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.05))
                            .overlay(Circle().strokeBorder(Color.white.opacity(0.10), lineWidth: 0.8))
                    )
            }.buttonStyle(.plain).help("Clear chat")
            }
            // The status pills get their OWN row rather than sharing the title
            // block. Nested in that VStack they were competing with a long,
            // truncating task title AND with the Spacer beside it for the same
            // horizontal budget, and at the 840pt window floor they lost: both
            // chips rendered as two letters and an ellipsis. Neither lineLimit,
            // minimumScaleFactor nor layoutPriority fixed that, because the
            // constraint was the width the block was handed, not how its
            // contents were drawn. On their own line they have the full pane
            // and simply fit. Two short status chips also read better under
            // the title than jammed beside it.
            HStack(spacing: GruxSpacing.m) {
                listeningIndicator
                speakIndicator
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, GruxSpacing.xl).padding(.vertical, GruxSpacing.m)
    }

    // Chat preset picker (Item 22). Applying a preset overrides the system
    // prompt, model, and tool surface for every send() until cleared. The
    // icon tints when a preset is active so the override is never invisible.
    private var presetMenu: some View {
        Menu {
            // An ACTION, not an inert line. A menu that opens to the words
            // "No chat presets yet" and nothing else is a dead end inside a
            // dead end: the reader learns presets exist, is told they have
            // none, and is given no way to make one or find out what one is.
            if presets.presets(kind: .chat).isEmpty {
                Button("No presets yet. Create one in Settings...") {
                    state.requestedSettingsTab = "presets"
                    state.requestedTab = "settings"
                }
            }
            ForEach(presets.presets(kind: .chat)) { p in
                Button {
                    presets.setActiveChat(id: presets.activeChatPresetId == p.id ? nil : p.id)
                } label: {
                    if presets.activeChatPresetId == p.id {
                        Label(p.name, systemImage: "checkmark")
                    } else { Text(p.name) }
                }
            }
            if presets.activeChatPresetId != nil {
                Divider()
                Button("Clear preset") { presets.setActiveChat(id: nil) }
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.callout)
                .foregroundStyle(presets.activeChatPresetId != nil ? GruxTheme.accentPrimaryLight : GruxTheme.textSecondary)
                .padding(GruxSpacing.s)
                .background(
                    Circle()
                        .fill(Color.white.opacity(0.05))
                        .overlay(Circle().strokeBorder(
                            presets.activeChatPresetId != nil ? GruxTheme.accentPrimary.opacity(0.45) : Color.white.opacity(0.10),
                            lineWidth: 0.8))
                )
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(presets.activeChatPresetId != nil ? "Chat preset active" : "Apply a chat preset")
    }

    // Session-level chat-voice mute toggle. Flipping ON also cancels any
    // in-flight TTS so Grux falls silent immediately instead of finishing
    // the sentence he's currently mid-speaking. State lives on AppState and
    // is intentionally not persisted across relaunches - the permanent
    // "speak replies aloud" toggle lives in Tuning.
    private var muteVoiceButton: some View {
        Button {
            let willMute = !state.voiceMuted
            state.voiceMuted = willMute
            if willMute {
                // Cut any in-flight ElevenLabs streaming / system TTS and drop
                // any queued polite-nudge so muting is truly instant.
                speech.stop(reason: "user voice-mute toggle")
                speech.cancelPendingPoliteSpeak()
            }
        } label: {
            Image(systemName: state.voiceMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.callout)
                .foregroundStyle(state.voiceMuted ? GruxTheme.destructiveRose : GruxTheme.textSecondary)
                .padding(GruxSpacing.s)
                .background(
                    Circle().fill(
                        state.voiceMuted ?
                        AnyShapeStyle(GruxTheme.destructiveRose.opacity(0.16)) :
                        AnyShapeStyle(Color.white.opacity(0.05))
                    )
                )
                .overlay(
                    Circle().strokeBorder(
                        state.voiceMuted ? GruxTheme.destructiveRose.opacity(0.45) : Color.white.opacity(0.10),
                        lineWidth: 0.8
                    )
                )
                .symbolEffect(.bounce, value: state.voiceMuted)
        }
        .buttonStyle(.plain)
        .help(state.voiceMuted ? "Unmute Grux's voice" : "Mute Grux's voice (chat only)")
    }

    /// WAS the wake chip, which read the wake listener and therefore reported
    /// the wake word as off while always-on listening held the microphone. It
    /// is now the shared tell, so this chip and the orb cannot disagree.
    private var listeningIndicator: some View {
        statusPill(
            icon: listeningTell == .off ? "waveform.slash" : "waveform",
            label: listeningTell.label,
            accent: listeningTell == .off || listeningTell == .muted
                ? GruxTheme.textTertiary
                : GruxTheme.successMint
        )
        .help(listeningTell.help)
    }

    /// WAS the TTS vendor, which is a supplier rather than a state. The chip
    /// now says what Grux's voice is DOING; the vendor still shows, one size
    /// smaller, behind the shared glyph.
    private var speakIndicator: some View {
        HStack(spacing: GruxSpacing.xs) {
            statusPill(icon: voiceState.icon, label: voiceState.label, accent: voiceState.accent)
            VendorGlyph(vendor: state.config.useElevenLabs ? "ElevenLabs" : "macOS")
        }
    }

    private var voiceState: VoiceStateChip {
        VoiceStateChip.resolve(speakRepliesAloud: state.config.speakRepliesAloud,
                               muted: state.voiceMuted,
                               isSpeaking: speech.isSpeaking || speech.isBuffering)
    }

    // Themed status pill used by the wake + TTS indicators: a tinted icon next
    // to a microCaps label on a faint glass chip.
    private func statusPill(icon: String, label: String, accent: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(accent)
            Text(label)
                .font(GruxTheme.Font.microCaps)
                .kerning(1.0)
                .foregroundStyle(GruxTheme.textSecondary)
                // At the 840pt window floor this header wrapped both status
                // chips one or two characters per line (the listening word
                // down one column, the voice vendor down another) on the
                // app's default landing tab. lineLimit alone fixes that: the
                // label truncates instead of wrapping.
                //
                // ...but lineLimit alone let it truncate all the way to a single
                // character: this header also carries a truncating task title
                // and three icon buttons, and when the title happened to be
                // short the pills lost instead, rendering "W..." and "E...".
                // minimumScaleFactor shrinks the type before the ellipsis takes
                // over, which keeps both labels legible at the floor. Scaling
                // does NOT raise the view's minimum width the way fixedSize
                // does, so it costs the nav rail nothing.
                .minimumScaleFactor(0.75)
                //
                // Deliberately NOT fixedSize here, unlike GruxChip. Measured:
                // adding it made this header rigid, which raised ChatView's
                // minimum past the 599pt pane and stole 46pt from the nav rail
                // (240pt to 194pt), so the fix for a wrapped label became a
                // clipped sidebar. A pill that truncates is the correct trade
                // in a header this dense.
                .lineLimit(1)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(
            Capsule().fill(Color.white.opacity(0.04))
                .overlay(Capsule().strokeBorder(accent.opacity(0.25), lineWidth: 0.6))
        )
    }

    // MARK: - Messages

    /// Whether the Latest chip is up over the transcript in `scroll`: the
    /// chip's own state (what the view draws from), for tests; nil when no
    /// Chat transcript owns that scroll view. Per scroll view, never a global
    /// another Chat alive in the process could change.
    @MainActor static func latestChipShown(in scroll: NSScrollView) -> Bool? {
        ChatFollow.byScrollView.object(forKey: scroll)?.chipUp
    }

    // MARK: - Driving Chat from outside the view

    /// What `perform` can do to a transcript: what the Show earlier row, the
    /// Latest chip and a person's scroll do.
    enum Control: Equatable {
        case showEarlier
        case latest
        /// A person's scroll by this many points; negative is up.
        case scroll(CGFloat)
    }

    /// Posted with a transcript's scroll view and `control` in its user info;
    /// the view runs the same function its row or chip runs.
    static let controlRequest = Notification.Name("grux.chat.control")

    /// The transcript `perform` and `status` act on when not given one: the
    /// Chat most recently put in a window.
    @MainActor static var liveTranscript: NSScrollView? {
        if let scroll = ChatFollow.live?.scrollView, scroll.window != nil { return scroll }
        // The most recent Chat left its window: any other still in one.
        return ChatFollow.byScrollView.keyEnumerator().allObjects
            .compactMap { $0 as? NSScrollView }.first { $0.window != nil }
    }

    /// Does `control` to the transcript in `scroll` (the live one when nil).
    /// False when there is no Chat transcript to act on.
    @MainActor @discardableResult
    static func perform(_ control: Control, in scroll: NSScrollView? = nil) -> Bool {
        guard let scroll = scroll ?? liveTranscript,
              let follow = ChatFollow.byScrollView.object(forKey: scroll) else { return false }
        switch control {
        case .showEarlier:
            NotificationCenter.default.post(name: controlRequest, object: scroll, userInfo: ["control": "show-earlier"])
        case .latest:
            NotificationCenter.default.post(name: controlRequest, object: scroll, userInfo: ["control": "latest"])
        case .scroll(let points):
            follow.scrollAsPerson(by: points)
        }
        return true
    }

    /// Whether the transcript has stopped moving: no scroll Chat started is
    /// running, the person is not scrolling, and nothing moved for 0.3 s.
    @MainActor static func isSettled(_ scroll: NSScrollView? = nil) -> Bool {
        guard let scroll = scroll ?? liveTranscript,
              let follow = ChatFollow.byScrollView.object(forKey: scroll) else { return true }
        return follow.isSettled
    }

    /// What `chat-status.json` says about the transcript in `scroll` (the
    /// live one when nil).
    @MainActor static func status(of scroll: NSScrollView? = nil) -> [String: Any] {
        let total = AppState.shared.chat.count
        guard let scroll = scroll ?? liveTranscript,
              let follow = ChatFollow.byScrollView.object(forKey: scroll) else {
            return ["chatOpen": false, "totalMessages": total]
        }
        let clip = scroll.contentView.bounds
        let docHeight = scroll.documentView?.frame.height ?? 0
        var out: [String: Any] = [
            "chatOpen": true,
            "totalMessages": total,
            "shownCount": min(follow.shownCount, total),
            "followsLatest": follow.latest,
            "latestChipUp": follow.chipUp,
            "scrollOffset": Double(clip.minY),
            "scrollMax": Double(max(0, docHeight - clip.height)),
            "transcriptWidth": Double(scroll.frame.width),
        ]
        out["topVisibleMessageId"] = follow.topVisibleMessage?.uuidString ?? NSNull()
        return out
    }

    /// Whether the transcript in `scroll` follows the newest message, for
    /// tests; nil when no Chat transcript owns that scroll view. Per scroll
    /// view, never a global another Chat alive in the process could change.
    @MainActor static func followsLatest(in scroll: NSScrollView) -> Bool? {
        ChatFollow.byScrollView.object(forKey: scroll)?.latest
    }

    /// How many of the newest messages the transcript lays out at first, and
    /// how many more each "Show earlier" adds.
    static let transcriptPage = 16

    /// The part of `chat` the transcript lays out when `shown` messages are
    /// asked for, and how many earlier ones stay behind "Show earlier".
    static func transcriptWindow(_ chat: [ChatMessage], shown: Int) -> (earlier: Int, messages: ArraySlice<ChatMessage>) {
        let count = min(max(shown, 0), chat.count)
        return (chat.count - count, chat.suffix(count))
    }

    /// The "Show earlier" row's words for `earlier` messages behind it.
    static func showEarlierLabel(earlier: Int) -> String {
        let next = min(earlier, transcriptPage)
        return next == 1 ? "Show 1 earlier message" : "Show \(next) earlier messages"
    }

    /// "Show earlier": a page more above, keeping the message that was at
    /// the top where the person is reading, rather than jumping.
    private func showEarlier(_ proxy: ScrollViewProxy) {
        let window = Self.transcriptWindow(state.chat, shown: shownCount)
        guard window.earlier > 0 else { return }
        follow.keepTopMessageWhileShowingEarlier()
        shownCount += Self.transcriptPage
    }

    /// The Latest chip: back to the newest message, following it again.
    private func jumpToLatest(_ proxy: ScrollViewProxy) {
        follow.scrollToEnd(animated: true)
    }

    /// The transcript's viewport changed size: back to the newest message if
    /// the transcript follows it. Twice, because a lazy list places rows it
    /// has only estimated on the first pass and corrects them on the next.
    ///
    /// Through the transcript's NSScrollView, not ScrollViewProxy: a proxy
    /// scroll is reapplied at SwiftUI's next layout, so one issued during a
    /// resize took back a scroll-up the person made just after it.
    private func viewportChanged(_ proxy: ScrollViewProxy) {
        guard follow.latest, !state.chat.isEmpty else { return }
        let follow = follow
        DispatchQueue.main.async {
            follow.showBottomIfFollowing()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { follow.showBottomIfFollowing() }
        }
    }

    private var messagesScroll: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    // A plain VStack, not LazyVStack. SWEEP-11: with rows of
                    // very different heights (long multi-paragraph workflow
                    // questions among one-line replies), the lazy stack placed
                    // rows it had only estimated, and the bottom-anchored view
                    // landed where no row was drawn: an empty transcript. A
                    // thread is short enough to lay out whole (auto-compact
                    // keeps it so), and exact heights keep the anchor true.
                    VStack(alignment: .leading, spacing: GruxSpacing.l) {
                        if state.chat.isEmpty {
                            emptyState
                        }
                        // A run of the same notice is one row. Measured
                        // 2026-09-20: six failed turns in one thread put six
                        // identical red bubbles in the transcript and pushed
                        // the conversation off the screen.
                        let window = Self.transcriptWindow(state.chat, shown: shownCount)
                        if window.earlier > 0 {
                            Button { showEarlier(proxy) } label: {
                                Text(Self.showEarlierLabel(earlier: window.earlier))
                                    .font(GruxType.caption)
                                    .foregroundStyle(GruxTheme.textSecondary)
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderless)
                        }
                        ForEach(ErrorBubbleGrouping.group(Array(window.messages))) { row in
                            switch row {
                            case .message(let m):
                                MessageBubble(message: m).id(m.id)
                                    .background(TranscriptRowFrame(id: m.id))
                            case .repeatedNotice(let m, let count):
                                MessageBubble(message: m)
                                    .id(m.id)
                                    .background(TranscriptRowFrame(id: m.id))
                                    .overlay(alignment: .topTrailing) {
                                        if count > 1 {
                                            Text(ErrorBubbleGrouping.repeatLabel(count: count))
                                                .font(GruxTheme.Font.microCaps)
                                                .foregroundStyle(GruxTheme.textTertiary)
                                                .padding(.horizontal, GruxSpacing.s)
                                        }
                                    }
                            }
                        }
                        if state.isThinking {
                            thinkingBubble
                        }
                        // Invisible sentinel pinned to the bottom of the
                        // scroll content. Where it sits in the visible area
                        // sets `isAtBottom`, so the floating jump chip knows
                        // when to fade in. Its position, not onAppear: a plain
                        // VStack builds every row once, so appear and
                        // disappear say nothing about what is on screen.
                        Color.clear
                            .frame(height: 1)
                            .id("grux.chat.bottom-sentinel")
                    }
                    .padding(.horizontal, GruxSpacing.xl).padding(.vertical, GruxSpacing.l)
                    // Where each message sits in the transcript, for the top
                    // visible message in chat-status.json. Changes on layout
                    // only, never on scrolling.
                    .coordinateSpace(name: TranscriptRowFrame.space)
                    .onPreferenceChange(TranscriptRowFrame.Key.self) { follow.rowFrames = $0 }
                    // Where the person scrolls to, from their own input only.
                    .background(TranscriptScrollIntent(follow: follow, atBottom: $isAtBottom))
                }
                // Opens on the newest message. Without it a long thread opened
                // at its first message, hours old, with no Latest chip. The
                // first layout only: on macOS 15 and later the plain modifier
                // also re-anchors every size change to the bottom, which took
                // a person who had scrolled up back down on the next resize.
                // Size changes re-anchor below, and only while following.
                .opensAtBottom()
                // The anchor only places the first layout. SWEEP-11: the
                // transcript's size changes after that (the pane opening
                // narrow and growing re-wraps every long line; the model
                // notice under it settling late), and the offset was left
                // mid-thread, or past the end of the content with nothing
                // drawn and the Latest chip up. While the transcript follows
                // the newest message, every size change puts it back.
                .background(GeometryReader { viewport in
                    Color.clear
                        .onAppear { viewportChanged(proxy) }
                        .onChange(of: viewport.size) { _, _ in viewportChanged(proxy) }
                })
                // The thinking bubble grows the transcript at the bottom; while
                // following, keep the bottom (with the bubble) in view.
                .onChange(of: state.isThinking) { _, _ in
                    let follow = follow
                    DispatchQueue.main.async { follow.showBottomIfFollowing() }
                }
                // The Show earlier row and the Latest chip, asked for from
                // outside the view (ChatView.perform: the chat triggers, and
                // tests, which cannot click offscreen). The same functions the
                // row and the chip call.
                .onReceive(NotificationCenter.default.publisher(for: Self.controlRequest)) { note in
                    guard let scroll = note.object as? NSScrollView, scroll === follow.scrollView,
                          let control = note.userInfo?["control"] as? String else { return }
                    switch control {
                    case "show-earlier": showEarlier(proxy)
                    case "latest": jumpToLatest(proxy)
                    default: break
                    }
                }
                .onChange(of: shownCount) { _, now in follow.shownCount = now }
                // Another thread opens on its newest message, not at the place
                // held in the one before.
                .onChange(of: state.activeThreadId) { _, _ in
                    shownCount = Self.transcriptPage
                    follow.latest = true
                    let follow = follow
                    DispatchQueue.main.async { follow.showBottomIfFollowing() }
                }
                .onChange(of: state.chat.count) { _, _ in
                    guard !state.chat.isEmpty else { follow.latest = true; return }
                    follow.scrollToEnd(animated: true)
                }
                // The live rail appearing shrinks this scroll view. Without
                // this the last message slides under it and the conversation
                // looks truncated. Someone who scrolled up to read history is
                // left where they are; the Latest chip is already there for
                // them.
                .onChange(of: railRowCount) { _, _ in
                    guard isAtBottom, !state.chat.isEmpty else { return }
                    follow.scrollToEnd(animated: true)
                }

                if !isAtBottom && !state.chat.isEmpty {
                    Button { jumpToLatest(proxy) } label: {
                        HStack(spacing: GruxSpacing.xs + 2) {
                            Image(systemName: "arrow.down")
                                .font(.caption.weight(.bold))
                            Text("Latest")
                                .font(.caption.weight(.semibold))
                                .kerning(0.5)
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, GruxSpacing.m).padding(.vertical, GruxSpacing.s)
                        .background(
                            Capsule().fill(GruxTheme.iridescent)
                        )
                        .shadow(color: GruxTheme.violetGlow(), radius: 8, y: 2)
                    }
                    .buttonStyle(.plain)
                    .help("Jump to latest message")
                    .padding(.trailing, GruxSpacing.xl).padding(.bottom, GruxSpacing.m)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .animation(.easeOut(duration: 0.25), value: isAtBottom)
        }
    }

    /// Nothing to work with yet: no tasks, and no earlier conversation.
    ///
    /// Deliberately NOT "has never launched". Somebody who cleared their history
    /// is in the same position as a fresh install as far as what Grux can
    /// usefully offer them, and a flag that only fires once would leave them
    /// looking at suggestions that cannot work.
    private var chatIsFirstRun: Bool {
        // activeTasks, NOT tasks. `tasks` is the raw array and includes
        // completed ones, while the model is handed `state.activeTasks` and sees
        // "(empty)". Somebody who finished everything they had would therefore
        // read as "not first run, and has a stack", get offered "Roast my task
        // stack", and get the shrug this whole change exists to prevent.
        // TasksDetailView got this right in the same range by using
        // topLevelActiveTasks; this did not.
        state.activeTasks.isEmpty
            && ChatThreadStore.shared.list().allSatisfy { $0.messageCount == 0 }
    }

    private var emptyState: some View {
        ChatEmptyState(isFirstRun: chatIsFirstRun,
                       hasTasks: !state.activeTasks.isEmpty,
                       // THE LIVE LISTENER, not `config.wakeWordEnabled`. The
                       // preference is only what the user asked for; ambient
                       // mode and a muted mic both stop the listener while
                       // leaving it true, and this line promised a wake word
                       // that could not hear anything.
                       wakeWordOn: wake.isListening) { text in
            draft = text
            send()
        }
    }

    private var thinkingBubble: some View {
        HStack(spacing: GruxSpacing.m) {
            Circle().fill(GruxTheme.accentCo).frame(width: 6, height: 6)
                .scaleEffect(1.2)
                .shadow(color: GruxTheme.accentCo.opacity(0.6), radius: 4)
            Text("grux is thinking…")
                .font(.caption)
                .foregroundStyle(GruxTheme.textSecondary)
            Spacer()
        }
    }

    // MARK: - Input

    private var liveVoiceStrip: some View {
        HStack(spacing: GruxSpacing.m) {
            Circle()
                .fill(voice.isTranscribing ? Color.yellow : Color.red)
                .frame(width: 8, height: 8)
                .overlay(
                    Circle().stroke(
                        (voice.isTranscribing ? Color.yellow : Color.red).opacity(0.4),
                        lineWidth: 2
                    ).scaleEffect(1.0 + CGFloat(voice.liveLevel) * 1.8)
                )
            Text(voice.isTranscribing ? "TRANSCRIBING" : "LISTENING")
                .font(GruxTheme.Font.microCaps)
                .foregroundStyle(GruxTheme.textSecondary)
                .kerning(1.5)
            WaveformBar(level: voice.liveLevel)
                .frame(height: 18)
            Spacer()
            if !voice.transcript.isEmpty {
                Text(voice.transcript).font(.caption).foregroundStyle(GruxTheme.textPrimary).lineLimit(1)
            }
            Button(voice.isRecording ? "Stop" : "Cancel") {
                voice.stop()
            }.buttonStyle(.borderless).font(.caption).tint(GruxTheme.accentPrimaryLight)
        }
        .padding(.horizontal, GruxSpacing.l).padding(.vertical, GruxSpacing.s)
        .background(
            LinearGradient(
                colors: [GruxTheme.destructiveRose.opacity(0.12), GruxTheme.accentPrimary.opacity(0.08)],
                startPoint: .leading, endPoint: .trailing
            )
        )
    }

    private func errorStrip(_ err: String) -> some View {
        HStack(spacing: GruxSpacing.s) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(GruxTheme.warnAmber)
            Text(err).font(.caption).foregroundStyle(GruxTheme.warnAmber).lineLimit(3)
            Spacer()
            if voice.needsMicSettings {
                Button("Open Settings") { VoiceInput.openMicSettings() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            } else if voice.needsSpeechSettings {
                Button("Open Settings") { VoiceInput.openSpeechSettings() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            }
            Button("Dismiss") { voice.error = nil; voice.needsMicSettings = false; voice.needsSpeechSettings = false }
                .buttonStyle(.borderless).font(.caption2).tint(GruxTheme.textSecondary)
        }
        .padding(.horizontal, GruxSpacing.l).padding(.vertical, GruxSpacing.s)
        .background(GruxTheme.warnAmber.opacity(0.10))
    }

    /// Mirrored, never read in `body`. `AppState.anthropicKey` is a Keychain
    /// hit on every access, and a computed property here would fire it on every
    /// keystroke in the composer. Refreshed on appear and whenever offline mode
    /// flips, which are the two moments the answer can change under the user.
    @State private var readiness: ChatReadiness = .ready

    /// Extracted so it can be RENDERED. A view that reads `ChatReadiness.current()`
    /// can only ever be photographed in whatever state the machine happens to be
    /// in, and this one is developed on a machine that has a key, so the not-ready
    /// layout would never be looked at. Taking the state as input is the same
    /// reason `ChatReadiness.evaluate` is split from `current()`.
    @ViewBuilder private var readinessNotice: some View {
        ChatReadinessNotice(readiness: readiness) {
            // "api", not "models". The latter resolves to the pane with no
            // anchor and opens the top of a long screen; "api" resolves to
            // anchor "models.api", the Anthropic key field itself. A "go to
            // Settings" sentence that lands somewhere near the answer is a
            // scavenger hunt.
            AppState.shared.requestedSettingsTab = "api"
            AppState.shared.requestedTab = "settings"
        }
    }

    private var inputBar: some View {
        VStack(spacing: 0) {
            themedHairline
            readinessNotice
            if pendingImagePreview != nil || attachmentError != nil {
                attachmentStrip
            }
            if skillsOpen {
                skillsTray
            }
            VStack(alignment: .leading, spacing: GruxSpacing.xs + 2) {
            HStack(alignment: .bottom, spacing: GruxSpacing.m) {
                draftEditor

                Button { toggleVoice() } label: {
                    ZStack {
                        Circle()
                            .fill(
                                voice.isRecording ?
                                AnyShapeStyle(LinearGradient(colors: [GruxTheme.destructiveRose, GruxTheme.accentPrimary], startPoint: .topLeading, endPoint: .bottomTrailing)) :
                                AnyShapeStyle(Color.white.opacity(0.05))
                            )
                            .frame(width: 40, height: 40)
                            .overlay(
                                Circle().strokeBorder(
                                    voice.isRecording ? Color.clear : Color.white.opacity(0.10),
                                    lineWidth: 0.8
                                )
                            )
                            .shadow(color: voice.isRecording ? GruxTheme.destructiveRose.opacity(0.5) : .clear, radius: 6)
                        Image(systemName: voice.isRecording ? "mic.fill" : "mic")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(voice.isRecording ? Color.white : GruxTheme.accentPrimary)
                            .symbolEffect(.pulse, options: .repeating,
                                           isActive: voice.isRecording && !GruxTheme.reduceMotion)
                    }
                }.buttonStyle(.plain).help(voice.isRecording ? "Stop listening" : "Dictate")

                Button { send() } label: {
                    ZStack {
                        Circle()
                            .fill(GruxTheme.iridescent)
                            .frame(width: 40, height: 40)
                            .shadow(color: GruxTheme.violetGlow(strong: true), radius: 6)
                        Image(systemName: "arrow.up")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }.buttonStyle(.plain)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || !readiness.canSend)
                    .opacity(draft.trimmingCharacters(in: .whitespaces).isEmpty || !readiness.canSend ? 0.4 : 1)
                    .help(readiness.canSend ? "Send" : readiness.headline)
            }
                composerMetaRow
            }
            .padding(.horizontal, GruxSpacing.l).padding(.vertical, GruxSpacing.m)
        }
        // `.behindWindow` samples what is BEHIND the app, which means the
        // composer's colour depended on the user's desktop. Measured
        // 2026-09-20 over a light background: the composer rendered as a pale
        // grey slab against the dark app, on the landing tab. `.withinWindow`
        // samples the chat backdrop instead, so the composer is the same
        // colour wherever the window happens to be sitting.
        .background(
            ZStack {
                VisualEffectBackdrop(material: .hudWindow, blendingMode: .withinWindow)
                Color.black.opacity(0.25)
            }
        )
        // The `skills` tab arrives here as Chat with Skills open.
        .onAppear { if opensSkills { skillsOpen = true } }
        .onChange(of: opensSkills) { _, open in if open { skillsOpen = true } }
    }

    private var backdrop: some View {
        ZStack {
            GruxTheme.base
            LinearGradient(
                colors: [
                    GruxTheme.accentPrimary.opacity(0.06),
                    Color.clear,
                    GruxTheme.accentCo.opacity(0.04)
                ],
                startPoint: .top, endPoint: .bottom
            )
        }.ignoresSafeArea()
    }

    // Broken out of inputBar so the SwiftUI type-checker can resolve the view
    // tree in reasonable time - the full chain of background+overlay+focus+
    // onKeyPress+onDrop was tripping "unable to type-check in reasonable
    // time" when inlined.
    private var draftEditor: some View {
        TextEditor(text: $draft)
            .overlay(alignment: .topLeading) {
                // A TextEditor has no placeholder of its own. This is the one
                // line that tells a person the new thing about 3.0, so it is
                // honest about the microphone: inviting speech from a Mac
                // that is not listening is a lie.
                if draft.isEmpty {
                    Text(ComposerPlaceholder.text(for: listeningTell))
                        .font(.body)
                        .foregroundStyle(GruxTheme.textTertiary)
                        .padding(.horizontal, GruxSpacing.m + 4)
                        .padding(.vertical, GruxSpacing.s + 8)
                        .allowsHitTesting(false)
                }
            }
            .font(.body)
            .foregroundStyle(GruxTheme.textPrimary)
            .tint(GruxTheme.accentPrimary)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 40, maxHeight: 160)
            .padding(.horizontal, GruxSpacing.m).padding(.vertical, GruxSpacing.s)
            .background(draftEditorBackground)
            .focused($inputFocused)
            // Enter submits; Shift+Enter falls through to TextEditor's
            // native newline handling. Returning .ignored for the shifted
            // case is important - it lets SwiftUI insert the newline into
            // the text binding as normal.
            .onKeyPress(keys: [.return], phases: .down) { press in
                if press.modifiers.contains(.shift) {
                    return .ignored
                }
                send()
                return .handled
            }
            // Accept image drops anywhere over the text editor. The handler
            // runs off-main inside NSItemProvider, so it hops back to
            // MainActor to write the @State.
            .onDrop(of: Self.acceptedDropTypes, isTargeted: $dropTargeted) { providers in
                handleDrop(providers: providers)
            }
    }

    private static let acceptedDropTypes = ImageIngest.acceptedDropTypes

    private var draftEditorBorderColor: Color {
        if dropTargeted { return GruxTheme.accentCo.opacity(0.85) }
        if voice.isRecording { return GruxTheme.destructiveRose.opacity(0.6) }
        if inputFocused { return GruxTheme.accentPrimary.opacity(0.7) }
        return GruxTheme.textTertiary.opacity(0.25)
    }

    private var draftEditorBackground: some View {
        RoundedRectangle(cornerRadius: GruxTheme.Radius.chip, style: .continuous)
            .fill(Color.black.opacity(0.28))
            .overlay(
                RoundedRectangle(cornerRadius: GruxTheme.Radius.chip, style: .continuous)
                    .strokeBorder(draftEditorBorderColor, lineWidth: dropTargeted ? 2 : 1)
            )
            .overlay(
                // Subtle accent focus ring, matching the SettingsView field chrome.
                RoundedRectangle(cornerRadius: GruxTheme.Radius.chip, style: .continuous)
                    .strokeBorder(GruxTheme.accentPrimary.opacity(inputFocused && !dropTargeted && !voice.isRecording ? 0.18 : 0), lineWidth: 3)
            )
    }

    // Inline thumbnail + clear/dismiss controls for whatever image is staged
    // for the next send. Also doubles as the surface for drop errors (bad
    // type, decode failure) so the user always sees WHY the drop did or
    // didn't stick.
    private var attachmentStrip: some View {
        HStack(spacing: GruxSpacing.m) {
            if let preview = pendingImagePreview {
                Image(nsImage: preview)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(GruxTheme.accentCo.opacity(0.5), lineWidth: 1)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text("Image ready to send")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(GruxTheme.textPrimary)
                    if let mt = pendingImageMediaType, let bytes = pendingImageData?.count {
                        Text("\(mt) · \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))")
                            .font(.caption2).foregroundStyle(GruxTheme.textSecondary)
                    }
                }
                Spacer()
                Button {
                    pendingImageData = nil
                    pendingImageMediaType = nil
                    pendingImagePreview = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(GruxTheme.textSecondary)
                }.buttonStyle(.plain).help("Remove image")
            } else if let err = attachmentError {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(GruxTheme.warnAmber)
                Text(err).font(.caption).foregroundStyle(GruxTheme.warnAmber).lineLimit(2)
                Spacer()
                Button {
                    attachmentError = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(GruxTheme.textSecondary)
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, GruxSpacing.l).padding(.vertical, GruxSpacing.s)
        .background(GruxTheme.accentCo.opacity(0.07))
    }

    // The drop rules (NSImage first, then file URLs) live in ImageIngest,
    // shared with the Optimize card's Change it box. Chat attaches one.
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        attachmentError = nil
        let took = ImageIngest.load(providers) { result in
            switch result {
            case .success(let image): self.ingestNSImage(image)
            case .failure(let failure): self.attachmentError = failure.message
            }
        }
        if !took { attachmentError = "That doesn't look like an image I can attach." }
        return took
    }

    // Re-encoded to PNG by ImageIngest, so the Anthropic API gets a format it
    // accepts whatever the source was.
    private func ingestNSImage(_ image: NSImage) {
        guard let png = ImageIngest.png(from: image) else {
            attachmentError = ImageIngest.cannotEncode
            return
        }
        pendingImageData = png
        pendingImageMediaType = "image/png"
        pendingImagePreview = image
        attachmentError = nil
    }

    private func toggleVoice() {
        if voice.isRecording {
            voice.stop()
        } else {
            // If Grux is currently speaking, interrupt it (user barge-in via button).
            if speech.isSpeaking || speech.isBuffering {
                speech.stop(reason: "manual barge-in")
            }
            draftBeforeVoice = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            Task { await voice.start() }
        }
    }

    // Actionable recovery banner above the composer. Interactive chat used to
    // dead-end on any error with a bare "⚠️" bubble; this gives the same rich
    // recovery the swarm path has (account switch / snooze) plus a Continue-
    // offline path, classified by ChatService.classifyChatFailure.
    @ViewBuilder
    private func recoveryBanner(_ recovery: ChatRecovery) -> some View {
        HStack(alignment: .top, spacing: GruxSpacing.m) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.callout)
            VStack(alignment: .leading, spacing: GruxSpacing.s) {
                Text(recovery.message)
                    .font(GruxType.body)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: GruxSpacing.s) {
                    switch recovery.kind {
                    case .limitHit:
                        // Only actions that can change the credential CHAT spends.
                        // "Switch account & retry" used to live here: it ran
                        // `claude auth logout` on the agent CLI, could not touch
                        // the API key this turn would reuse, and signed the user
                        // out of a working terminal session to fix a chat error.
                        Button("Open key settings") { openKeySettings() }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                        if ModelRegistry.shared.local != nil {
                            Button("Use local model") { continueOfflineAndRetry(recovery) }
                                .buttonStyle(.bordered).controlSize(.small)
                        }
                        Button("Snooze") { snoozeChat() }
                            .buttonStyle(.bordered).controlSize(.small)
                    case .network:
                        Button("Continue offline") { continueOfflineAndRetry(recovery) }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                    case .offlineNoModel:
                        Button("Discover local models") { discoverLocalModels() }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                    case .generic:
                        EmptyView()
                    }
                    Button("Retry") { retryRecovery(recovery) }
                        .buttonStyle(.bordered).controlSize(.small)
                    Button("Dismiss") { state.chatRecovery = nil }
                        .buttonStyle(.borderless).controlSize(.small)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, GruxSpacing.m).padding(.vertical, GruxSpacing.m)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.30), lineWidth: 1))
        .padding(.horizontal, GruxSpacing.xl).padding(.bottom, GruxSpacing.s)
    }

    private func resendRecovery(_ recovery: ChatRecovery) {
        state.chatRecovery = nil
        Task {
            await ChatService.shared.send(
                userText: recovery.retryText,
                imageData: recovery.retryImageData,
                imageMediaType: recovery.retryImageMediaType
            )
        }
    }

    private func retryRecovery(_ recovery: ChatRecovery) {
        resendRecovery(recovery)
    }

    /// Routes to the Anthropic key field, the only credential chat can spend.
    private func openKeySettings() {
        state.chatRecovery = nil
        AppState.shared.requestedSettingsTab = "api"
        AppState.shared.requestedTab = "settings"
    }

    private func continueOfflineAndRetry(_ recovery: ChatRecovery) {
        Task {
            state.offlineMode = true
            await ModelRegistry.shared.discoverLocal()
            resendRecovery(recovery)
        }
    }

    private func discoverLocalModels() {
        Task { await ModelRegistry.shared.discoverLocal() }
    }

    private func snoozeChat() {
        // No job to snooze in interactive chat; just clear the banner so the
        // composer is unobstructed. The user can retry whenever.
        state.chatRecovery = nil
    }

    // MARK: - Composer model chip + cost line

    // Compact row under the composer. Left: a chip to switch the active model
    // (cloud defaults + discovered local tags + saved custom endpoints). Right:
    // the pre-run cost estimate for the next send. Tight control sizing.
    private var composerMetaRow: some View {
        HStack(spacing: GruxSpacing.s) {
            modelChip
            skillsChip
            Spacer(minLength: GruxSpacing.s)
            if let e = costMeter.chatEstimate, !costLineText(e).isEmpty {
                Text(costLineText(e))
                    .font(GruxTheme.Font.microCaps)
                    .foregroundStyle(GruxTheme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help("Estimated cost of the next send at API rates. Local and subscription runs are free.")
            }
        }
    }

    private var modelChip: some View {
        Menu {
            Section("Cloud (API)") {
                ForEach(cloudModelOptions, id: \.self) { id in
                    Button {
                        state.config.model = id
                        state.saveConfig()
                        // Choosing a Claude model means routing to Claude;
                        // setting the id alone left a custom route in place.
                        registry.setActiveProvider(.anthropic)
                    } label: {
                        Text(activeModelId == id ? "\u{2713}  \(id)" : id)
                    }
                }
            }
            if !registry.localTags.isEmpty {
                Section("Local (free)") {
                    ForEach(registry.localTags, id: \.self) { tag in
                        Button {
                            state.config.offlineLLMModel = tag
                            state.saveConfig()
                            registry.setActiveProvider(.local)
                        } label: {
                            Text(activeModelId == tag ? "\u{2713}  \(tag)" : tag)
                        }
                    }
                }
            }
            if !endpoints.endpoints.isEmpty {
                Section("Custom endpoints") {
                    ForEach(endpoints.endpoints) { ep in
                        Button {
                            // Route to the endpoint. This used to write the
                            // endpoint's NAME into offlineLLMModel, which neither
                            // switched the route nor named a model.
                            registry.setActiveProvider(.custom(ep.id))
                        } label: {
                            Text(registry.activeProvider == .custom(ep.id) ? "\u{2713}  \(ep.name)" : ep.name)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: GruxSpacing.xs) {
                Image(systemName: "cpu").font(.system(size: 9, weight: .bold))
                Text(ComposerFooter.displayName(id: activeModelId, registryName: nil)).font(GruxTheme.Font.microCaps)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 7, weight: .bold))
            }
            .foregroundStyle(GruxTheme.textSecondary)
            .padding(.horizontal, GruxSpacing.s)
            .padding(.vertical, GruxSpacing.xs)
            .background(Capsule().fill(Color.white.opacity(0.05)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 0.8))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Switch the model for chat. Cloud runs are metered; local and subscription runs are free.")
    }

    // MARK: - Skills picker (Phase C fold)

    /// Opens and closes Skills above the draft. It matches the model chip
    /// beside it, and lights in the accent while Skills is open, the way the
    /// preset button lights while a preset is on. It is the only skills
    /// control in the composer; everything else lives inside what it opens.
    private var skillsChip: some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) { skillsOpen.toggle() }
        } label: {
            HStack(spacing: GruxSpacing.xs) {
                Image(systemName: "graduationcap.fill").font(.system(size: 9, weight: .bold))
                Text(ComposerSkills.chipLabel(count: skillStore.skills.count)).font(GruxTheme.Font.microCaps)
                Image(systemName: skillsOpen ? "chevron.down" : "chevron.up").font(.system(size: 7, weight: .bold))
            }
            .foregroundStyle(skillsOpen ? GruxTheme.accentPrimaryLight : GruxTheme.textSecondary)
            .padding(.horizontal, GruxSpacing.s)
            .padding(.vertical, GruxSpacing.xs)
            .background(Capsule().fill(skillsOpen ? GruxTheme.accentPrimary.opacity(0.16) : Color.white.opacity(0.05)))
            .overlay(Capsule().strokeBorder(skillsOpen ? GruxTheme.accentPrimary.opacity(0.45) : Color.white.opacity(0.10),
                                            lineWidth: 0.8))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("Skills")
        .help(skillsOpen ? "Hide your skills" : "Use one of your skills in this message")
    }

    /// Skills, folded in from its own rail row. The whole surface comes with
    /// it, not a cut-down list: USE puts a skill in front of the draft, and
    /// new, edit and delete work exactly as they did on the old tab.
    private var skillsTray: some View {
        SkillsView(onUse: { skill in
            draft = ComposerSkills.apply(skill.name, to: draft)
            withAnimation(.easeOut(duration: 0.18)) { skillsOpen = false }
            inputFocused = true
        })
        .capabilityGated("skills")
        .frame(height: 220)
        .background(
            RoundedRectangle(cornerRadius: GruxTheme.Radius.card, style: .continuous)
                .fill(Color.white.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: GruxTheme.Radius.card, style: .continuous)
                .strokeBorder(GruxTheme.iridescentRim.opacity(0.4), lineWidth: 0.8)
        )
        .clipShape(RoundedRectangle(cornerRadius: GruxTheme.Radius.card, style: .continuous))
        .padding(.horizontal, GruxSpacing.l)
        .padding(.top, GruxSpacing.m)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // Model id that will actually be sent given the registry's offline state.
    /// The model the next turn is routed to: the same answer `ChatService`
    /// sends with. Until 2026-09-21 this read `offlineLLMModel` whenever the
    /// route was not Anthropic, so a chat routed to OpenRouter's DeepSeek
    /// showed "Llama3.2" (seen live in the Phase A gate's Chat capture).
    private var activeModelId: String {
        registry.modelId()
    }

    // Canonical cloud choices, plus whatever is currently configured (a custom
    // id typed in Settings) so switching never hides the active model.
    private var cloudModelOptions: [String] {
        var opts = ["claude-fable-5", "claude-opus-4-8", "claude-sonnet-5", "claude-haiku-4-5-20251001"]
        let current = state.config.model
        if !current.isEmpty && !opts.contains(current) { opts.insert(current, at: 0) }
        return opts
    }


    // WAS: "est $X.XXXX for this send | in ~Nk tok | cheaper: <id> free".
    //
    // Four pieces of internal bookkeeping on the most looked-at surface in the
    // app. A four decimal price is accounting rather than information, a token
    // count is a number a person cannot act on, and the cheaper-alternative
    // nudge named a raw model identifier in a place you could not act on it.
    // The nudge belongs in the model picker, which is where you would go to
    // take it up. What is left is the cost, in words.
    private func costLineText(_ e: ChatRunEstimate) -> String {
        guard let usd = e.estimatedUSD else { return "" }
        return ComposerFooter.cost(usd)
    }

    private func send() {
        if voice.isRecording { voice.stop() }
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // With an image staged, allow a blank text payload - Grux sees the
        // image and Claude will describe it. Without an image, require text.
        guard !t.isEmpty || pendingImageData != nil else { return }
        let imgData = pendingImageData
        let imgType = pendingImageMediaType
        draft = ""
        draftBeforeVoice = ""
        // Clear the retained published transcript too. It is SET (not appended)
        // by VoiceInput and was never reset after a send, so a second dictation
        // cycle re-prepended the already-combined phrase onto draftBeforeVoice
        // and grew it into the "X, brand X, brand X" self-loop.
        voice.transcript = ""
        pendingImageData = nil
        pendingImageMediaType = nil
        pendingImagePreview = nil
        attachmentError = nil
        Task {
            await ChatService.shared.send(
                userText: t,
                imageData: imgData,
                imageMediaType: imgType
            )
        }
    }
}

/// Simple animated bar-equalizer driven by a 0..1 level. Used under the
/// "listening…" strip so users see the mic is actually hearing them.
struct WaveformBar: View {
    let level: Float
    @State private var phase: Double = 0

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(0..<16, id: \.self) { i in
                    Capsule()
                        .fill(LinearGradient(colors: [GruxTheme.destructiveRose, GruxTheme.accentPrimary],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: 3, height: height(for: i, geoH: geo.size.height))
                }
            }
        }
        .onAppear {
            // Bars keep their level-driven heights with motion off. Only the
            // travelling jitter stops, so the strip still shows the mic is live.
            guard !GruxTheme.reduceMotion else {
                phase = 0
                return
            }
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                phase = 2 * .pi
            }
        }
    }

    private func height(for i: Int, geoH: CGFloat) -> CGFloat {
        let jitter = 0.5 + 0.5 * abs(sin(phase + Double(i) * 0.55))
        let amp = CGFloat(max(0.08, level * 1.2)) * CGFloat(jitter)
        return max(2, min(geoH, geoH * amp))
    }
}

struct MessageBubble: View {
    /// Which side of the conversation a message belongs to, and what it is
    /// labelled. Extracted from the view because a view that decides this
    /// inline cannot be tested, and "a system message must never render as
    /// the person" is exactly the kind of rule that rots silently.
    enum Side: Equatable { case person, grux, system }

    static func side(for role: ChatRole) -> Side {
        switch role {
        case .user: return .person
        case .assistant: return .grux
        case .system: return .system
        }
    }

    /// A system message is the app reporting something that happened (a
    /// meeting saved, a recording recovered). It is not the person and it is
    /// not Grux answering, and labelling it GRUX put words in Grux's mouth.
    static func label(for role: ChatRole) -> String {
        switch side(for: role) {
        case .person: return "YOU"
        case .grux:   return "GRUX"
        case .system: return "NOTICE"
        }
    }

    let message: ChatMessage

    var body: some View {
        HStack(alignment: .top, spacing: GruxSpacing.m) {
            if MessageBubble.side(for: message.role) == .person { Spacer(minLength: 60) }
            if MessageBubble.side(for: message.role) != .person {
                avatar
            }
            VStack(alignment: MessageBubble.side(for: message.role) == .person ? .trailing : .leading,
                   spacing: GruxSpacing.xs) {
                Text(MessageBubble.label(for: message.role))
                    .font(GruxTheme.Font.microCaps).kerning(1.5)
                    .foregroundStyle(MessageBubble.side(for: message.role) == .person ? GruxTheme.accentPrimaryLight.opacity(0.8) : GruxTheme.textTertiary)
                if let imgData = message.imageData, let nsImg = NSImage(data: imgData) {
                    Image(nsImage: nsImg)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 280, maxHeight: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                        )
                }
                if !message.content.isEmpty {
                    MarkdownText(content: message.content)
                        .markdownFont(.body)
                        .markdownForegroundColor(GruxTheme.textPrimary)
                        .textSelection(.enabled)
                        .padding(.horizontal, GruxSpacing.m).padding(.vertical, GruxSpacing.s)
                        .background(bubbleBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(
                                    MessageBubble.side(for: message.role) == .person
                                        ? AnyShapeStyle(Color.white.opacity(0.12))
                                        : AnyShapeStyle(GruxTheme.iridescentRim.opacity(0.5)),
                                    lineWidth: 0.8
                                )
                        )
                }
            }
            if MessageBubble.side(for: message.role) == .person {
                userAvatar
            }
            if MessageBubble.side(for: message.role) != .person { Spacer(minLength: 60) }
        }
    }

    @ViewBuilder
    private var bubbleBackground: some View {
        if MessageBubble.side(for: message.role) == .person {
            LinearGradient(
                colors: [GruxTheme.accentPrimaryLight.opacity(0.7), GruxTheme.accentPrimary.opacity(0.55)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        } else {
            ZStack {
                Color.white.opacity(0.04)
                LinearGradient(
                    colors: [GruxTheme.accentCo.opacity(0.06), .clear],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            }
        }
    }

    private var avatar: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(colors: [GruxTheme.accentCo, GruxTheme.accentPrimary.opacity(0.8)],
                                   center: .center, startRadius: 1, endRadius: 18)
                )
                .frame(width: 28, height: 28)
            Text("G")
                .font(.caption.weight(.black))
                .foregroundStyle(.white)
        }.shadow(color: GruxTheme.accentCo.opacity(0.4), radius: 4)
    }

    private var userAvatar: some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.06))
                .overlay(Circle().strokeBorder(GruxTheme.accentPrimary.opacity(0.3), lineWidth: 0.8))
                .frame(width: 28, height: 28)
            Image(systemName: "person.fill")
                .font(.caption)
                .foregroundStyle(GruxTheme.textSecondary)
        }
    }
}


/// Reports where the person's own scrolling of the transcript ended: a
/// trackpad or scroller drag (the scroll view's live-scroll end) or a scroll
/// wheel turn over it. Layout, resizing and programmatic scrolls never
/// report, so they can never change whether Chat follows the newest message.
private struct TranscriptScrollIntent: NSViewRepresentable {
    let follow: ChatFollow
    // Whether the end of the transcript is in view, from the scroll view's
    // own geometry: what the Latest chip shows.
    let atBottom: Binding<Bool>

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.follow = follow
        probe.atBottom = atBottom
        return probe
    }

    func updateNSView(_ probe: Probe, context: Context) {
        probe.follow = follow
        probe.atBottom = atBottom
    }

    static func dismantleNSView(_ probe: Probe, coordinator: ()) {
        probe.detach()
    }

    final class Probe: NSView {
        var follow: ChatFollow? {
            didSet { follow?.scrollView = enclosingScrollView }
        }
        var atBottom: Binding<Bool>?
        private var liveScrollStart: NSObjectProtocol?
        private var liveScrollEnd: NSObjectProtocol?
        private var geometry: [NSObjectProtocol] = []
        private var wheel: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            detach()
            guard window != nil, let scroll = enclosingScrollView else { return }
            follow?.scrollView = scroll
            follow?.probe = self
            ChatFollow.live = follow
            // Where the view is, whoever moved it: the person, a re-anchor,
            // the content or the viewport changing size.
            scroll.contentView.postsBoundsChangedNotifications = true
            scroll.contentView.postsFrameChangedNotifications = true
            scroll.documentView?.postsFrameChangedNotifications = true
            // The content or the viewport changing size (a new message, the
            // thinking bubble, the notice under Chat, the window resizing) is
            // a layout: it keeps the end in view while following, or the
            // person's place while not. A move that is not a layout, not the
            // person's wheel or live scroll and not one Chat makes (selection
            // autoscroll, VoiceOver, a focused field) is the person's new place.
            for (name, object, layout) in [(NSView.boundsDidChangeNotification, scroll.contentView as NSView?, false),
                                           (NSView.frameDidChangeNotification, scroll.contentView as NSView?, true),
                                           (NSView.frameDidChangeNotification, scroll.documentView, true)] {
                geometry.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: nil) {
                    [weak self, weak scroll] _ in
                    guard let scroll else { return }
                    MainActor.assumeIsolated {
                        self?.follow?.lastMoveAt = ProcessInfo.processInfo.systemUptime
                        if layout { self?.follow?.sizesChanged() } else { self?.follow?.viewMoved() }
                        self?.publishBottom(scroll)
                    }
                })
            }
            DispatchQueue.main.async { [weak self, weak scroll] in
                guard let scroll else { return }
                MainActor.assumeIsolated { self?.publishBottom(scroll) }
            }
            // queue nil: handled as it is posted (on the main thread), so a
            // relayout queued behind it already sees the person's choice.
            liveScrollStart = NotificationCenter.default.addObserver(
                forName: NSScrollView.willStartLiveScrollNotification, object: scroll, queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.follow?.personScrolling = true }
            }
            liveScrollEnd = NotificationCenter.default.addObserver(
                forName: NSScrollView.didEndLiveScrollNotification, object: scroll, queue: nil
            ) { [weak self, weak scroll] _ in
                guard let scroll else { return }
                MainActor.assumeIsolated {
                    self?.follow?.personScrolling = false
                    self?.report(scroll)
                }
            }
            wheel = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self, weak scroll] event in
                MainActor.assumeIsolated {
                    if let scroll, event.window === scroll.window,
                       scroll.bounds.contains(scroll.convert(event.locationInWindow, from: nil)) {
                        // The person is moving the view: nothing puts it back.
                        self?.follow?.personScrolling = true
                        // After the scroll view has handled the event.
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                self?.follow?.personScrolling = false
                                self?.report(scroll)
                            }
                        }
                    }
                }
                return event
            }
        }

        func detach() {
            // A Chat that left its window is not the one the chat triggers
            // act on (chat-status.json says chatOpen: false).
            if let follow, ChatFollow.live === follow { ChatFollow.live = nil }
            geometry.forEach { NotificationCenter.default.removeObserver($0) }
            geometry = []
            if let liveScrollStart { NotificationCenter.default.removeObserver(liveScrollStart) }
            if let liveScrollEnd { NotificationCenter.default.removeObserver(liveScrollEnd) }
            liveScrollStart = nil
            if let wheel { NSEvent.removeMonitor(wheel) }
            liveScrollEnd = nil
            wheel = nil
        }

        private func report(_ scroll: NSScrollView) {
            follow?.latest = Self.isAtBottom(scroll)
            follow?.holdPlace()
        }

        private var publishQueued = false
        /// The chip's state is about to be set from where the view is.
        var publishPending: Bool { publishQueued }

        /// Sets the Latest chip's state from where the view is. Not inside
        /// SwiftUI's own update pass, so on the next turn, and read then:
        /// a value read now and set later could land after a newer one (the
        /// view mid-layout off the end, then re-anchored before the set ran)
        /// and leave the chip up over a transcript showing its end.
        private func publishBottom(_ scroll: NSScrollView) {
            guard !publishQueued else { return }
            publishQueued = true
            DispatchQueue.main.async { [weak self, weak scroll] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.publishQueued = false
                    guard let scroll, let atBottom = self.atBottom else { return }
                    let now = Self.isAtBottom(scroll)
                    if atBottom.wrappedValue != now { atBottom.wrappedValue = now }
                }
            }
        }

        /// The visible part of the transcript reaches its end (within a few
        /// points), in either document orientation.
        static func isAtBottom(_ scroll: NSScrollView) -> Bool {
            guard let doc = scroll.documentView else { return true }
            let visible = scroll.contentView.bounds
            return doc.isFlipped ? visible.maxY >= doc.frame.height - 8 : visible.minY <= 8
        }
    }
}

private extension View {
    /// The scroll view's first layout shows its bottom; later size changes
    /// leave the position alone.
    @ViewBuilder func opensAtBottom() -> some View {
        if #available(macOS 15.0, *) {
            defaultScrollAnchor(.bottom, for: .initialOffset)
        } else {
            defaultScrollAnchor(.bottom)
        }
    }
}

/// Reports where a message row sits in the transcript's content.
private struct TranscriptRowFrame: View {
    static let space = "grux.chat.transcript"
    let id: UUID

    struct Key: PreferenceKey {
        static let defaultValue: [UUID: CGRect] = [:]
        static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
            value.merge(nextValue()) { $1 }
        }
    }

    var body: some View {
        GeometryReader { g in
            Color.clear.preference(key: Key.self, value: [id: g.frame(in: .named(Self.space))])
        }
    }
}

/// Whether Chat's transcript follows the newest message (see ChatView's
/// `follow`), and where the person's place is when it does not.
@MainActor
private final class ChatFollow {
    var latest = true {
        didSet {
            if latest { heldTop = nil; anchor = nil }
        }
    }
    /// While the person scrolls, nothing puts the view back.
    var personScrolling = false
    /// Where the person left the view (the clip view's top), while not
    /// following. SwiftUI's own layout passes restore the scroll offset they
    /// last knew, which took back a scroll-up made during a resize.
    private var heldTop: CGFloat?
    /// The reader's place as a message, not a pixel offset (SWEEP-13: a resize
    /// re-wraps every message above, so the same offset showed message 11
    /// where message 14 had been). The message at the top of the view, and
    /// either how far below the top its first line sits, or how far into it
    /// the top is, as a share of its height.
    private struct Anchor { let id: UUID; let gap: CGFloat?; let fraction: CGFloat }
    private var anchor: Anchor?
    /// How long after a size change a move of the view is still that layout
    /// settling (SwiftUI restoring its offset), not a move of its own.
    static let layoutSettle: TimeInterval = 0.5
    private var settlingUntil: TimeInterval = 0
    private var lastSizes: [CGSize] = []
    /// Chat is moving the view itself (re-anchoring, restoring the place).
    private var selfMoving = false
    /// A scroll Chat started (it may animate) is still running.
    private var appMoving = false
    private var appMoves = 0

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Remembers where the view is now as the person's place.
    func holdPlace() {
        guard !latest, let scroll = scrollView else { return }
        let top = scroll.contentView.bounds.minY
        heldTop = top
        if let (id, frame) = row(atTop: top) {
            anchor = frame.minY >= top
                ? Anchor(id: id, gap: frame.minY - top, fraction: 0)
                : Anchor(id: id, gap: nil, fraction: (top - frame.minY) / max(1, frame.height))
        } else {
            anchor = nil
        }
    }

    /// The first message with any of it below `top`, and where it sits.
    private func row(atTop top: CGFloat) -> (UUID, CGRect)? {
        rowFrames.filter { $0.value.maxY > top + 1 }.min { $0.value.minY < $1.value.minY }.map { ($0.key, $0.value) }
    }

    /// Where the view's top goes to show the reader's place: the anchored
    /// message where it sat, or the held offset when no message is laid out.
    private var heldTarget: CGFloat? {
        if let anchor, let frame = rowFrames[anchor.id] {
            return anchor.gap.map { frame.minY - $0 } ?? frame.minY + anchor.fraction * frame.height
        }
        return heldTop
    }

    /// Show earlier: the message now at the top stays at the top while a page
    /// is laid out above it.
    func keepTopMessageWhileShowingEarlier() {
        latest = false
        holdPlace()
        if let a = anchor { anchor = Anchor(id: a.id, gap: 0, fraction: 0) }
        restoreHeldPlace()
    }

    /// Back to the newest message, following it: through the scroll view,
    /// never a SwiftUI scroll target (SWEEP-13: a target SwiftUI applied again
    /// at a later layout put the view back 33 pt short of the end after Chat
    /// had reached it, and that move turned following off).
    func scrollToEnd(animated: Bool) {
        appMove(following: true, duration: animated ? 0.35 : 0.1) {
            guard let scroll = self.scrollView, let doc = scroll.documentView else { return }
            let clip = scroll.contentView
            let y = doc.isFlipped ? max(0, doc.frame.height - clip.bounds.height) : 0
            let target = NSPoint(x: clip.bounds.minX, y: y)
            if animated && !GruxTheme.reduceMotion {
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.25
                    clip.animator().setBoundsOrigin(target)
                }, completionHandler: { scroll.reflectScrolledClipView(clip) })
            } else {
                clip.scroll(to: target)
                scroll.reflectScrolledClipView(clip)
            }
        }
    }

    /// The content or the viewport may have changed size: if it did, the
    /// moves right after it are that layout. Keeps the end or the place.
    func sizesChanged() {
        guard let scroll = scrollView else { return }
        let sizes = [scroll.contentView.frame.size, scroll.documentView?.frame.size ?? .zero]
        if sizes != lastSizes {
            lastSizes = sizes
            settlingUntil = Self.now + Self.layoutSettle
        }
        settle()
    }

    /// The view moved. Chat's own moves, the person's wheel or live scroll
    /// and a scroll Chat started are reported elsewhere. Right after a size
    /// change it is the layout, and the end or the place is kept. Anything
    /// else (selection autoscroll, VoiceOver, a focused field, the keyboard)
    /// is the person's new place.
    func viewMoved() {
        guard !selfMoving, !personScrolling, !appMoving, let scroll = scrollView else { return }
        if Self.now < settlingUntil {
            settle()
        } else {
            latest = TranscriptScrollIntent.Probe.isAtBottom(scroll)
            holdPlace()
        }
    }

    private func settle() {
        if latest { showBottomIfFollowing() } else { restoreHeldPlace() }
    }

    /// Moves a view that a layout moved back to where the person left it (as
    /// close as the content allows).
    func restoreHeldPlace() {
        guard !latest, !personScrolling, !appMoving, let top = heldTarget,
              let scroll = scrollView, let doc = scroll.documentView else { return }
        let clip = scroll.contentView
        let target = min(top, max(0, doc.frame.height - clip.bounds.height))
        guard abs(clip.bounds.minY - target) > 1 else { return }
        moveClip(scroll, to: target)
    }

    /// A scroll Chat makes, which may animate for up to `duration`: its steps
    /// are neither put back nor taken as the person's place. With
    /// `following`, the end of the transcript is kept in view after it;
    /// without (Show earlier), the place it lands on is the person's.
    func appMove(following: Bool, duration: TimeInterval = 0.35, _ move: () -> Void) {
        latest = following
        appMoves += 1
        let mine = appMoves
        appMoving = true
        move()
        let giveUp = Self.now + duration + 2
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            self?.finishAppMove(mine, giveUpAt: giveUp)
        }
    }

    /// Ends an app move once the view has stopped: an animated scroll's last
    /// frames can land after its nominal duration, and taken as the person's
    /// own place they turned following off (the Latest chip's own tap, found
    /// by its trigger's test). Following, the view then goes to the true end:
    /// a message anchored at the bottom stops short of the transcript's
    /// padding.
    private func finishAppMove(_ mine: Int, giveUpAt: TimeInterval) {
        // A later move owns the end.
        guard appMoves == mine else { return }
        if Self.now - lastMoveAt < 0.15, Self.now < giveUpAt {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.finishAppMove(mine, giveUpAt: giveUpAt)
            }
            return
        }
        appMoving = false
        if latest { showBottomIfFollowing() } else { holdPlace() }
    }

    /// The probe watching the transcript (it owns the Latest chip's state).
    weak var probe: TranscriptScrollIntent.Probe?

    /// The Chat most recently put in a window: what the chat triggers act on.
    static weak var live: ChatFollow?

    /// How many of the newest messages the transcript lays out (the view's
    /// own count, mirrored for chat-status.json).
    var shownCount = ChatView.transcriptPage
    /// Where each laid-out message sits in the transcript's content.
    var rowFrames: [UUID: CGRect] = [:] {
        // Rows move only when the transcript is laid out again (a resize,
        // a page shown above): keep the reader's message where it was.
        didSet { if !latest { restoreHeldPlace() } }
    }
    /// When the view last moved or changed size.
    var lastMoveAt: TimeInterval = 0

    /// Whether the Latest chip is up: its own state, what decides whether it
    /// draws (the transcript's end out of view, and a thread with messages).
    var chipUp: Bool {
        guard let bottom = probe?.atBottom else { return false }
        return !bottom.wrappedValue && !AppState.shared.chat.isEmpty
    }

    /// The first message with any of it in view.
    var topVisibleMessage: UUID? {
        guard let top = scrollView?.contentView.bounds.minY else { return nil }
        return rowFrames.filter { $0.value.maxY > top + 1 }.min { $0.value.minY < $1.value.minY }?.key
    }

    /// No scroll Chat started is running, the person is not scrolling, the
    /// chip's state is set, and nothing moved for 0.3 s.
    var isSettled: Bool {
        !appMoving && !personScrolling && !(probe?.publishPending ?? false)
            && Self.now - lastMoveAt >= 0.3
    }

    /// A person's scroll by `points` (negative is up), the way a trackpad
    /// scroll reaches Chat: the scroll view says a live scroll started, the
    /// view moves (never past either end), and the live scroll ends, which is
    /// where Chat reads the person's new place.
    func scrollAsPerson(by points: CGFloat) {
        guard let scroll = scrollView, let doc = scroll.documentView else { return }
        let clip = scroll.contentView
        let maxY = max(0, doc.frame.height - clip.bounds.height)
        let step = doc.isFlipped ? points : -points
        let y = min(max(0, clip.bounds.minY + step), maxY)
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
        scroll.reflectScrolledClipView(clip)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
    }
    /// The transcript's scroll view, set by TranscriptScrollIntent.
    weak var scrollView: NSScrollView? {
        didSet { if let scrollView { Self.byScrollView.setObject(self, forKey: scrollView) } }
    }
    /// Each transcript's follow state by its scroll view (ChatView.followsLatest).
    static let byScrollView = NSMapTable<NSScrollView, ChatFollow>.weakToWeakObjects()

    /// Shows the end of the transcript, if it follows the newest message and
    /// nobody (the person, or a scroll Chat started) is moving it.
    func showBottomIfFollowing() {
        guard latest, !personScrolling, !appMoving, let scroll = scrollView, let doc = scroll.documentView else { return }
        let clip = scroll.contentView
        let y = doc.isFlipped ? max(0, doc.frame.height - clip.bounds.height) : 0
        guard abs(clip.bounds.minY - y) > 0.5 else { return }
        moveClip(scroll, to: y)
    }

    private func moveClip(_ scroll: NSScrollView, to y: CGFloat) {
        selfMoving = true
        defer { selfMoving = false }
        let clip = scroll.contentView
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
        scroll.reflectScrolledClipView(clip)
    }
}

