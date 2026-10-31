import SwiftUI

// The fluid-layout primitives. Every surface the Command Panel opens has to
// render from its pane's floor (`GruxLayout.detailContentMin`) to any width,
// and a surface built for the classic sidebar's wide detail area did not:
// fixed rows and fixed columns overflowed the pane and SwiftUI centred them,
// so they spilled past both edges. These are the few shapes that come up over
// and over, written once so a surface reflows instead of picking a number.
// PaneFitSweepTests holds every surface to them.

// MARK: - Width switch

/// Shows `wide` when the offer is at least `threshold` and `narrow` below it.
///
/// Built on `ViewThatFits`, which compares a candidate's IDEAL width with the
/// offer. A row's ideal width is usually its unwrapped text, far wider than it
/// needs, so the wide candidate is given an ideal of exactly `threshold`: the
/// switch then happens at the width the caller names, and above it the wide
/// candidate still fills whatever it is offered.
struct GruxWidthSwitch<Wide: View, Narrow: View>: View {
    let threshold: CGFloat
    @ViewBuilder var wide: () -> Wide
    @ViewBuilder var narrow: () -> Narrow

    init(threshold: CGFloat, @ViewBuilder wide: @escaping () -> Wide, @ViewBuilder narrow: @escaping () -> Narrow) {
        self.threshold = threshold
        self.wide = wide
        self.narrow = narrow
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            wide().frame(minWidth: 0, idealWidth: threshold, maxWidth: .infinity)
            narrow()
        }
    }
}

// MARK: - Title and actions

/// A heading and its action chips on one row when every chip fits whole, and
/// otherwise the heading over the chips, which wrap onto as many rows as the
/// width needs. `GruxToolbar` does the same for a pane's own header; this is
/// the shape for a header inside a card or an editor. A chip's label
/// truncates rather than wraps (see `GruxChip`), so sharing one row that is
/// too narrow cut the Presets editor's actions to "APPLY...", "DUPLI..." and
/// "DELE...", leaving Delete a guess. PaneFitSweepTests fails on any cut chip.
///
/// A layout, not `ViewThatFits`: measured, that one also placed the
/// arrangement it did not pick, its chips squeezed to 15 to 19pt, even on a
/// 1200pt pane where the one row fit, so no probe could tell a real cut.
struct GruxTitleActions<Heading: View, Actions: View>: View {
    var spacing: CGFloat = GruxSpacing.s
    @ViewBuilder var heading: () -> Heading
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        GruxTitleActionsLayout(spacing: spacing) {
            // One subview, whatever the caller's builder holds.
            VStack(alignment: .leading, spacing: 0) { heading() }
            actions()
        }
    }
}

/// The first subview is the heading; every other one is an action, kept at
/// its own width.
struct GruxTitleActionsLayout: Layout {
    var spacing: CGFloat

    private struct Arrangement {
        var oneRow: Bool
        var heading: CGSize
        /// Each action's origin, from the layout's top leading corner.
        var origins: [CGPoint]
        var sizes: [CGSize]
        var size: CGSize
    }

