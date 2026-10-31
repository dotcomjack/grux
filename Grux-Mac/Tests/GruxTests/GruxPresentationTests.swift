import XCTest
import SwiftUI
import AppKit
@testable import Grux

/// D2: a popover or sheet sits on the system material, which follows the app's
/// appearance, while Grux's text colors are fixed for its dark base. With Grux in
/// Light the Approvals tray's titles were near-white on near-white.
@MainActor
final class GruxPresentationTests: XCTestCase {

    private static let door = "Sources/Grux/DesignSystem/GruxPresentation.swift"

    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Every popover and sheet in the app goes through `gruxPopover` / `gruxSheet`.
    func test_everyPopoverAndSheetGoesThroughTheDarkSurface() throws {
        let sources = root.appendingPathComponent("Sources/Grux")
        let e = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        let raw = try NSRegularExpression(pattern: #"\.(popover|sheet)\("#)
        var offenders: [String] = []
        var scanned = 0
        for case let url as URL in e where url.pathExtension == "swift" {
            let rel = String(url.path.dropFirst(root.path.count + 1))
            if rel == Self.door { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for (i, line) in text.components(separatedBy: "\n").enumerated() {
                scanned += 1
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("///") { continue }
                let code = line.range(of: " //").map { String(line[..<$0.lowerBound]) } ?? line
                if raw.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil {
                    offenders.append("\(rel):\(i + 1): \(trimmed)")
                }
            }
        }
        XCTAssertGreaterThan(scanned, 10_000, "the scan found almost no source, so it proves nothing")
        XCTAssertEqual(offenders, [], "use .gruxPopover / .gruxSheet so the text reads in Light")
    }

    /// The presenting window turns dark aqua, whatever the app's appearance.
    func test_theSurfaceTurnsItsOwnWindowDarkInLight() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        let host = NSHostingView(rootView: Text("Approve").gruxPresentationSurface())
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let deadline = Date().addingTimeInterval(2)
        while window.appearance?.name != .darkAqua, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(window.appearance?.name, .darkAqua, "a popover in Light kept the light material")
    }

    /// Grux's own text on Grux's base passes WCAG AA, so painting the base under the
    /// content is what makes it readable (and what a headless capture shows).
    func test_primaryAndSecondaryTextReadOnTheBase() {
        XCTAssertGreaterThanOrEqual(contrast(GruxTheme.textPrimary, GruxTheme.base), 4.5)
        XCTAssertGreaterThanOrEqual(contrast(GruxTheme.textSecondary, GruxTheme.base), 4.5)
    }

    /// The base is painted under the content: rendered in Light, the corner pixel is
    /// Grux's base, not the system's light material or a clear pixel.
    func test_theBaseIsPaintedUnderTheContent() throws {
        let view = Text("Approve").padding(20).gruxPresentationSurface()
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        let rep = NSBitmapImageRep(cgImage: image)
        let corner = try XCTUnwrap(rep.colorAt(x: 1, y: 1)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(corner.alphaComponent, 0.99, "nothing painted under the content")
        XCTAssertLessThan(corner.redComponent, 0.1, "the corner is not Grux's dark base")
    }

    private func contrast(_ a: Color, _ b: Color) -> Double {
        func lum(_ c: Color) -> Double {
            let n = NSColor(c).usingColorSpace(.sRGB)!
            func ch(_ v: CGFloat) -> Double {
                let d = Double(v)
                return d <= 0.03928 ? d / 12.92 : pow((d + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * ch(n.redComponent) + 0.7152 * ch(n.greenComponent) + 0.0722 * ch(n.blueComponent)
        }
        let (x, y) = (lum(a), lum(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
}
