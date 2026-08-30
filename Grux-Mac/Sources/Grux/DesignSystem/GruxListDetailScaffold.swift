import SwiftUI

// Blueprint 02: the list + detail split every PIM tab reinvented. List column
// with the standard darkened backdrop, hairline divider, detail pane filling
// the rest. Selection, keyboard handling, and content stay with the caller;
// this is layout chrome only so behavior is untouched.
struct GruxListDetailScaffold<ListContent: View, DetailContent: View>: View {
    /// The width the column WANTS. It is an ideal, not a demand: see body.
    var listWidth: CGFloat = GruxLayout.listColumnIdeal
    @ViewBuilder let list: () -> ListContent
    @ViewBuilder let detail: () -> DetailContent

    init(listWidth: CGFloat = GruxLayout.listColumnIdeal,
         @ViewBuilder list: @escaping () -> ListContent,
         @ViewBuilder detail: @escaping () -> DetailContent) {
        self.listWidth = listWidth
        self.list = list
        self.detail = detail
    }

    var body: some View {
        HStack(spacing: 0) {
            list()
                // The caller's width is the CEILING, not a fixed size. With a
                // hard `.frame(width:)` the column held its number while the
                // window narrowed and the detail pane absorbed every lost
                // point, until the detail was too narrow for its own content
                // and clipped. Expressed as a range, the HStack hands the
                // column its full ask whenever the pane can afford it (any
                // pane at least twice the ask, which is every ordinary window
                // size) and shrinks it toward listColumnMin first when the
                // pane approaches its 599pt floor. The index degrades before
                // the thing the user is actually reading.
                .frame(minWidth: GruxLayout.listColumnMin,
                       idealWidth: resolvedListWidth,
                       maxWidth: resolvedListWidth)
                .frame(maxHeight: .infinity)
                .background(Color.black.opacity(0.18))
            Divider()
            // The detail DOES claim its floor, and the arithmetic is why this is
            // safe rather than the overflow an earlier version of this comment
            // feared: listColumnMin + divider + detailContentMin is
            // 220 + 1 + 360 = 581, inside the 599pt pane floor with 18pt spare.
            // Without a minimum here the budget was decorative: the token was
            // asserted by LayoutTokenTests and referenced in comments, but no
            // view ever asked for it, so at the pane floor an HStack split the
            // space evenly and handed the detail 299pt, well under the 360 the
            // whole token set exists to protect. Claiming it is what actually
            // forces the index to give ground before the thing being read.
            detail()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// Five tabs call this scaffold and two of them pass their own column
    /// width (Contacts at 320, Mailbox at 330). Honour what they ask for,
    /// clamped into the shared range, so an out-of-range number cannot starve
    /// the detail pane at the window floor.
    private var resolvedListWidth: CGFloat {
        GruxLayout.listColumnWidth(listWidth)
    }
}
