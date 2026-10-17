import SwiftUI

/// Holds the window a view is drawn in, without making SwiftUI redraw.
final class WindowBox {
    weak var window: NSWindow?
}

/// Records the hosting window into a `WindowBox`.
struct WindowReader: NSViewRepresentable {
    let box: WindowBox
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in box.window = view?.window }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {
        if box.window == nil { box.window = view.window }
    }
}
