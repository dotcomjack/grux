import SwiftUI
import AppKit

struct TerminalFocusSettingsView: View {
    // Single source of truth is the shared singleton. The earlier version
    // also declared an @EnvironmentObject - but LaunchRootView hosts this
    // view without injecting one, so that crashed at render. `tf` is the
    // only observed handle we need; `state` below is an alias for clarity
    // at the Task 9 call sites.
    @ObservedObject private var tf = TerminalFocusState.shared
    private var state: TerminalFocusState { tf }

    @State private var hookError: String?
    @State private var showHookSuccess = false

    // Task 9 - Claude session mapping + hotkey capture state.
    // `sessions` reads the background-maintained list on TerminalFocusState
    // rather than calling ClaudeSessionIndex.recentSessions() here: that scan
    // reads+parses hundreds of MB of session JSONL, and doing it on the main
    // thread in .onAppear froze the launch window so the terminalFocus tab
    // showed no window. Capped to 50 for the picker.
    private var sessions: [ClaudeSessionDescriptor] {
        Array(tf.sessionPickerDescriptors.prefix(50))
    }
    @State private var recording: Bool = false
    // Per-corner picker bindings. Mirror state.terminalFocusCfg.slotMapping so
    // the Picker value is an optional String? (nil == "- unassigned -").
    @State private var topLeftPick: String? = nil
    @State private var topRightPick: String? = nil
    @State private var bottomLeftPick: String? = nil
    @State private var bottomRightPick: String? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                HStack(alignment: .center, spacing: 14) {
                    Image(systemName: "rectangle.inset.filled.on.rectangle")
                        .font(.system(size: 28))
                        .foregroundStyle(.green.opacity(0.7))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Terminal Focus")
                            .font(GruxType.title).foregroundStyle(GruxTheme.textPrimary)
                        Text("Floating overlay showing context from surrounding Claude Code sessions")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: $tf.isEnabled)
                        .toggleStyle(.switch)
                        .onChange(of: tf.isEnabled) { _, enabled in
                            tf.saveConfig()
                            if enabled {
                                tf.start()
                                TerminalFocusOverlayController.shared.show()
                            } else {
                                TerminalFocusOverlayController.shared.hide()
                            }
                        }
                }
                .padding(.bottom, 4)

                Divider()

                // Task 9: Claude session mapping + hotkey capture sections.
                // Placed near the top (right after the header/divider) so the
                // v1 "pick sessions per corner + customize hotkey" flow is the
                // first thing the user sees when they open the Terminal tab.
                // Paper cut (papercut sweep 2026-06-10): this block was a
                // macOS Form, whose layout engine demanded more width than
                // the detail pane has. The whole HStack overflowed the
                // window and the sidebar clipped off-screen. Plain stacks
                // lay out the identical rows inside the available width.
                VStack(alignment: .leading, spacing: GruxSpacing.m) {
                    HStack {
                        GruxSectionLabel("Claude session mapping")
                        Spacer()
                        Button("Refresh") {
                            tf.reloadSessionPicker()
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                    if sessions.isEmpty {
                        Text("No recent Claude Code sessions found yet. Sessions appear here once you have run Claude Code in a terminal.")
                            .font(GruxType.caption)
                            .foregroundStyle(GruxTheme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(cornerPickerRows, id: \.0) { corner, label in
                        HStack(spacing: GruxSpacing.s) {
                            Text(label)
                                .font(GruxType.body)
                                .foregroundStyle(GruxTheme.textSecondary)
                                .frame(width: 96, alignment: .trailing)
                            Picker("", selection: binding(for: corner)) {
                                Text("(unassigned)").tag(String?.none)
                                ForEach(sessions) { session in
                                    // Untruncated titles set the popup's
                                    // intrinsic width; cap the label and keep
                                    // the full title in the tooltip.
                                    Text("\(Self.clipped(session.title)) · \(relativeString(session.lastActiveAt))")
                                        .help(session.title)
                                        .tag(session.sessionId as String?)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 420, alignment: .leading)
                        }
                    }

                    GruxSectionLabel("Hotkey")
                        .padding(.top, GruxSpacing.xs)
                    if recording {
                        HStack(spacing: 8) {
                            Image(systemName: "keyboard")
                                .foregroundStyle(.orange)
                            Text("Press the keys now (Esc to cancel)")
                                .font(.callout)
                                .foregroundStyle(.orange)
                            KeyCaptureView { keyCode, mods in
                                recording = false
                                if let kc = keyCode, let m = mods {
                                    state.setHotkey(HotkeyConfig(keyCode: kc, modifiers: m))
                                }
                            }
                            .frame(width: 0, height: 0)
                            Spacer()
                        }
                    } else {
                        HStack {
                            Text("Current")
                                .foregroundStyle(.secondary)
                            Text(state.terminalFocusCfg.hotkey.displayString)
                                .font(GruxTheme.Font.mono)
                            Spacer()
                            Button("Record new combo…") { recording = true }
                            Button("Reset to ⌥⌘T") {
                                state.setHotkey(.defaultTerminalFocus)
                                recording = false
                            }
                        }
                    }
                }
                .onAppear {
                    // Loads off the main thread (background-maintained cache);
                    // never reads session JSONL synchronously here.
                    tf.loadSessionPickerDescriptorsIfNeeded()
                    // Seed pickers from current mapping so the UI matches disk.
                    let m = state.terminalFocusCfg.slotMapping
                    topLeftPick = m.sessionId(for: .topLeft)
                    topRightPick = m.sessionId(for: .topRight)
                    bottomLeftPick = m.sessionId(for: .bottomLeft)
                    bottomRightPick = m.sessionId(for: .bottomRight)
                }

                Divider()

                // Live status
                if tf.isEnabled {
                    statusSection
                    Divider()
                }

                // Display settings
                displaySection
                Divider()

                // Corner assignment
                cornerSection
                Divider()

                // Hook setup
                hookSection

                if !tf.allSessions.isEmpty {
                    Divider()
                    sessionsSection
                }
            }
            .padding(20)
            // Let the content shrink with the detail pane. The previous
            // .frame(minWidth: 480) here forced horizontal overflow that
            // clipped labels on both sides when the window wasn't wide
            // enough. Window-level minSize now enforces layout headroom.
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            tf.refresh()
            tf.checkHookInstalled()
        }
    }

    // MARK: - Status

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Live Status", systemImage: "antenna.radiowaves.left.and.right")
                .font(.headline)

            HStack(spacing: 20) {
                statusPill(
                    label: "Overlay",
                    value: TerminalFocusOverlayController.shared.isShowing ? "visible" : "hidden",
                    color: TerminalFocusOverlayController.shared.isShowing ? .green : .secondary
                )
                statusPill(
                    label: "Sessions",
                    value: "\(tf.allSessions.count)",
                    color: tf.allSessions.isEmpty ? .secondary : .green
                )
                statusPill(
                    label: "Active",
                    value: "\(tf.activeCount)",
                    color: tf.activeCount > 0 ? .green : .secondary
                )
                if tf.stuckCount > 0 {
                    statusPill(label: "Stuck", value: "\(tf.stuckCount)", color: .orange)
                }
            }

            HStack(spacing: 10) {
                // Route through hideOverlay()/showOverlay() so the user-dismiss
                // flag persists. The old direct controller toggle was defeated
                // by the 1.5s poll tick bringing the panel right back.
                Button(tf.userHidden ? "Show Overlay" : "Hide Overlay") {
                    tf.toggleOverlay()
                }
                .buttonStyle(.bordered)

                Button("Refresh") { tf.refresh() }
                    .buttonStyle(.bordered)

                Button("Grant Screen Recording") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
                .buttonStyle(.bordered)
                .help("Required for spatial corner assignment. Terminal windows won't be spatially mapped without this permission.")
            }
        }
    }

    private func statusPill(label: String, value: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title3.bold().monospaced())
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 60)
        .padding(.vertical, 8).padding(.horizontal, 12)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Display

    private var displaySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Display", systemImage: "rectangle.on.rectangle")
                .font(.headline)

            // Paper cut (papercut sweep 2026-06-10): this was a nested Form.
            // The macOS form layout engine demanded more width than the
            // detail pane has, overflowing the window and clipping the
            // sidebar off-screen. A plain VStack lays out the same rows
            // without the width demand.
            VStack(alignment: .leading, spacing: 12) {
                Picker("Task view", selection: $tf.viewMode) {
                    ForEach(OverlayViewMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320, alignment: .leading)
                .onChange(of: tf.viewMode) { _, _ in tf.saveConfig() }

                HStack {
                    Text("Stuck threshold")
                    Spacer()
                    Stepper("\(tf.stuckThresholdMinutes) min",
                            value: $tf.stuckThresholdMinutes, in: 1...60)
                        .fixedSize()
                        .onChange(of: tf.stuckThresholdMinutes) { _, _ in tf.saveConfig() }
                }

                HStack {
                    VStack(alignment: .leading) {
                        Text("Fade opacity when terminal focused")
                        Text("How visible the overlay is when you're actively using a terminal window")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(Int(tf.fadeOpacity * 100))%")
                        .foregroundStyle(.secondary)
                        .frame(width: 36)
                }

                Slider(value: $tf.fadeOpacity, in: 0.04...0.40, step: 0.02) {
                    EmptyView()
                } minimumValueLabel: {
                    Text("4%").font(.caption2)
                } maximumValueLabel: {
                    Text("40%").font(.caption2)
                }
                .onChange(of: tf.fadeOpacity) { _, _ in tf.saveConfig() }

                Toggle(isOn: $tf.autoHideWhenTerminalInactive) {
                    VStack(alignment: .leading) {
                        Text("Auto-hide when Terminal isn't frontmost")
                        Text("Overlay disappears the moment you switch to any non-Terminal app, reappears when Terminal regains focus.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: tf.autoHideWhenTerminalInactive) { _, _ in
                    tf.saveConfig()
                    tf.refresh()
                }
            }
        }
    }

    // MARK: - Corner Assignment

    private var cornerSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Corner Assignment", systemImage: "square.grid.2x2")
                .font(.headline)

            Text("Pin a session to each corner. \"Auto\" lets Grux assign spatially based on window position.")
                .font(.caption)
                .foregroundStyle(.secondary)

            let corners: [(OverlayCorner, String)] = [
                (.topLeft, "Top Left"), (.topRight, "Top Right"),
                (.bottomLeft, "Bottom Left"), (.bottomRight, "Bottom Right")
            ]

            // `.adaptive` with a sensible minimum lets the grid collapse to
            // 1 column on narrow detail panes - prevents the picker cells
            // from forcing the view wider than its container (which was
            // pushing the leading edge under the sidebar).
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)], spacing: 10) {
                ForEach(corners, id: \.0) { corner, label in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Picker("", selection: Binding(
                            get: { tf.pinnedCorners[corner] ?? "" },
                            set: { tf.pinCorner(corner, tty: $0.isEmpty ? nil : $0) }
                        )) {
                            Text("Auto").tag("")
                            ForEach(tf.allSessions) { session in
                                Text(session.summary.isEmpty ? session.tty : "\(session.projectName) (\(session.tty))")
                                    .tag(session.tty)
                            }
                        }
                        .labelsHidden()
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    // MARK: - Hook

    private var hookSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Claude Code Hook", systemImage: "chevron.left.forwardslash.chevron.right")
                .font(.headline)

            Text("The hook fires after every `TodoWrite` tool call and writes a session context file to `~/.grux/focus/`. Zero extra API calls. Context is derived from your existing task list.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                if tf.hookInstalled {
                    Label("Installed", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.callout)
                } else {
                    Label("Not installed", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }

                Spacer()

                if showHookSuccess {
                    Text("Installed ✓")
                        .foregroundStyle(.green)
                        .font(.callout)
                        .transition(.opacity)
                }

                Button(tf.hookInstalled ? "Reinstall Hook" : "Install Hook") {
                    installHook()
                }
                .buttonStyle(.borderedProminent)
                .tint(tf.hookInstalled ? .secondary : .green)
            }

            if let err = hookError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Text("Hook path: \(tf.hookScriptURL.path)")
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
    }

    private func installHook() {
        hookError = nil
        do {
            try tf.installHook()
            showHookSuccess = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                showHookSuccess = false
            }
        } catch {
            hookError = error.localizedDescription
        }
    }

    // MARK: - Sessions

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Active Sessions", systemImage: "terminal")
                .font(.headline)

            ForEach(tf.allSessions) { session in
                SessionRowView(session: session)
            }
        }
    }

    // MARK: - Task 9 helpers (Claude session mapping + hotkey)

    // Drives the ForEach inside the "Claude session mapping" Section. Tuple
    // shape `(OverlayCorner, String)` so the label text can vary per row.
    private var cornerPickerRows: [(OverlayCorner, String)] {
        [
            (.topLeft, "Top-left"),
            (.topRight, "Top-right"),
            (.bottomLeft, "Bottom-left"),
            (.bottomRight, "Bottom-right"),
        ]
    }

    // Bridges the per-corner @State to TerminalFocusState.setSessionMapping.
    // Writing through the binding updates both the local picker state AND
    // the persisted config in one step (no separate .onChange needed).
    private func binding(for corner: OverlayCorner) -> Binding<String?> {
        Binding<String?>(
            get: {
                switch corner {
                case .topLeft:     return topLeftPick
                case .topRight:    return topRightPick
                case .bottomLeft:  return bottomLeftPick
                case .bottomRight: return bottomRightPick
                }
            },
            set: { newValue in
                switch corner {
                case .topLeft:     topLeftPick = newValue
                case .topRight:    topRightPick = newValue
                case .bottomLeft:  bottomLeftPick = newValue
                case .bottomRight: bottomRightPick = newValue
                }
                state.setSessionMapping(newValue, for: corner)
            }
        )
    }

    // Short relative-time string for Picker labels - "now" / "5s" / "3m" /
    // "2h" / "4d". Keep it tight: these render inside a Picker row where
    // horizontal space is at a premium.
    private func relativeString(_ date: Date) -> String {
        let secs = Int(Date().timeIntervalSince(date))
        if secs < 5       { return "now" }
        if secs < 60      { return "\(secs)s" }
        if secs < 3600    { return "\(secs / 60)m" }
        if secs < 86_400  { return "\(secs / 3600)h" }
        return "\(secs / 86_400)d"
    }

    // Cap a session title for popup labels. NSPopUpButton sizes itself to
    // the longest menu item, so an unclipped title blows the pane's
    // intrinsic width past the window and shoves the sidebar off-screen.
    static func clipped(_ title: String, max: Int = 44) -> String {
        title.count <= max ? title : String(title.prefix(max - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

// MARK: - KeyCaptureView (Task 9)
//
// Invisible NSView that becomes first responder the moment it mounts and
// reports the next keyDown event back via a closure. Used by the "Record
// new combo…" flow. Esc cancels (both args nil). Unmodified key presses
// are ignored - a bare "T" as a global hotkey would eat every "T" you
// type anywhere. At least one modifier (⌘/⌥/⇧/⌃) is required.
private struct KeyCaptureView: NSViewRepresentable {
    let onCapture: (UInt32?, UInt32?) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = KeyCaptureNSView()
        v.onCapture = onCapture
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let v = nsView as? KeyCaptureNSView {
            v.onCapture = onCapture
        }
    }
}

private final class KeyCaptureNSView: NSView {
    var onCapture: ((UInt32?, UInt32?) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Steal focus so the very next keystroke lands here. If another
        // subview grabs focus later, the recording banner stays put until
        // the user hits Esc or clicks "Record…" again.
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        // Esc = cancel. Don't fall through to super - we want to swallow it
        // so Settings doesn't close.
        if event.keyCode == 53 {
            onCapture?(nil, nil)
            return
        }

        // Translate NSEvent.ModifierFlags → Carbon flag values. Matching
        // HotkeyConfig's persisted format keeps the persisted JSON
        // readable and avoids a second translation layer in GlobalHotkey.
        var carbon: UInt32 = 0
        let f = event.modifierFlags
        if f.contains(.command)  { carbon |= 256 }
        if f.contains(.option)   { carbon |= 2048 }
        if f.contains(.shift)    { carbon |= 512 }
        if f.contains(.control)  { carbon |= 4096 }

        // Reject unmodified key presses - a global hotkey on a bare letter
        // would swallow that letter in every text field system-wide.
        guard carbon != 0 else { return }

        onCapture?(UInt32(event.keyCode), carbon)
    }
}

private struct SessionRowView: View {
    let session: TerminalSession
    @ObservedObject private var tf = TerminalFocusState.shared

    private var isStuck: Bool { session.isStuck(thresholdMinutes: tf.stuckThresholdMinutes) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Status dot
            Circle()
                .fill(isStuck ? Color.orange : (session.isActive ? Color.green : Color.secondary.opacity(0.4)))
                .frame(width: 8, height: 8)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(session.projectName)
                        .font(.callout.bold())
                    if isStuck {
                        Text("stuck")
                            .font(.caption2.bold())
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.orange.opacity(0.15))
                            .foregroundStyle(.orange)
                            .clipShape(Capsule())
                    }
                    Spacer()
                    Text(session.ageString + " ago")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(session.tty)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.quaternary)
                }

                Text(session.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                // Task summary line
                let done = session.tasks.filter { $0.status == .completed }.count
                let total = session.tasks.count
                if total > 0 {
                    Text("\(done)/\(total) tasks done")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
