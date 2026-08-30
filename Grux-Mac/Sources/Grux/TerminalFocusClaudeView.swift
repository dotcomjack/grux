import SwiftUI
import AppKit

// TerminalFocusClaudeView - v1 Claude-session overlay.
//
// Fills the floating 60%×60% NSPanel that replaces the empty "5th position"
// when 4 Claude Code sessions are tiled into the screen corners. Renders a
// 2×2 grid of CornerLabel views, each reflecting a ClaudeSessionSnapshot
// published by TerminalFocusState / ClaudeSessionTailer. A center × button
// lets the user park the overlay (TerminalFocusState.hideOverlay()).
//
// Styled via GruxTheme tokens - ultraThinMaterial background, iridescent
// rim on a hud-radius RoundedRectangle, textPrimary/Secondary/Tertiary for
// the 4 per-cell lines.
@MainActor
struct TerminalFocusClaudeView: View {
    @ObservedObject private var state = TerminalFocusState.shared

    // Ticker so "12s ago" / "3m ago" relative strings animate forward even
    // when no new JSONL lines arrive. Publishes every 5s; CornerLabel reads
    // snapshot.relativeLastMessage which recomputes against `Date()` on
    // every body rebuild.
    @State private var now = Date()
    private let ticker = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    init() {}

    var body: some View {
        ZStack {
            // Denser backdrop: regularMaterial reads well on both dark desktop
            // wallpapers and over Terminal.app's dark background. The dark tint
            // on top keeps text contrast high regardless of what's behind.
            RoundedRectangle(cornerRadius: GruxTheme.Radius.hud, style: .continuous)
                .fill(.regularMaterial)
            RoundedRectangle(cornerRadius: GruxTheme.Radius.hud, style: .continuous)
                .fill(GruxTheme.base.opacity(0.55))

            // Adaptive grid: render N×M cells matching the inferred Terminal
            // cockpit shape. Default (2,2) preserves the original two-VStacks-
            // of-HStacks layout via cornerSnapshots; any other shape uses a
            // LazyVGrid driven by slotSnapshots (row-major). Both paths feed
            // CornerLabel so styling stays uniform.
            if state.gridCols == 2 && state.gridRows == 2 {
                cornerGrid2x2
            } else {
                adaptiveGrid
            }

            // Centered close affordance. Always clickable; uses a transparent
            // plain button so the visual weight is tiny.
            closeButton
        }
        .overlay(
            RoundedRectangle(cornerRadius: GruxTheme.Radius.hud, style: .continuous)
                .strokeBorder(GruxTheme.iridescentRim, lineWidth: 2)
        )
        .shadow(color: Color.black.opacity(0.45), radius: 24, x: 0, y: 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onReceive(ticker) { now = $0 }
    }

    // Original 2×2 layout: two stacked HStacks reading directly from the
    // OverlayCorner-keyed cornerSnapshots dict.
    private var cornerGrid2x2: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                CornerLabel(corner: .topLeft, snapshot: state.cornerSnapshots[.topLeft], now: now)
                CornerLabel(corner: .topRight, snapshot: state.cornerSnapshots[.topRight], now: now)
            }
            HStack(spacing: 10) {
                CornerLabel(corner: .bottomLeft, snapshot: state.cornerSnapshots[.bottomLeft], now: now)
                CornerLabel(corner: .bottomRight, snapshot: state.cornerSnapshots[.bottomRight], now: now)
            }
        }
        .padding(14)
    }

    // Adaptive N×M layout. Maps each row-major slot index to the
    // corresponding ClaudeSessionSnapshot from state.slotSnapshots; uses
    // synthetic OverlayCorner.topLeft for non-corner cells (the corner arg
    // only drives a faint per-cell tint; functionally cosmetic).
    private var adaptiveGrid: some View {
        let cols = max(1, state.gridCols)
        let rows = max(1, state.gridRows)
        let total = cols * rows
        let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: cols)
        // Pad / truncate so the grid is always rectangular even if the
        // snapshot array hasn't caught up to the inferred shape yet.
        let snaps: [ClaudeSessionSnapshot?] = {
            var s = state.slotSnapshots
            if s.count < total { s.append(contentsOf: Array(repeating: nil, count: total - s.count)) }
            if s.count > total { s = Array(s.prefix(total)) }
            return s
        }()
        return LazyVGrid(columns: columns, spacing: 10) {
            ForEach(0..<total, id: \.self) { i in
                CornerLabel(corner: cornerForIndex(i, cols: cols), snapshot: snaps[i], now: now)
            }
        }
        .padding(14)
    }

    // Synthesize an OverlayCorner for cells beyond the 2×2 case. CornerLabel
    // uses the corner only for a faint per-cell visual hint, so an
    // approximate quadrant mapping is fine for the adaptive grid.
    private func cornerForIndex(_ i: Int, cols: Int) -> OverlayCorner {
        let col = i % cols
        let isLeft = col < cols / 2 || (cols == 1)
        let isTop = (i / cols) < (max(1, state.gridRows) / 2 + (state.gridRows % 2))
        switch (isLeft, isTop) {
        case (true, true):   return .topLeft
        case (false, true):  return .topRight
        case (true, false):  return .bottomLeft
        default:             return .bottomRight
        }
    }

    private var closeButton: some View {
        // Switched from SwiftUI Button to an explicit tap gesture. On a
        // .nonactivatingPanel hosted SwiftUI root, Button was firing its
        // action shortly after the panel became visible (no user click),
        // which dismissed the overlay on every launch. onTapGesture only
        // fires on an actual mouseDown+mouseUp pair inside the hit region.
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.55))
            Circle()
                .strokeBorder(GruxTheme.iridescentRim, lineWidth: 1)
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(GruxTheme.textSecondary)
        }
        .frame(width: 28, height: 28)
        .shadow(color: GruxTheme.violetGlow(), radius: 10)
        .contentShape(Circle())
        .onTapGesture { state.hideOverlay() }
        .help("Hide Terminal Focus overlay")
        .accessibilityLabel("Hide overlay")
    }
}

