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
    /// 44pt: the height of the pinned rail tail (Settings) that sits between
    /// the scrolling rail and the status bar. One sidebar row plus the small
    /// inset a `.sidebar` list puts around it. Measured rather than guessed:
    /// a shorter frame clips the row's own padding and the label sits against
    /// the divider.
    static let pinnedRailTailHeight: CGFloat = 44
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

    // MARK: Command Panel (3.0 reskin)
    //
    // The panel is the resting form: one column, no sidebar. A surface opens
    // beside it as ONE pane, and the window grows by `paneWidth` to hold it.
    // With no pane open the window's width floor is `panelWidth` itself: a
    // floor below the fixed panel would clip the panel by the difference.
    // With a pane open it is `panelWidth + detailContentMin`.
    // `windowFloorWidth` and `navRail` above describe the legacy shell and
    // stay until `legacyShell` is removed.

    /// 420pt: the panel column. Wide enough for a seven-row Now list with a
    /// glyph, a title and one action per row at the body size.
    static let panelWidth: CGFloat = 420
    /// 680pt: the pane beside it. Clears chat's 560pt minimum, the widest
    /// surface minimum in the app, with room for the pane bar's close control.
    static let paneWidth: CGFloat = 680
    /// 480pt: the panel's height floor. Head, input, four Now rows, the
    /// collapsed Optimize row and the foot.
    static let panelMinHeight: CGFloat = 480
    /// 560pt: the resting height.
    static let panelIdealHeight: CGFloat = 560
    /// 36pt: the bar across the top of an open pane (name and close).
    static let paneBarHeight: CGFloat = 36
    /// 68pt: the orb as the legacy rail's hero draws it. Its inner core is a
    /// fixed size, so a smaller orb is this one scaled, not re-framed.
    static let railOrb: CGFloat = 68
    /// 44pt: the orb in the panel head (spec 3.2).
    static let panelOrb: CGFloat = 44
    /// 48pt: a screenshot staged on the Change it box, big enough to tell two
    /// apart, small enough that a row of them stays one line in the panel.
    static let attachmentThumb: CGFloat = 48
    /// 200pt: a list column's height when a narrow pane stacks it over its
    /// detail (GruxSplitLayout): five rows of an index, and the rest of the
    /// pane for the thing being read.
    static let stackedListHeight: CGFloat = 200
    /// 196pt: one Reactor telemetry panel. The radial instrument is a canvas,
    /// so its panels keep one size and the pane holds them (reactorPaneMin).
    static let reactorPanelWidth: CGFloat = 196
    /// 150pt: the Reactor's core orb in its compact tier.
    static let reactorCompactOrb: CGFloat = 150
    /// 602pt: the Reactor's honest minimum. Two panel columns either side of
    /// the compact orb with a gap each side, inside the instrument's own
    /// margins; narrower and the panels cover the core they report on.
    static let reactorPaneMin: CGFloat = 2 * reactorPanelWidth + reactorCompactOrb
        + 2 * GruxSpacing.m + 2 * reactorInset
    /// 18pt: the Reactor's side margin around its panel columns.
    static let reactorInset: CGFloat = 18
    /// 340pt: the month grid's floor, seven day columns that still read.
    static let calendarGridMin: CGFloat = 340
    /// 200 to 320pt: the day agenda's range beside the grid.
    static let calendarAgendaMin: CGFloat = 200
    static let calendarAgendaMax: CGFloat = 320
    /// 380pt: the month grid's height when a narrow pane stacks the agenda
    /// under it: six week rows at the grid's 56pt cell floor, the gaps, and
    /// the weekday header.
    static let calendarStackedGridHeight: CGFloat = 380
    /// 440pt: the approvals tray popover. A popover is its own window, not a
    /// share of the pane, so one fixed width is right for it; this one holds
    /// an approval card's title and its Approve and Skip row.
    static let trayPopoverWidth: CGFloat = 440
    /// 340pt: the Meetings archive column's ask, a meeting's title, date and
    /// duration on one row. Clamped into the list column range like any ask.
    static let archiveListIdeal: CGFloat = 340
    /// 240pt: the narrowest a Labs card keeps its title on one line and its
    /// line of copy readable beside the 30pt glyph.
    static let labsCardMin: CGFloat = 240
    /// 260pt: a Settings pane picker as a menu, the form it takes when its
    /// segments do not fit the row.
    static let settingsMenuPickerMax: CGFloat = 260
    /// 140pt: the Tasks add row's project field beside the title field.
    static let taskProjectFieldWidth: CGFloat = 140
    /// 180pt: the Projects filter field's width on a pane wide enough to
    /// hold it beside the title.
    static let projectsFilterWidth: CGFloat = 180
    /// 300pt: the narrowest a Tuning dial card holds its widest control, the
    /// three-segment listening picker (about 260pt), inside its 20pt padding.
    /// Two cards sit side by side only where both get this much.
    static let tuningCardMin: CGFloat = 300
    /// 320pt: the width Design Studio's chat rail asks for on a wide pane.
    static let designRailIdeal: CGFloat = 320
    /// 300pt: Design Studio's preview column floor, beside its chat rail.
    static let designPreviewMin: CGFloat = 300
    /// 521pt: Design Studio's honest minimum: its chat rail at listColumnMin
    /// beside the preview at its floor. A split editor and live preview has
    /// no single-column form worth shipping, so the window holds both.
    static let designStudioPaneMin: CGFloat = listColumnMin + divider + designPreviewMin
    /// 640 x 520pt: the first-run flow's minimum. Wider than the panel, so
    /// the window grows to it while onboarding presents and returns after.
    static let onboardingMinWidth: CGFloat = 640
    static let onboardingMinHeight: CGFloat = 520
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
    /// 14pt regular. The command palette's query field and its glyph: one
    /// step above body so the typed command leads the results under it.
    static let field = GruxTheme.Font.field
    /// 11pt mono. Logs, tags, technical strings.
    static let mono = GruxTheme.Font.mono
    /// 9pt heavy mono caps. Chip labels, kicker lines.
    static let microCaps = GruxTheme.Font.microCaps
    /// Letter spacing for `microCaps` headings ("NOW", "RECENT").
    static let microCapsTracking: CGFloat = 1.2
    /// Letter spacing for the wordmark.
    static let wordmarkTracking: CGFloat = 2
}
