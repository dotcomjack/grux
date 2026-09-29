import SwiftUI

/// Recent surfaces, the Watching control, the listening status, approvals
/// when any wait, and the Settings gear. Written fresh for the panel; the legacy
/// rail's foot stays in LaunchRootView for the classic shell.
struct PanelFoot: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var sidebarStore = SidebarStateStore.shared
    @ObservedObject private var speech = SpeechEngine.shared
    @ObservedObject private var micHealth = MicHealth.shared
    /// Opens a surface by its locked key.
    var onOpen: (String) -> Void
    var onSettings: () -> Void

    /// How many Recent chips the foot shows at most. `chipMaxWidth` divides
    /// the panel by the same number.
    static let chipCap = 5

    /// Up to `chipCap`, pinned first, then most recent, never a duplicate,
    /// never Settings, which has its own gear, and never a key the live tab
    /// registry does not know (a retired surface, a hand-edited file).
    static func chips(pinned: [String], recents: [String], cap: Int = chipCap) -> [String] {
        var out: [String] = []
        for k in pinned + recents where !out.contains(k) && k != "settings" && SidebarIA.item(forKey: k) != nil {
            out.append(k)
        }
        return Array(out.prefix(cap))
    }

    private var tell: ListeningTell {
        ListeningTell.resolve(state: state, speech: speech, notHearing: micHealth.notHearing)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: GruxSpacing.s) {
            let chips = Self.chips(pinned: sidebarStore.pinned, recents: sidebarStore.recents)
            if !chips.isEmpty {
                Text(PanelCopy.recentHeading.uppercased())
                    .font(GruxType.microCaps)
                    .kerning(GruxType.microCapsTracking)
                    .foregroundStyle(GruxTheme.textTertiary)
                Self.chipRow(chips) { chip($0) }
            }
            Divider()
            HStack(spacing: GruxSpacing.s) {
                watchingControl
                listeningStatus
                ApprovalsTrayButton()
                Spacer(minLength: 0)
                Button { onSettings() } label: {
                    Image(systemName: "gearshape.fill")
                        .font(GruxType.caption)
                        .foregroundStyle(GruxTheme.textSecondary)
                }
                .buttonStyle(.borderless)
                .help(PanelCopy.settings)
                .accessibilityLabel(PanelCopy.settings)
            }
        }
    }

    /// The gap between two Recent chips.
    static let chipSpacing = GruxSpacing.xs

    /// The widest one chip draws: half the panel inside its padding, less the
    /// gap. Wide enough that every label the rail knows reads whole; a label
    /// longer than that truncates with a tail rather than stretching the row.
    ///
    /// It used to be a fifth of the panel, so five chips always fitted by
    /// truncating each one, and "Focus log" rendered as "Fo...": the row fitted
    /// and said nothing. The row drops the chips that do not fit instead
    /// (`chipRow`), so a label no longer has to give up its words to make room
    /// for its neighbours.
    static let chipMaxWidth = (GruxLayout.panelWidth - 2 * GruxSpacing.l) / 2 - chipSpacing

    /// The Recent row: as many chips as fit whole, in order, at their own
    /// widths. The rest are not drawn. Never wider than the panel it sits in
    /// (R12.3), and never a chip cut at the panel edge: a scrolling row under a
    /// fade drew the last chip in half ("Meta", "Sel"), which reads as broken,
    /// not as more (D-chips). Every chip stays one click away in the palette.
    static func chipRow<Chip: View>(_ keys: [String], @ViewBuilder chip: @escaping (String) -> Chip) -> some View {
        ViewThatFits(in: .horizontal) {
            ForEach(Array(stride(from: keys.count, through: 1, by: -1)), id: \.self) { n in
                HStack(spacing: chipSpacing) {
                    ForEach(keys.prefix(n), id: \.self) { chip($0) }
                }
            }
        }
    }

    /// What one Recent chip draws. Shared with the test that measures five of
    /// them against the panel. `fixedSize` after the cap keeps a short label
    /// at its own width; a bare `maxWidth` frame stretches it to the cap.
    static func chipFace(_ key: String) -> some View {
        Label(SidebarIA.railLabel(forKey: key), systemImage: SidebarIA.railIcon(forKey: key))
            .font(GruxType.caption)
            .foregroundStyle(GruxTheme.textSecondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, GruxSpacing.s)
            .frame(maxWidth: chipMaxWidth)
            .fixedSize()
            .padding(.vertical, GruxSpacing.xs)
            .background(Capsule().fill(GruxTheme.chipFill))
    }

    private func chip(_ key: String) -> some View {
        Button { onOpen(key) } label: { Self.chipFace(key) }
        .buttonStyle(.plain)
        .contextMenu {
            if sidebarStore.isPinned(key) {
                Button(PanelCopy.unpin) { sidebarStore.unpin(key) }
            } else {
                Button(PanelCopy.pin) { sidebarStore.pin(key) }
            }
        }
    }

    /// Whether focus watching runs, and the one button that flips it.
    private var watchingControl: some View {
        HStack(spacing: GruxSpacing.xs) {
            Circle()
                .fill(state.watching ? GruxTheme.successMint : GruxTheme.textTertiary)
                .frame(width: GruxSpacing.s, height: GruxSpacing.s)
            Text(state.watching ? PanelCopy.watching : PanelCopy.paused)
                .font(GruxType.caption)
                .foregroundStyle(GruxTheme.textSecondary)
            Button(state.watching ? PanelCopy.pause : PanelCopy.watch) {
                state.watching ? FocusWatcher.shared.stop() : FocusWatcher.shared.start()
            }
            .buttonStyle(.borderless)
            .font(GruxType.caption)
        }
    }

    /// What the microphone is doing, in the shared tell's word. A status,
    /// not a control: the input's mic and the orb are the toggles, and a
    /// third one here would be the same switch twice (R5.19).
    private var listeningStatus: some View {
        Text(tell.label)
            .font(GruxType.caption)
            .foregroundStyle(tell == .muted || tell == .off ? GruxTheme.textTertiary : GruxTheme.successMint)
            .help(tell.help)
            .accessibilityLabel(PanelCopy.micLabel(tell))
    }
}