// MARK: - CornerLabel

// One cell of the 2×2 grid. When `snapshot` is nil, renders a subtle
// "- unassigned -" placeholder aligned to the cell's corner so the empty
// state still reinforces which slot the user would be filling. When a
// snapshot is present, lays out 4 lines per the design doc:
//   1. title (+ gitBranch pill)
//   2. relativeLastMessage · currentTool?  (falls back to cwd basename)
//   3. displayTokens · displayCost
//   4. lastAssistantSummary (2-line cap)
private struct CornerLabel: View {
    let corner: OverlayCorner
    let snapshot: ClaudeSessionSnapshot?
    let now: Date

    var body: some View {
        ZStack {
            // Per-cell card - an ultraThinMaterial block that reads as a
            // distinct tile on top of the panel's regularMaterial backdrop.
            // Subtle white stroke delineates each cell's bounds.
            RoundedRectangle(cornerRadius: GruxTheme.Radius.card, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: GruxTheme.Radius.card, style: .continuous)
                .fill(Color.white.opacity(0.05))
            RoundedRectangle(cornerRadius: GruxTheme.Radius.card, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.75)

            if let snapshot {
                contentView(snapshot: snapshot)
                    .padding(14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: cellAlignment)
            } else {
                Text("(unassigned)")
                    .font(GruxTheme.Font.caption)
                    .foregroundStyle(GruxTheme.textTertiary)
                    .padding(14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: cellAlignment)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Content

    @ViewBuilder
    private func contentView(snapshot: ClaudeSessionSnapshot) -> some View {
        VStack(alignment: hStackAlignment, spacing: 6) {
            // Line 1: title + optional gitBranch capsule
            titleLine(snapshot: snapshot)

            // Line 2: relative time · currentTool?  (fallback: cwd basename)
            metaLine(snapshot: snapshot)

            // Line 3: tokens · cost
            Text("\(snapshot.displayTokens) · \(snapshot.displayCost)")
                .font(GruxTheme.Font.mono)
                .foregroundStyle(GruxTheme.textTertiary)
                .lineLimit(1)

            // Line 4: capped 2-line assistant summary
            if !snapshot.lastAssistantSummary.isEmpty {
                Text(snapshot.lastAssistantSummary)
                    .font(GruxTheme.Font.body)
                    .foregroundStyle(GruxTheme.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(textAlignment)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func titleLine(snapshot: ClaudeSessionSnapshot) -> some View {
        HStack(spacing: 6) {
            if hStackAlignment == .trailing {
                Spacer(minLength: 0)
            }
            Text(snapshot.title)
                .font(GruxTheme.Font.title)
                .foregroundStyle(GruxTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let branch = snapshot.gitBranch, !branch.isEmpty {
                Text(branch)
                    .font(GruxTheme.Font.microCaps)
                    .kerning(0.8)
                    .foregroundStyle(GruxTheme.accentPrimary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(GruxTheme.accentPrimary.opacity(0.25))
                    )
                    .overlay(
                        Capsule().stroke(GruxTheme.accentPrimary.opacity(0.35), lineWidth: 0.5)
                    )
                    .lineLimit(1)
            }
            if hStackAlignment == .leading {
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private func metaLine(snapshot: ClaudeSessionSnapshot) -> some View {
        // Reference `now` so SwiftUI re-evaluates this line when the ticker
        // fires; snapshot.relativeLastMessage is a computed helper that
        // recomputes against Date() each call.
        let _ = now
        let primary = snapshot.relativeLastMessage
        let cwdBase: String? = {
            guard let cwd = snapshot.cwd, !cwd.isEmpty else { return nil }
            let base = (cwd as NSString).lastPathComponent
            return base.isEmpty ? nil : base
        }()

        HStack(spacing: 6) {
            if hStackAlignment == .trailing {
                Spacer(minLength: 0)
            }
            Text(primary)
                .font(GruxTheme.Font.caption)
                .foregroundStyle(GruxTheme.textSecondary)
                .lineLimit(1)

            if let tool = snapshot.currentTool, !tool.isEmpty {
                Text("·")
                    .font(GruxTheme.Font.caption)
                    .foregroundStyle(GruxTheme.textTertiary)
                Text(tool)
                    .font(GruxTheme.Font.caption)
                    .foregroundStyle(GruxTheme.textSecondary)
                    .lineLimit(1)
            } else if let base = cwdBase {
                Text("·")
                    .font(GruxTheme.Font.caption)
                    .foregroundStyle(GruxTheme.textTertiary)
                Text(base)
                    .font(GruxTheme.Font.caption)
                    .foregroundStyle(GruxTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if hStackAlignment == .leading {
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: Corner-driven alignment

    private var cellAlignment: Alignment {
        switch corner {
        case .topLeft: return .topLeading
        case .topRight: return .topTrailing
        case .bottomLeft: return .bottomLeading
        case .bottomRight: return .bottomTrailing
        }
    }

    private var hStackAlignment: HorizontalAlignment {
        switch corner {
        case .topLeft, .bottomLeft: return .leading
        case .topRight, .bottomRight: return .trailing
        }
    }

    private var textAlignment: TextAlignment {
        switch corner {
        case .topLeft, .bottomLeft: return .leading
        case .topRight, .bottomRight: return .trailing
        }
    }
}
