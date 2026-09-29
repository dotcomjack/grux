import AppKit
import SwiftUI
import XCTest
@testable import Grux

/// Tuning's cards sit below the page title and subtitle at every width.
///
/// Measured 2026-09-28 on the headless Mini (and in the pane-fit sweep's own PNG):
/// at a 680 pt pane the two-column grid drew 1319 pt tall in the 1107 pt slot it
/// had measured, so it was centred on the slot and its open card drew up over the
/// title and subtitle. Every card stretches to match its row, and a Grid of only
/// stretching cells, offered a finite height, spreads it over every row.
@MainActor
final class TuningLayoutTests: XCTestCase {

    /// Every AppKit-backed element's label and frame, top-down from the window's top edge.
    /// SwiftUI text is not in an offscreen window's accessibility tree; controls are.
    private func controls(in host: NSView, height: CGFloat) -> [(String, CGRect)] {
        var out: [(String, CGRect)] = []
        func walk(_ e: Any, depth: Int) {
            guard depth < 40, let o = e as? NSObject else { return }
            let label = (o.accessibilityAttributeValue(.title) as? String)
                ?? (o.accessibilityAttributeValue(.description) as? String) ?? ""
            if !label.isEmpty,
               let pos = (o.accessibilityAttributeValue(.position) as? NSValue)?.pointValue,
               let size = (o.accessibilityAttributeValue(.size) as? NSValue)?.sizeValue {
                out.append((label, CGRect(x: pos.x, y: height - pos.y - size.height, width: size.width, height: size.height)))
            }
            for c in (o.accessibilityAttributeValue(.children) as? [Any]) ?? [] { walk(c, depth: depth + 1) }
        }
        walk(host, depth: 0)
        return out
    }

    private func textHeight(_ text: Text, width: CGFloat) -> CGFloat {
        NSHostingView(rootView: text.fixedSize(horizontal: false, vertical: true).frame(width: width)).fittingSize.height
    }

    /// Tuning's open card sits below the page title and subtitle at every width:
    /// its listening picker starts no higher than the page padding, the title, the
    /// subtitle, the card's padding, its header and the divider under it. Measured red: 102 pt from the top at 680.
    func test_tuningsOpenCardSitsBelowItsTitle() throws {
        for width in [CGFloat(680), 1200, 400] {
            let height: CGFloat = 524
            let host = NSHostingView(rootView: TuningView().frame(width: width, height: height)
                .environmentObject(AppState.shared))
            host.frame = NSRect(x: 0, y: 0, width: width, height: height)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            PaneFitHarness.pump(0.4)
            host.layoutSubtreeIfNeeded()
            let found = controls(in: host, height: height)
            window.contentView = nil

            let picker = try XCTUnwrap(found.first { $0.0 == "Always on" }?.1, "\(width): no listening picker in \(found)")
            let inner = width - 2 * (GruxSpacing.xl + GruxSpacing.xs)
            let floor = (GruxSpacing.xl + GruxSpacing.xs)
                + textHeight(Text(TuningCopy.title).font(GruxType.title), width: inner) + 12
                + textHeight(Text(TuningCopy.subtitle).font(.callout), width: inner) + 8 + 12
            // Then the open card: its padding, its title and summary, and the divider under them.
            let columns: CGFloat = width >= 2 * GruxLayout.tuningCardMin + GruxSpacing.m + 2 * (GruxSpacing.xl + GruxSpacing.xs) ? 2 : 1
            let cardText = (inner - (columns - 1) * GruxSpacing.m) / columns - 40
            let c = AppState.shared.config
            let card = 20
                + textHeight(Text(TuningCopy.Card.acts.title).font(.system(size: 15, weight: .bold)), width: cardText) + 5
                + textHeight(Text(TuningCopy.acts(threshold: c.listeningThreshold, mode: c.listeningMode)).font(.callout),
                             width: cardText)
                + 33
            XCTAssertGreaterThanOrEqual(picker.minY, floor + card,
                                        "\(width): the open card's picker is at \(picker.minY) pt, it belongs at \(floor + card) pt or lower, under the title and subtitle (they end near \(floor - 12) pt)")
        }
    }
}
