import SwiftUI

// Blueprint 02 "Design primitives": the type scale and the 4/8/12/16/24
// spacing scale as named static tokens. Every PIM tab sweeps its ad hoc
// font sizes and paddings onto these so the surfaces stop drifting apart.

// MARK: - Spacing scale

// The only padding/spacing values new UI should use. 4/8/12/16/24.
enum GruxSpacing {
    /// 4pt: hairline gaps, icon-to-text inside chips.
    static let xs: CGFloat = 4
    /// 8pt: row internals, control clusters.
    static let s: CGFloat = 8
    /// 12pt: card padding, list-column gutters.
    static let m: CGFloat = 12
    /// 16pt: detail-pane padding, section gaps.
    static let l: CGFloat = 16
    /// 24pt: hero spacing, big section breaks.
    static let xl: CGFloat = 24
}

// MARK: - Layout widths

// The shared width budget. Every number here is DERIVED from the main
// window's floor rather than picked: LaunchRootView pins the window at
// 840x560 of content, the nav rail eats 240 of the width, and the hairline
// Divider beside it eats 1 more, so a tab's detail pane can be handed as
// little as 599pt. A view that DEMANDS more than it is handed does not
// scroll, it clips, and because SwiftUI centres an oversized child it clips
// off BOTH edges at once. Settings shipped a hard `.frame(width: 680)` and
// lost text off the left and the right simultaneously; that is the defect
// these tokens exist to make impossible.
//
// Use them as min/ideal/max triples, never as a bare `.frame(width:)`, so a
// pane shrinks toward its floor instead of bleeding past the window edge.
// Fixed width is still correct for things that are not inside the resizable
// window (menu bar popovers, floating HUDs, toasts) and for icons, status
// dots and badges. It is wrong for anything holding content.
enum GruxLayout {
    /// 840pt: the main window's content-width floor (LaunchRootView).
    /// Everything below is measured against it. Raising the rail or a column
    /// without raising this is exactly how clipping comes back.
    static let windowFloorWidth: CGFloat = 840
    /// 560pt: the main window's content-height floor (LaunchRootView).
    static let windowFloorHeight: CGFloat = 560
    /// 240pt: the nav rail, deliberately fixed. It is global chrome rather
    /// than tab content, and it has to hold the longest row ("Terminal
    /// Focus" plus icon plus badge) at every window size, so it is a hard
    /// subtraction from every budget below rather than a share of the width.
    static let navRail: CGFloat = 240
    /// 1pt: one Divider in an HStack. Trivial on its own, and the whole
    /// difference between "600 fits" and "600 overflows by a point".
    static let divider: CGFloat = 1

    /// 599pt: what a tab's detail pane is actually handed at the window
    /// floor. Derived, never typed: 840 window - 240 rail - 1 divider. The
    /// widest tab min in the app is chat at 560, which clears it by 39.
    static let detailPaneFloor: CGFloat = windowFloorWidth - navRail - divider

    /// 360pt: the narrowest a detail pane still reads as one. 16pt
    /// (GruxSpacing.l) of padding per side leaves 328pt of 13pt body text,
    /// roughly 50 characters, which is the low end of a usable measure. A
    /// list column that squeezes its detail below this has starved it.
    static let detailContentMin: CGFloat = 360

    // List column of a list+detail split. The floor plus a readable detail
    // has to fit the pane floor: 220 + 1 divider + 360 = 581 inside 599.
    /// 220pt: floor. Below this a row's icon, title and trailing metadata
    /// start colliding.
    static let listColumnMin: CGFloat = 220
    /// 280pt: what a list+detail tab renders at when nothing says otherwise.
    static let listColumnIdeal: CGFloat = 280
    /// 360pt: ceiling. A wider window should grow the detail, not the index,
    /// and a caller asking for more than this is starving its own detail.
    static let listColumnMax: CGFloat = 360

