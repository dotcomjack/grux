// Print the on-screen window ids for an app, so `screencapture -l<id>` can grab
// exactly that window. Capturing by window id rather than by screen region is
// what keeps the macOS Zoom magnifier (and any overlapping window) out of the
// shot, which is why the Grux UI-verification rule asks for it.
//
//   xcrun swift Grux-Mac/tools/winid.swift Grux
//   screencapture -o -x -l<id> /tmp/shot.png
//
// Output is one tab-separated line per matching window:
//   <windowId>\t<width>x<height>\t<ownerName>\t<windowTitle>
// The width and height are POINTS, which grux-sweep.sh uses to size the diff
// region. On a Retina display the captured PNG is 2x these numbers.
import CoreGraphics
import Foundation

let wanted = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Grux"

guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                           kCGNullWindowID) as? [[String: Any]] else {
    FileHandle.standardError.write(Data("cannot read the window list\n".utf8))
    exit(2)
}

var found = false
for w in raw {
    let owner = (w[kCGWindowOwnerName as String] as? String) ?? ""
    guard owner.localizedCaseInsensitiveContains(wanted) else { continue }
    let id = (w[kCGWindowNumber as String] as? Int) ?? -1
    let name = (w[kCGWindowName as String] as? String) ?? ""
    let b = (w[kCGWindowBounds as String] as? [String: Any]) ?? [:]
    let width = (b["Width"] as? Double) ?? 0
    let height = (b["Height"] as? Double) ?? 0
    // Skip the 1x1 and menu-bar-sized helper windows every AppKit app carries,
    // or the capture silently grabs a sliver instead of the real UI.
    guard width > 200, height > 200 else { continue }
    print("\(id)\t\(Int(width))x\(Int(height))\t\(owner)\t\(name)")
    found = true
}

if !found {
    FileHandle.standardError.write(Data("no window over 200x200 owned by \(wanted)\n".utf8))
    exit(1)
}
