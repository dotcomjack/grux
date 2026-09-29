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
        // Side by side from `GruxSplitLayout.sideBySideFloor` (listColumnMin +
        // divider + detailContentMin, 581pt) up, stacked below it: a Command
        // Panel pane starts at 360pt, where a 220pt list left the detail 139pt
        // and a message body wrapped a word per line. Side by side the column
        // takes its ask while the detail keeps its floor, and gives ground
        // toward listColumnMin first, so the index degrades before the thing
        // the user is actually reading.
        // Five tabs call this scaffold and two pass their own column width
        // (Contacts at 320, Mailbox at 330); GruxSplit clamps it into the
        // shared range, so an out-of-range number cannot starve the detail.
        GruxSplit(listWidth: listWidth) {
            list()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.18))
        } detail: {
            detail()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

}
