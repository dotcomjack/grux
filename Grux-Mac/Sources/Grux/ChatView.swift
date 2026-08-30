import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ChatView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var voice = VoiceInput.shared
    @StateObject private var speech = SpeechEngine.shared
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

    // Item 24: shell bus fills the idle gap with canonical moments.
    @ObservedObject private var shellBus = ShellStateBus.shared

    // Cost meter: the pre-run estimate published right before each send, plus
    // the model sources the composer chip picks from (discovered local tags +
    // saved custom endpoints).
    @ObservedObject private var costMeter = CostMeter.shared
    @ObservedObject private var registry = ModelRegistry.shared
    @ObservedObject private var endpoints = CustomEndpointStore.shared

    private var orbState: GruxOrbState {
        if speech.isSpeaking || speech.isBuffering { return .speaking }
        if voice.isRecording || voice.isTranscribing { return .listening }
        if state.isThinking { return .thinking }
        return shellBus.current.mode.orbState
    }

    var body: some View {
        HStack(spacing: 0) {
            ChatThreadsSidebar()
                .environmentObject(state)
            Rectangle()
                .fill(GruxTheme.iridescentRim.opacity(0.4))
                .frame(width: 1)
            ZStack {
                backdrop
                VStack(spacing: 0) {
                    heroHeader
                    themedHairline
                    SessionsStrip()
                    messagesScroll
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
        .frame(minWidth: 560, minHeight: 520)
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
    private var heroHeader: some View {
        VStack(alignment: .leading, spacing: GruxSpacing.s) {
            HStack(alignment: .center, spacing: GruxSpacing.m) {
            VStack(alignment: .leading, spacing: GruxSpacing.xs + 2) {
                Text("CURRENT TASK")
                    .font(GruxTheme.Font.microCaps)
                    .kerning(1.4)
                    .foregroundStyle(GruxTheme.textTertiary)
                if let t = state.currentTask {
                    Label(t.title, systemImage: "target")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(GruxTheme.textPrimary)
                        .lineLimit(1)
                } else {
                    Text("No current task. Ask me what to work on.")
                        .font(.callout).foregroundStyle(GruxTheme.textSecondary)
                }
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
            // horizontal budget, and at the 840pt window floor they lost:
            // "WAKE OFF" and "ELEVEN LABS" rendered as "WA..." and "EL...".
            // Neither lineLimit, minimumScaleFactor nor layoutPriority fixed
            // that, because the constraint was the width the block was handed,
            // not how its contents were drawn. On their own line they have the
            // full pane and simply fit. Two short status chips also read better
            // under the title than jammed beside it.
            HStack(spacing: GruxSpacing.m) {
                wakeIndicator
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
    // "speak replies aloud" toggle lives in Settings.
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

    private var wakeIndicator: some View {
        statusPill(
            icon: wake.isListening ? "waveform" : "waveform.slash",
            label: wake.isListening ? "WAKE ON" : "WAKE OFF",
            accent: wake.isListening ? GruxTheme.successMint : GruxTheme.textTertiary
        )
    }

    private var speakIndicator: some View {
        statusPill(
            icon: state.config.useElevenLabs ? "waveform.and.person.filled" : "speaker.wave.2",
            label: state.config.useElevenLabs ? "ELEVEN LABS" : "SYSTEM TTS",
            accent: state.config.speakRepliesAloud ? GruxTheme.accentCo : GruxTheme.textTertiary
        )
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
                // At the 840pt window floor this header rendered "WAKE OFF" as
                // "WA / KE / OF / F" and "ELEVEN LABS" as "EL / EV / EN / LA /
                // BS", one or two characters per line, on the app's default
                // landing tab. lineLimit alone fixes that: the label truncates
                // instead of wrapping.
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

    private var messagesScroll: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: GruxSpacing.l) {
                        if state.chat.isEmpty {
                            emptyState
                        }
                        ForEach(state.chat) { m in
                            MessageBubble(message: m).id(m.id)
                        }
                        if state.isThinking {
                            thinkingBubble
                        }
                        // Invisible sentinel pinned to the bottom of the
                        // scroll content. Its onAppear/onDisappear flips
                        // `isAtBottom` so the floating jump chip knows when
                        // to fade in. A 1pt footprint keeps layout clean;
                        // LazyVStack composes it right when the true bottom
                        // enters the render window.
                        Color.clear
                            .frame(height: 1)
                            .id("grux.chat.bottom-sentinel")
                            .onAppear { isAtBottom = true }
                            .onDisappear { isAtBottom = false }
                    }
                    .padding(.horizontal, GruxSpacing.xl).padding(.vertical, GruxSpacing.l)
                }
                .onChange(of: state.chat.count) { _, _ in
                    if let last = state.chat.last {
                        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }

                if !isAtBottom && !state.chat.isEmpty {
                    Button {
                        withAnimation(.easeOut(duration: 0.3)) {
                            if let last = state.chat.last {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            } else {
                                proxy.scrollTo("grux.chat.bottom-sentinel", anchor: .bottom)
                            }
                        }
                    } label: {
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
                            .symbolEffect(.pulse, options: .repeating, isActive: voice.isRecording)
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
        .background(
            ZStack {
                VisualEffectBackdrop(material: .hudWindow, blendingMode: .behindWindow)
                Color.black.opacity(0.25)
            }
        )
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

    private static let acceptedDropTypes: [UTType] = [
        .image, .fileURL, .png, .jpeg, .gif, .webP, .heic, .tiff
    ]

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

    // Walk NSItemProvider candidates, preferring the NSImage loader because
    // that's the only path that reliably works across EVERY macOS drag source
    // (Safari, Photos, iMessage, Finder, Preview, Notes). Raw
    // loadDataRepresentation often returns nil/empty even when
    // hasItemConformingToTypeIdentifier says the type is available - the
    // provider resolves the bytes lazily through the object loader, not the
    // UTType data channel. Fall back to file URLs for Finder drops that
    // only expose themselves as file refs.
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        attachmentError = nil

        for provider in providers where provider.canLoadObject(ofClass: NSImage.self) {
            provider.loadObject(ofClass: NSImage.self) { object, err in
                Task { @MainActor in
                    if let image = object as? NSImage {
                        self.ingestNSImage(image)
                    } else {
                        self.attachmentError = err.map { "Drop failed: \($0.localizedDescription)" }
                            ?? "Couldn't read the dropped image."
                    }
                }
            }
            return true
        }

        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                Task { @MainActor in
                    guard let url else {
                        self.attachmentError = "Couldn't resolve the dropped file."
                        return
                    }
                    self.ingestFileURL(url)
                }
            }
            return true
        }

        attachmentError = "That doesn't look like an image I can attach."
        return false
    }

    // Dropped-file path: read bytes off disk, sniff the format, and send
    // through the same NSImage pipeline as in-memory drops. Handles files
    // that came in via file-URL-only providers (some Finder drags).
    private func ingestFileURL(_ url: URL) {
        guard let data = try? Data(contentsOf: url) else {
            attachmentError = "Couldn't read \(url.lastPathComponent)."
            return
        }
        guard let image = NSImage(data: data) else {
            attachmentError = "\(url.lastPathComponent) isn't a readable image."
            return
        }
        ingestNSImage(image)
    }

    // Universal ingest: re-encode whatever NSImage we got into PNG so the
    // Anthropic API gets a format it accepts (PNG/JPEG/GIF/WebP). NSImage
    // is normalized via TIFF → NSBitmapImageRep → PNG; that round-trip also
    // strips any weird source-specific metadata that might confuse the API.
    private func ingestNSImage(_ image: NSImage) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]),
              !png.isEmpty else {
            attachmentError = "Couldn't encode that image."
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
            Spacer(minLength: GruxSpacing.s)
            if let e = costMeter.chatEstimate {
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
                            state.config.offlineLLMModel = ep.name
                            state.saveConfig()
                        } label: {
                            Text(ep.name)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: GruxSpacing.xs) {
                Image(systemName: "cpu").font(.system(size: 9, weight: .bold))
                Text(shortModelLabel(activeModelId)).font(GruxTheme.Font.microCaps)
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

    // Model id that will actually be sent given the registry's offline state.
    private var activeModelId: String {
        registry.offlineReady ? state.config.offlineLLMModel : state.config.model
    }

    // Canonical cloud choices, plus whatever is currently configured (a custom
    // id typed in Settings) so switching never hides the active model.
    private var cloudModelOptions: [String] {
        var opts = ["claude-fable-5", "claude-opus-4-8", "claude-sonnet-5", "claude-haiku-4-5-20251001"]
        let current = state.config.model
        if !current.isEmpty && !opts.contains(current) { opts.insert(current, at: 0) }
        return opts
    }

    // Trim a model id to a compact chip label: drop a provider prefix, the
    // "claude-" prefix, and a trailing -YYYYMMDD date tag.
    private func shortModelLabel(_ id: String) -> String {
        var s = id
        if let slash = s.lastIndex(of: "/") { s = String(s[s.index(after: slash)...]) }
        if s.hasPrefix("claude-") { s = String(s.dropFirst("claude-".count)) }
        if let r = s.range(of: #"-\d{8}$"#, options: .regularExpression) { s = String(s[..<r.lowerBound]) }
        return s.isEmpty ? id : s
    }

    // "est $X.XXXX for this send | in ~Nk tok | cheaper: haiku $Y / local free".
    // Always leads with "est" and uses $N numerals per the copy rules.
    private func costLineText(_ e: ChatRunEstimate) -> String {
        var parts: [String] = []
        if let usd = e.estimatedUSD {
            parts.append(usd <= 0 ? "est $0 for this send" : "est \(shortUSD(usd)) for this send")
        }
        parts.append("in ~\(kTokens(e.inputTokens)) tok")
        if let alt = e.cheaperAlternative {
            let name = shortModelLabel(alt.modelId)
            parts.append(alt.estimatedUSD <= 0 ? "cheaper: \(name) free" : "cheaper: \(name) \(shortUSD(alt.estimatedUSD))")
        }
        return parts.joined(separator: "  |  ")
    }

    private func shortUSD(_ usd: Double) -> String {
        usd >= 1 ? String(format: "$%.2f", usd) : String(format: "$%.4f", usd)
    }

    private func kTokens(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.0fk", Double(n) / 1000.0) : "\(n)"
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
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .top, spacing: GruxSpacing.m) {
            if message.role == .user { Spacer(minLength: 60) }
            if message.role != .user {
                avatar
            }
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: GruxSpacing.xs) {
                Text(message.role == .user ? "YOU" : "GRUX")
                    .font(GruxTheme.Font.microCaps).kerning(1.5)
                    .foregroundStyle(message.role == .user ? GruxTheme.accentPrimaryLight.opacity(0.8) : GruxTheme.textTertiary)
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
                                    message.role == .user
                                        ? AnyShapeStyle(Color.white.opacity(0.12))
                                        : AnyShapeStyle(GruxTheme.iridescentRim.opacity(0.5)),
                                    lineWidth: 0.8
                                )
                        )
                }
            }
            if message.role == .user {
                userAvatar
            }
            if message.role != .user { Spacer(minLength: 60) }
        }
    }

    @ViewBuilder
    private var bubbleBackground: some View {
        if message.role == .user {
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
