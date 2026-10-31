import SwiftUI
import AppKit

// D2: every popover and sheet Grux shows goes through here.
//
// Grux paints its own dark base everywhere, and `GruxTheme.textPrimary` is a fixed
// near-white. A SwiftUI popover or sheet sits on the system's own material, which
// follows NSApp.appearance, so with Grux set to Light (or Auto on a light Mac) the
// Approvals tray, Optimize Grux, the chat threads list and every sheet drew
// near-white titles on a near-white material. One door for both, and a scan test
// (`GruxPresentationTests`) keeps every `.popover(` and `.sheet(` behind it.

extension View {
    /// A popover drawn on Grux's own dark surface in every appearance.
    func gruxPopover<Content: View>(
        isPresented: Binding<Bool>,
        arrowEdge: Edge = .top,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        popover(isPresented: isPresented, arrowEdge: arrowEdge) {
            content().gruxPresentationSurface()
        }
    }

    /// A sheet drawn on Grux's own dark surface in every appearance.
    func gruxSheet<Content: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        sheet(isPresented: isPresented) {
            content().gruxPresentationSurface()
        }
    }

    /// A sheet drawn on Grux's own dark surface in every appearance.
    func gruxSheet<Item: Identifiable, Content: View>(
        item: Binding<Item?>,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        sheet(item: item) { value in
            content(value).gruxPresentationSurface()
        }
    }

    /// Dark controls and colors inside, Grux's base painted under the content (a
    /// headless capture drops the system material, so the base is what it reads),
    /// and the presenting window itself (the popover's arrow, the sheet's frame)
    /// in dark aqua. Only the presentation's own window: the main window keeps
    /// whatever ThemeConfig set.
    func gruxPresentationSurface() -> some View {
        self
            .environment(\.colorScheme, .dark)
            .background(GruxTheme.base)
            .background(DarkPresentationWindow())
    }
}

/// Sets the window it lands in to dark aqua: a popover's own window or a sheet's,
/// never the window that presented it.
private struct DarkPresentationWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