    private func arrange(_ subviews: Subviews, width: CGFloat?) -> Arrangement {
        guard let head = subviews.first else {
            return Arrangement(oneRow: true, heading: .zero, origins: [], sizes: [], size: .zero)
        }
        let actions = Array(subviews.dropFirst())
        let headIdeal = head.sizeThatFits(.unspecified)
        let ideals = actions.map { $0.sizeThatFits(.unspecified) }
        let actionsWidth = ideals.map(\.width).reduce(0, +) + spacing * CGFloat(max(0, ideals.count - 1))
        let gap = ideals.isEmpty ? 0 : spacing
        let rowWidth = headIdeal.width + gap + actionsWidth

        if width.map({ rowWidth <= $0 }) ?? true {
            let total = width ?? rowWidth
            let height = max(headIdeal.height, ideals.map(\.height).max() ?? 0)
            var x = total - actionsWidth
            var origins: [CGPoint] = []
            for size in ideals {
                origins.append(CGPoint(x: x, y: (height - size.height) / 2))
                x += size.width + spacing
            }
            return Arrangement(oneRow: true, heading: headIdeal, origins: origins, sizes: ideals,
                               size: CGSize(width: total, height: height))
        }

        // Stacked: the heading at the full width, then the actions in rows,
        // each at its own width, a new row whenever the next would not fit.
        let total = width ?? rowWidth
        let heading = head.sizeThatFits(ProposedViewSize(width: total, height: nil))
        var y = heading.height + spacing
        var x: CGFloat = 0
        var rowHeight: CGFloat = 0
        var origins: [CGPoint] = []
        var sizes: [CGSize] = []
        for (i, ideal) in ideals.enumerated() {
            let size = ideal.width > total
                ? actions[i].sizeThatFits(ProposedViewSize(width: total, height: nil)) : ideal
            if x > 0, x + size.width > total {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            sizes.append(size)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        let height = ideals.isEmpty ? heading.height : y + rowHeight
        return Arrangement(oneRow: false, heading: CGSize(width: min(heading.width, total), height: heading.height),
                           origins: origins, sizes: sizes, size: CGSize(width: total, height: height))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        return arrange(subviews, width: width).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let a = arrange(subviews, width: bounds.width)
        guard let head = subviews.first else { return }
        let headY = a.oneRow ? (a.size.height - a.heading.height) / 2 : 0
        head.place(at: CGPoint(x: bounds.minX, y: bounds.minY + headY), anchor: .topLeading,
                   proposal: ProposedViewSize(a.heading))
        for (i, view) in subviews.dropFirst().enumerated() {
            view.place(at: CGPoint(x: bounds.minX + a.origins[i].x, y: bounds.minY + a.origins[i].y),
                       anchor: .topLeading, proposal: ProposedViewSize(a.sizes[i]))
        }
    }
}

// MARK: - Flow

/// Lays its children out in a row and wraps to a new row whenever the next
/// child would pass the offered width. For control clusters and chip rows
/// that would otherwise push past the edge of a narrow pane. A child wider
/// than the whole offer gets a row of its own, offered the full width.
struct GruxFlow: Layout {
    var spacing: CGFloat = GruxSpacing.s
    var rowSpacing: CGFloat = GruxSpacing.s
    var alignment: VerticalAlignment = .center

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func rows(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for (i, view) in subviews.enumerated() {
            let size = measured(view, width: width)
            let next = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if !row.indices.isEmpty, next > width {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(i)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }

    /// A child at its own ideal width, never wider than the offer.
    private func measured(_ view: LayoutSubview, width: CGFloat) -> CGSize {
        let ideal = view.sizeThatFits(.unspecified)
        guard ideal.width > width else { return ideal }
        return view.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? .greatestFiniteMagnitude
        let laid = rows(subviews, width: width)
        let height = laid.map(\.height).reduce(0, +) + rowSpacing * CGFloat(max(0, laid.count - 1))
        let used = laid.map(\.width).max() ?? 0
        return CGSize(width: width == .greatestFiniteMagnitude ? used : min(width, max(used, 0)), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, width: bounds.width) {
            var x = bounds.minX
            for i in row.indices {
                let size = measured(subviews[i], width: bounds.width)
                let dy: CGFloat
                switch alignment {
                case .top: dy = 0
                case .bottom: dy = row.height - size.height
                default: dy = (row.height - size.height) / 2
                }
                subviews[i].place(at: CGPoint(x: x, y: y + dy), anchor: .topLeading,
                                  proposal: ProposedViewSize(width: size.width, height: size.height))
                x += size.width + spacing
            }
            y += row.height + rowSpacing
        }
    }
}

// MARK: - Adaptive inset

/// Horizontal padding that gives ground on a narrow offer: `wide` on each side
/// when the offer is at least `threshold`, `narrow` below it. A hero margin
/// that reads as generous on a wide pane eats a third of a narrow one.
struct GruxAdaptiveInset: Layout {
    let wide: CGFloat
    let narrow: CGFloat
    let threshold: CGFloat

    private func inset(_ width: CGFloat?) -> CGFloat {
        guard let width, width.isFinite else { return wide }
        return width < threshold ? narrow : wide
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let i = inset(proposal.width)
        let inner = proposal.width.map { $0.isFinite ? max(0, $0 - 2 * i) : $0 }
        let size = child.sizeThatFits(ProposedViewSize(width: inner, height: proposal.height))
        return CGSize(width: size.width + 2 * i, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let i = inset(bounds.width)
        subviews.first?.place(at: CGPoint(x: bounds.minX + i, y: bounds.minY), anchor: .topLeading,
                              proposal: ProposedViewSize(width: max(0, bounds.width - 2 * i), height: bounds.height))
    }
}

extension View {
    /// `wide` points of horizontal padding on a pane at least `threshold`
    /// wide, `narrow` below it. See `GruxAdaptiveInset`.
    func adaptiveHorizontalPadding(_ wide: CGFloat, narrow: CGFloat = GruxSpacing.l,
                                   below threshold: CGFloat = GruxLayout.paneWidth) -> some View {
        GruxAdaptiveInset(wide: wide, narrow: narrow, threshold: threshold) { self }
    }
}

// MARK: - List and detail

/// A list column and its detail, side by side when the offer holds the list
/// at `listColumnMin` and the detail at `detailContentMin`, and stacked below
/// that: the list across the top at `GruxLayout.stackedListHeight`, the detail
/// under it at the full width. Side by side, the list gets its ideal width
/// when the detail can keep its floor, and gives ground toward
/// `listColumnMin` before the detail does.
///
/// One instance of each child in both arrangements, so a list's scroll
/// position and a detail's state survive the switch.
struct GruxSplitLayout: Layout {
    /// The width the list column asks for, clamped into the shared range.
    let listIdeal: CGFloat

    static var sideBySideFloor: CGFloat {
        GruxLayout.listColumnMin + GruxLayout.divider + GruxLayout.detailContentMin
    }

    static func sideBySide(_ width: CGFloat) -> Bool { width >= sideBySideFloor }

    /// The list column's width beside a detail, in a split `width` wide.
    static func listWidth(ideal: CGFloat, in width: CGFloat) -> CGFloat {
        min(ideal, max(GruxLayout.listColumnMin, width - GruxLayout.divider - GruxLayout.detailContentMin))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 3 else { return .zero }
        let detail = subviews[2].sizeThatFits(.unspecified)
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil }
            ?? (listIdeal + GruxLayout.divider + max(detail.width, GruxLayout.detailContentMin))
        let height = proposal.height.flatMap { $0.isFinite ? $0 : nil }
            ?? max(detail.height, GruxLayout.stackedListHeight)
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let (list, rule, detail) = (subviews[0], subviews[1], subviews[2])
        if Self.sideBySide(bounds.width) {
            let lw = Self.listWidth(ideal: listIdeal, in: bounds.width)
            let dw = max(0, bounds.width - lw - GruxLayout.divider)
            list.place(at: bounds.origin, anchor: .topLeading,
                       proposal: ProposedViewSize(width: lw, height: bounds.height))
            rule.place(at: CGPoint(x: bounds.minX + lw, y: bounds.minY), anchor: .topLeading,
                       proposal: ProposedViewSize(width: GruxLayout.divider, height: bounds.height))
            detail.place(at: CGPoint(x: bounds.minX + lw + GruxLayout.divider, y: bounds.minY), anchor: .topLeading,
                         proposal: ProposedViewSize(width: dw, height: bounds.height))
        } else {
            let lh = min(GruxLayout.stackedListHeight, bounds.height / 2)
            let dh = max(0, bounds.height - lh - GruxLayout.divider)
            list.place(at: bounds.origin, anchor: .topLeading,
                       proposal: ProposedViewSize(width: bounds.width, height: lh))
            rule.place(at: CGPoint(x: bounds.minX, y: bounds.minY + lh), anchor: .topLeading,
                       proposal: ProposedViewSize(width: bounds.width, height: GruxLayout.divider))
            detail.place(at: CGPoint(x: bounds.minX, y: bounds.minY + lh + GruxLayout.divider), anchor: .topLeading,
                         proposal: ProposedViewSize(width: bounds.width, height: dh))
        }
    }
}

/// `GruxSplitLayout` with its hairline: the list, the rule, the detail.
struct GruxSplit<ListContent: View, DetailContent: View>: View {
    var listWidth: CGFloat = GruxLayout.listColumnIdeal
    @ViewBuilder var list: () -> ListContent
    @ViewBuilder var detail: () -> DetailContent

    init(listWidth: CGFloat = GruxLayout.listColumnIdeal,
         @ViewBuilder list: @escaping () -> ListContent,
         @ViewBuilder detail: @escaping () -> DetailContent) {
        self.listWidth = listWidth
        self.list = list
        self.detail = detail
    }

    var body: some View {
        GruxSplitLayout(listIdeal: GruxLayout.listColumnWidth(listWidth)) {
            list()
            Rectangle().fill(Color(nsColor: .separatorColor))
            detail()
        }
    }
}