    /// 140pt: floor for the search field that sits in a list column header or
    /// a toolbar. Derived from the narrowest place it appears: a list column at
    /// its own 220pt floor, less GruxSpacing.m of padding per side, less the
    /// magnifying-glass icon and its gap, leaves roughly 180pt, and 140 keeps
    /// headroom for a trailing button on the same row. Callers pass a `width`
    /// as their IDEAL; this is the point below which the field stops shrinking
    /// and the row wraps or scrolls instead, because a search field that
    /// refuses to shrink pushes the buttons beside it off the edge.
    static let searchFieldMin: CGFloat = 140

    // Sheets and modal panels. A sheet is bounded by the window it hangs
    // off, so its ceiling is the window floor less breathing room: 40pt per
    // side (GruxSpacing.xl + .l) on both axes, so a sheet never runs edge to
    // edge on the smallest window we support.
    /// 380pt: floor. 16pt padding per side leaves 348pt, enough for a ~110pt
    /// label column plus a ~226pt field, the narrowest form row that reads.
    static let sheetMin: CGFloat = 380
    /// 520pt: the default sheet width.
    static let sheetIdeal: CGFloat = 520
    /// 760pt: ceiling. 840 window floor less 40pt per side.
    static let sheetMax: CGFloat = windowFloorWidth - 80
    /// 480pt: height ceiling. 560 window floor less 40pt per side. A sheet
    /// taller than this loses its bottom row (the Save button) on a small
    /// display, which is unrecoverable because a sheet has no scroll of its
    /// own. Pair it with a ScrollView when content can grow.
    static let sheetMaxHeight: CGFloat = windowFloorHeight - 80

    /// 1200pt: the widest a tab's CONTENT COLUMN grows, matching the house
    /// content width used across the other surfaces in this app.
    ///
    /// Every width above is a floor, guarding against starvation at the 840pt
    /// window. This is the opposite guard, and it was missing entirely until a
    /// sweep at 2400pt went looking. Past roughly this width a card and form
    /// stack stops being a layout and becomes a row of stranded elements.
    /// Measured on Settings at 2400: "Start: 5 AM" sat at the far left with its
    /// slider running about 1700pt to the right, the first-run paragraph
    /// rendered as a single line about 1700pt wide (a readable measure is
    /// closer to 75 characters), and "Run it again" ended up roughly 1600pt
    /// from the sentence it acts on.
    ///
    /// This is inert at the floor: the detail pane is handed 599 there, so the
    /// cap never binds and narrow layout is unchanged.
    ///
    /// NOT for every tab. A list+detail split is already bounded by its list
    /// column, and a canvas (Cognition Map, the Reactor rings) is supposed to
    /// use the whole pane. Apply it to prose, form and card stacks.
    static let contentMax: CGFloat = 1200

    /// Clamps a caller-supplied list-column width into the shared range.
    /// A tab asking for 500 is not honoured: at the window floor that leaves
    /// the detail pane under `detailContentMin` and the detail is the point
    /// of a list+detail split.
    static func listColumnWidth(_ requested: CGFloat) -> CGFloat {
        min(max(requested, listColumnMin), listColumnMax)
    }
}

// MARK: - Type scale

// Named type roles. These forward to GruxTheme.Font so the canonical scale
// lives in exactly one place; views reference the role, not a point size.
enum GruxType {
    /// 28pt heavy condensed. Tab hero titles only.
    static let display = GruxTheme.Font.display
    /// 17pt bold. Section and pane titles.
    static let title = GruxTheme.Font.title
    /// 13pt medium. Default reading text.
    static let body = GruxTheme.Font.body
    /// 11pt semibold. Secondary metadata.
    static let caption = GruxTheme.Font.caption
    /// 11pt mono. Logs, tags, technical strings.
    static let mono = GruxTheme.Font.mono
    /// 9pt heavy mono caps. Chip labels, kicker lines.
    static let microCaps = GruxTheme.Font.microCaps
}
