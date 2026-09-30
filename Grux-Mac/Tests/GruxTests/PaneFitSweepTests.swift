import XCTest
import SwiftUI
import AppKit
@testable import Grux

// MARK: - The harness

/// What one surface's own layout answered, recorded by `PaneFitSlot`.
@MainActor
final class PaneFitBox {
    var child: CGSize = .zero
}

/// Records the width it is placed at: inside a vertical scroll view, that is
/// the content column the scroller leaves.
struct PaneFitWidthProbe: Layout {
    let box: PaneFitBox

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 0, height: 10)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        MainActor.assumeIsolated { box.child = bounds.size }
    }
}

/// Offers its one child exactly `width` x `height`, takes exactly that size
/// itself, and centres the child the way `.frame(width:height:)` does, so a
/// child that answers wider spills past both edges exactly as it does in the
/// app. The child's own answer lands in `box`: that is the surface's fitting
/// width at the proposed width.
struct PaneFitSlot: Layout {
    let width: CGFloat
    let height: CGFloat
    let box: PaneFitBox

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        let offer = ProposedViewSize(width: width, height: height)
        let answer = child.sizeThatFits(offer)
        MainActor.assumeIsolated { box.child = answer }
        child.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center, proposal: offer)
    }
}

/// One surface at one width.
struct PaneFitResult {
    let surface: String
    let width: CGFloat
    /// The surface's own answer to the proposal.
    let fitting: CGFloat
    /// How far anything drew past the leading and trailing edge of its slot.
    let bleedLeading: CGFloat
    let bleedTrailing: CGFloat
    /// The drawn layers that reach past the slot, with their rows in points
    /// from the top, so the offending row can be found in the PNG.
    let overflowingLayers: [String]
    /// Where the first ink sits, in points from the slot's leading edge, when
    /// the measurement asked for it.
    var firstInk: CGFloat? = nil

    static let tolerance: CGFloat = 1

    var fits: Bool {
        fitting <= width + Self.tolerance
            && bleedLeading <= Self.tolerance && bleedTrailing <= Self.tolerance
    }

    var key: String { "\(surface)@\(Int(width))" }

    var line: String {
        var parts = ["\(surface) at \(Int(width))pt: fitting \(Int(fitting.rounded(.up)))pt"]
        if bleedLeading > Self.tolerance || bleedTrailing > Self.tolerance {
            parts.append("drew \(Int(bleedLeading.rounded(.up)))pt past the leading edge and \(Int(bleedTrailing.rounded(.up)))pt past the trailing edge")
        }
        if !overflowingLayers.isEmpty { parts.append("past the slot: " + overflowingLayers.joined(separator: "; ")) }
        return parts.joined(separator: ", ")
    }
}

/// Hosts a view offscreen in an `NSHostingView`, proposes it one width, and
/// measures it three ways: its fitting width, the ink it drew outside its
/// slot, and any vertical scroll view whose content is wider than itself.
/// Needs no screen recording permission: `cacheDisplay` draws the view, it
/// does not read the screen.
@MainActor
enum PaneFitHarness {
    /// Transparent room either side of the slot, so ink past an edge shows.
    static let margin: CGFloat = 400
    /// An alpha above this is ink. Low enough to catch a capability gate's
    /// dimmed content (0.28), high enough to ignore a soft shadow's tail.
    static let inkAlpha: UInt8 = 40

    /// Where the offscreen PNGs go: `GRUX_FLEX_SWEEP_DIR` when set, otherwise
    /// the package's own `.build/flex-sweep`, which git ignores.
    static var outputDir: URL {
        if let dir = ProcessInfo.processInfo.environment["GRUX_FLEX_SWEEP_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/flex-sweep", isDirectory: true)
    }

    static func pump(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    static func measure<V: View>(_ surface: String, width: CGFloat, height: CGFloat,
                                 settle: TimeInterval = 0.35, writePNG: Bool = true,
                                 findFirstInk: Bool = false, onBase: Bool = true,
                                 @ViewBuilder _ content: () -> V) -> PaneFitResult {
        let box = PaneFitBox()
        let root = HStack(spacing: 0) {
            Color.clear.frame(width: margin, height: height)
            // On the app's base colour, as a person sees it, unless the caller
            // is reading where the first ink falls, where a background is ink.
            PaneFitSlot(width: width, height: height, box: box) { content() }
                .background(onBase ? GruxTheme.base : Color.clear)
            Color.clear.frame(width: margin, height: height)
        }
        .environmentObject(AppState.shared)
        .tint(GruxTheme.accentPrimary)
        let host = NSHostingView(rootView: root)
        let size = NSSize(width: width + 2 * margin, height: height)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        pump(settle)
        host.layoutSubtreeIfNeeded()

        var bleedLeading: CGFloat = 0
        var bleedTrailing: CGFloat = 0
        var firstInk: CGFloat?
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            (bleedLeading, bleedTrailing) = bleed(rep, slotWidth: width)
            if findFirstInk { firstInk = firstInkColumn(rep, slotWidth: width) }
            if writePNG { write(rep, slotWidth: width, name: "\(surface)-\(Int(width))") }
        }
        let fitting = box.child.width
        let overflowing = (fitting > width + PaneFitResult.tolerance || bleedLeading > PaneFitResult.tolerance
                           || bleedTrailing > PaneFitResult.tolerance)
            ? layersPastTheSlot(in: host, slotWidth: width) : []
        // Never `close()`: a programmatic NSWindow is released when closed, and
        // ARC releases it again, which crashes the next autorelease pool pop.
        window.contentView = nil
        return PaneFitResult(surface: surface, width: width, fitting: fitting,
                             bleedLeading: bleedLeading, bleedTrailing: bleedTrailing,
                             overflowingLayers: overflowing, firstInk: firstInk)
    }

    /// The surface's fitting width alone, laid out in a window but with no
    /// settle and no render: a fraction of what `measure` costs, so a band of
    /// widths can be swept one point at a time. The window is not optional: a
    /// scroll view with no window never reserves its legacy scroller, so
    /// without one this measures the overlay case whatever the pin says.
    static func fitting<V: View>(width: CGFloat, height: CGFloat, @ViewBuilder _ content: () -> V) -> CGFloat {
        let box = PaneFitBox()
        let host = NSHostingView(rootView: PaneFitSlot(width: width, height: height, box: box) { content() }
            .environmentObject(AppState.shared)
            .tint(GruxTheme.accentPrimary))
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        pump(0.02)
        host.layoutSubtreeIfNeeded()
        // Never `close()`, for the reason `measure` gives.
        window.contentView = nil
        return box.child.width
    }

    /// The first inked column, in points from the slot's leading edge.
    static func firstInkColumn(_ rep: NSBitmapImageRep, slotWidth: CGFloat) -> CGFloat? {
        guard let data = rep.bitmapData, rep.bitsPerSample == 8, rep.hasAlpha else { return nil }
        let scale = CGFloat(rep.pixelsWide) / (slotWidth + 2 * margin)
        let spp = rep.samplesPerPixel
        let alphaIndex = rep.bitmapFormat.contains(.alphaFirst) ? 0 : spp - 1
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh where data[y * rep.bytesPerRow + x * spp + alphaIndex] > inkAlpha {
                return CGFloat(x) / scale - margin
            }
        }
        return nil
    }

    /// Points of ink past each edge of the slot.
    static func bleed(_ rep: NSBitmapImageRep, slotWidth: CGFloat) -> (CGFloat, CGFloat) {
        guard let data = rep.bitmapData, rep.bitsPerSample == 8, rep.hasAlpha else { return (0, 0) }
        let scale = CGFloat(rep.pixelsWide) / (slotWidth + 2 * margin)
        let spp = rep.samplesPerPixel
        let alphaIndex = rep.bitmapFormat.contains(.alphaFirst) ? 0 : spp - 1
        let rowBytes = rep.bytesPerRow
        let slotStart = Int((margin * scale).rounded())
        let slotEnd = Int(((margin + slotWidth) * scale).rounded())
        func inked(_ x: Int) -> Bool {
            var y = 0
            while y < rep.pixelsHigh {
                if data[y * rowBytes + x * spp + alphaIndex] > inkAlpha { return true }
                y += 1
            }
            return false
        }
        var leading = 0
        for x in 0..<slotStart where inked(x) { leading = slotStart - x; break }
        var trailing = 0
        for x in stride(from: rep.pixelsWide - 1, through: slotEnd, by: -1) where inked(x) {
            trailing = x - slotEnd + 1
            break
        }
        return (CGFloat(leading) / scale, CGFloat(trailing) / scale)
    }

    /// Writes the slot alone, as a person sees the pane.
    static func write(_ rep: NSBitmapImageRep, slotWidth: CGFloat, name: String) {
        let scale = CGFloat(rep.pixelsWide) / (slotWidth + 2 * margin)
        let rect = CGRect(x: (margin * scale).rounded(), y: 0,
                          width: (slotWidth * scale).rounded(), height: CGFloat(rep.pixelsHigh))
        guard let cg = rep.cgImage?.cropping(to: rect) else { return }
        let slot = NSBitmapImageRep(cgImage: cg)
        guard let png = slot.representation(using: .png, properties: [:]) else { return }
        let dir = outputDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? png.write(to: dir.appendingPathComponent("\(name).png"))
    }

    /// The deepest drawn layers whose frame reaches past the slot on either
    /// side, as `class x0..x1 at y` in slot points, at most twelve. SwiftUI
    /// draws text and shapes into layers rather than views, so this is what
    /// names the row that overflowed.
    static func layersPastTheSlot(in host: NSView, slotWidth: CGFloat) -> [String] {
        guard let root = host.layer else { return [] }
        var out: [String] = []
        func walk(_ layer: CALayer) {
            let frame = root.convert(layer.frame, from: layer.superlayer ?? root)
            let x0 = frame.minX - margin, x1 = frame.maxX - margin
            let past = x0 < -PaneFitResult.tolerance || x1 > slotWidth + PaneFitResult.tolerance
            let kids = layer.sublayers ?? []
            if past, kids.isEmpty, frame.width < slotWidth + 2 * margin - 1, out.count < 12 {
                let name = String(describing: type(of: layer))
                out.append("\(name) \(Int(x0))..\(Int(x1)) at y \(Int(frame.minY)) h \(Int(frame.height))")
            }
            kids.forEach(walk)
        }
        walk(root)
        return out
    }

    /// Appends the results to `<group>.tsv` beside the PNGs, and prints each
    /// miss on a line a log grep can find.
    static func report(_ group: String, _ results: [PaneFitResult]) {
        let rows = results.map {
            [$0.surface, "\(Int($0.width))", "\(Int($0.fitting.rounded(.up)))",
             "\(Int($0.bleedLeading.rounded(.up)))", "\(Int($0.bleedTrailing.rounded(.up)))",
             $0.fits ? "fits" : "OVERFLOWS", $0.overflowingLayers.joined(separator: "; ")].joined(separator: "\t")
        }
        let text = (["surface\twidth\tfitting\tbleedLeading\tbleedTrailing\tverdict\tpastTheSlot"] + rows)
            .joined(separator: "\n") + "\n"
        let dir = outputDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? text.write(to: dir.appendingPathComponent("\(group).tsv"), atomically: true, encoding: .utf8)
        for r in results where !r.fits { note("OVERFLOW \(r.line)") }
        note("\(group): \(results.filter(\.fits).count) of \(results.count) fit")
    }

    /// Prints a line and appends it to `notes.txt` beside the PNGs: the test
    /// runner keeps only the tail of the output, and the offender list is
    /// what this sweep is for.
    static func note(_ line: String) {
        print("FLEXSWEEP \(line)")
        let dir = outputDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("notes.txt")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data((line + "\n").utf8))
            try? handle.close()
        } else {
            try? (line + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - The sweep

/// Every surface the Command Panel can show, at every width it can be shown
/// at, must fit: its fitting width at or under the proposal, no ink past its
/// slot, and no vertical scroll view hiding content wider than itself.
///
/// The surface list comes from `LaunchRootView.Tab.allCases`, rendered through
/// `SurfacePane`, the builder the panel's pane uses, so a new tab is swept the
/// day it is added. Settings sections, the panel column and its rows, the
/// Self-Upgrade cards, every onboarding screen at the flow's minimum width,
/// and the sheets and popovers a pane opens are swept beside them.
///
/// Every render is also written as a PNG to `PaneFitHarness.outputDir`, so a
/// person can look at each one, not only count them.
@MainActor
final class PaneFitSweepTests: XCTestCase {
    /// The pane widths: its floor, its resting width, and a wide one.
    static let paneWidths: [CGFloat] = [GruxLayout.detailContentMin, GruxLayout.paneWidth, GruxLayout.contentMax]
    /// The pane's height at the resting window, under its bar.
    static let paneHeight = GruxLayout.panelIdealHeight - GruxLayout.paneBarHeight
    /// A sheet's floor and ceiling.
    static let sheetWidths: [CGFloat] = [GruxLayout.sheetMin, GruxLayout.sheetMax]
    /// The panel's column inside its padding.
    static let panelContentWidth = GruxLayout.panelWidth - 2 * GruxSpacing.l

    /// Surfaces that live in files another branch owns (`Sources/Grux/Optimize/`
    /// and `Sources/Grux/Foundry/`), measured and known to overflow, keyed
    /// `surface@width`. Self-liquidating: the sweep fails the day one of these
    /// fits, so the entry is removed with the fix.
    static let knownOffenders: Set<String> = []

    /// The only surfaces `knownOffenders` may name: the ones drawn by files in
    /// `Sources/Grux/Optimize/` and `Sources/Grux/Foundry/`.
    static let offenderOwnersElsewhere = ["tab-selfUpgrade@", "panel-optimize-", "selfupgrade-card-"]

    private var savedRequestedSettingsTab: String?
    private var savedRecents: [String] = []
    private var savedPins: [String] = []
    private var savedStage: OnboardingModel.Stage = .done
    private var savedSkippedFirstLook = false
    private var savedOnboardingBytes: Data?
    private let onboardingURL = Persistence.supportDir.appendingPathComponent("onboarding.json")
    private var savedScrollerStyle: IMP?

    /// Every failure also lands in notes.txt, for the same reason `note` exists.
    override func record(_ issue: XCTIssue) {
        PaneFitHarness.note("FAIL \(name): \(issue.compactDescription)")
        super.record(issue)
    }

    override func setUp() async throws {
        savedRequestedSettingsTab = AppState.shared.requestedSettingsTab
        savedRecents = SidebarStateStore.shared.recents
        savedPins = SidebarStateStore.shared.pinned
        savedStage = OnboardingModel.shared.stage
        savedSkippedFirstLook = OnboardingModel.shared.skippedFirstLook
        savedOnboardingBytes = try? Data(contentsOf: onboardingURL)
        // Always-visible scrollers, which a Mac with no trackpad gets and a
        // hosted CI runner has. A vertical scroll view then gives its content
        // one scroller less than the pane, so a surface that fits a 360pt pane
        // under overlay scrollers can still overflow one. Measured 2026-09-30:
        // the Cognition Map fit on every Mac with a trackpad and overflowed 2pt
        // on macOS 15 CI. Pinned here so every host measures the narrow case.
        //
        // By replacing `NSScroller.preferredScrollerStyle` for the length of
        // the test, because nothing gentler takes. AppKit reads the
        // `AppleShowScrollBars` default once, so setting it in any domain from
        // inside a running process changes nothing: measured, the content
        // column stayed 360pt. `test_theSweepMeasuresUnderAlwaysVisibleScrollers`
        // fails if this stops taking.
        let method = class_getClassMethod(NSScroller.self, #selector(getter: NSScroller.preferredScrollerStyle))
        let legacy: @convention(block) (AnyObject) -> Int = { _ in NSScroller.Style.legacy.rawValue }
        if let method { savedScrollerStyle = method_setImplementation(method, imp_implementationWithBlock(legacy)) }
    }

    override func tearDown() async throws {
        if let saved = savedScrollerStyle,
           let method = class_getClassMethod(NSScroller.self, #selector(getter: NSScroller.preferredScrollerStyle)) {
            method_setImplementation(method, saved)
        }
        AppState.shared.requestedSettingsTab = savedRequestedSettingsTab
        SidebarStateStore.shared.replaceRecents(savedRecents)
        SidebarStateStore.shared.replacePins(savedPins)
        OptimizeHubState.shared.isExpanded = false
        let onboarding = OnboardingModel.shared
        if savedStage == .done, onboarding.stage != .done || onboarding.skippedFirstLook != savedSkippedFirstLook {
            onboarding.finish(skippedFirstLook: savedSkippedFirstLook)
        }
        if let bytes = savedOnboardingBytes {
            try? bytes.write(to: onboardingURL)
        } else {
            try? FileManager.default.removeItem(at: onboardingURL)
        }
    }

    /// Fails once per surface and width that does not fit, unless it is a
    /// named known offender in a file this branch does not own.
    private func assertAllFit(_ group: String, _ results: [PaneFitResult],
                              file: StaticString = #filePath, line: UInt = #line) {
        PaneFitHarness.report(group, results)
        XCTAssertFalse(results.isEmpty, "\(group) measured nothing", file: file, line: line)
        for r in results where !r.fits && !Self.knownOffenders.contains(r.key) {
            XCTFail("does not fit: \(r.line)", file: file, line: line)
        }
        for r in results where r.fits && Self.knownOffenders.contains(r.key) {
            XCTFail("\(r.key) fits now: remove it from knownOffenders", file: file, line: line)
        }
    }

    // MARK: Surface lists

    /// Every tab, in the enum's order, named by its locked key.
    static var tabs: [(name: String, tab: LaunchRootView.Tab)] {
        LaunchRootView.Tab.allCases.map { ("tab-\(LaunchRootView.tabKey(for: $0))", $0) }
    }

    /// One settings tag per section, every pane and every sub-pane.
    static let settingsSections: [String] = [
        "general", "voice", "ambient", "focus", "sessions",
        "models", "presets", "appearance", "backup", "security", "folders", "capabilities",
    ]

    // MARK: The guard's own list

    /// The sweep covers every key the panel can open: every sidebar key maps
    /// to a case the sweep walks, and the walk covers every case.
    func test_theSweepCoversEveryTabThePanelCanOpen() {
        let swept = Set(Self.tabs.map { LaunchRootView.tabKey(for: $0.tab) })
        for item in SidebarIA.allItems {
            let tab = LaunchRootView.tab(forKey: item.key)
            XCTAssertNotNil(tab, "sidebar key \(item.key) opens nothing")
            if let tab { XCTAssertTrue(swept.contains(LaunchRootView.tabKey(for: tab)), "\(item.key) escapes the sweep") }
        }
        for key in ["labs", "tuning", "settings"] {
            XCTAssertTrue(swept.contains(key), "\(key) escapes the sweep")
        }
        XCTAssertEqual(Set(SettingsPane.allCases.map { SettingsTabAliases.resolve($0.rawValue).pane }),
                       Set(Self.settingsSections.map { SettingsTabAliases.resolve($0).pane }),
                       "a Settings pane escapes the sweep")
    }

    /// The harness is not evidence until it has failed. A planted fixed-width
    /// view must be caught two ways, its fitting width and its ink past the
    /// slot, on its own and inside a vertical scroll view, and a horizontal
    /// scroll view holding wider content must pass, since scrolling sideways
    /// is what it is for.
    func test_aPlantedFixedWidthViewFails() {
        let w = GruxLayout.detailContentMin
        let wide = w + 200
        let planted = PaneFitHarness.measure("planted-fixed", width: w, height: 200, writePNG: false) {
            Color.red.frame(width: wide, height: 40)
        }
        XCTAssertFalse(planted.fits, "the harness passed a \(Int(wide))pt view in a \(Int(w))pt pane")
        XCTAssertEqual(planted.fitting, wide, accuracy: 1, "the fitting width is not the planted width")
        XCTAssertGreaterThan(planted.bleedLeading, 90, "ink past the leading edge went unseen")
        XCTAssertGreaterThan(planted.bleedTrailing, 90, "ink past the trailing edge went unseen")

        let fine = PaneFitHarness.measure("planted-fluid", width: w, height: 200, writePNG: false) {
            Color.red.frame(maxWidth: .infinity).frame(height: 40)
        }
        XCTAssertTrue(fine.fits, "a fluid view failed: \(fine.line)")

        let scrolled = PaneFitHarness.measure("planted-scroll", width: w, height: 200, writePNG: false) {
            ScrollView(.vertical) { Color.red.frame(width: wide, height: 40) }
        }
        XCTAssertFalse(scrolled.fits, "wide content inside a vertical scroll view went unseen: \(scrolled.line)")
        XCTAssertFalse(scrolled.overflowingLayers.isEmpty, "the overflow was not traced to a layer")

        let sideways = PaneFitHarness.measure("planted-hscroll", width: w, height: 200, writePNG: false) {
            ScrollView(.horizontal, showsIndicators: false) { Color.red.frame(width: wide, height: 40) }
        }
        XCTAssertTrue(sideways.fits, "a horizontal scroll view is meant to hold wider content: \(sideways.line)")
        PaneFitHarness.report("planted", [planted, fine, scrolled, sideways])
    }

    /// The container, red first. The shell's pane column, holding a surface
    /// far wider than its pane, beside a transparent stand-in for the panel:
    /// contained, the surface takes the pane's width, draws nothing over the
    /// panel and nothing past the window edge. The same column uncontained is
    /// measured first and must fail, or this test proves nothing.
    func test_thePaneContainerNeverDrawsOverThePanelOrPastTheWindow() throws {
        let pane = GruxLayout.detailContentMin
        let total = GruxLayout.panelWidth + GruxLayout.divider + pane
        let planted = pane + 300
        func shell(contained: Bool) -> some View {
            HStack(spacing: 0) {
                Color.clear.frame(width: GruxLayout.panelWidth)
                Color.clear.frame(width: GruxLayout.divider)
                Group {
                    if contained {
                        Color.red.frame(width: planted, height: 40).containedInOffer()
                    } else {
                        Color.red.frame(width: planted, height: 40)
                    }
                }
                .frame(minWidth: GruxLayout.detailContentMin, idealWidth: GruxLayout.paneWidth, maxWidth: .infinity)
            }
        }
        let bare = PaneFitHarness.measure("container-bare", width: total, height: 200, writePNG: false,
                                          findFirstInk: true, onBase: false) { shell(contained: false) }
        let bareInk = try XCTUnwrap(bare.firstInk, "the planted surface drew nothing")
        XCTAssertTrue(!bare.fits || bareInk < GruxLayout.panelWidth,
                      "an uncontained pane did not spill, so this test proves nothing: \(bare.line)")

        let held = PaneFitHarness.measure("container-held", width: total, height: 200, writePNG: false,
                                          findFirstInk: true, onBase: false) { shell(contained: true) }
        XCTAssertTrue(held.fits, "the contained pane spilled: \(held.line)")
        let heldInk = try XCTUnwrap(held.firstInk, "the contained surface drew nothing")
        XCTAssertGreaterThanOrEqual(heldInk, GruxLayout.panelWidth - PaneFitResult.tolerance,
                                    "the pane drew \(Int(GruxLayout.panelWidth - heldInk))pt over the panel")

        // And the shell really uses it, on both columns.
        let root = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/Shell/CommandPanelRoot.swift"), encoding: .utf8)
        XCTAssertEqual(root.components(separatedBy: ".containedInOffer()").count - 1, 2,
                       "the panel and the pane are not both contained")
    }

    /// Every pane minimum the window is asked for is one the sweep holds the
    /// surface to, and none is wider than the pane the panel opens at rest.
    func test_paneMinimumsAreHonestAndFitTheRestingPane() {
        for tab in LaunchRootView.Tab.allCases {
            let floor = PaneMinimum.width(for: tab)
            XCTAssertGreaterThanOrEqual(floor, GruxLayout.detailContentMin)
            XCTAssertLessThanOrEqual(floor, GruxLayout.paneWidth,
                                     "\(LaunchRootView.tabKey(for: tab)) needs more than the resting pane")
        }
    }

    /// A known offender names one surface at one width, and only a surface
    /// whose files this branch does not own. Everything else is fixed, not listed.
    func test_knownOffendersAreOnlySurfacesOwnedElsewhere() {
        for key in Self.knownOffenders {
            XCTAssertTrue(key.contains("@"), "\(key) names no width")
            XCTAssertTrue(Self.offenderOwnersElsewhere.contains { key.hasPrefix($0) },
                          "\(key) is not an Optimize or Foundry surface, so it is fixed, not listed")
        }
    }

    // MARK: Panes

    func test_everyTabFitsEveryPaneWidth() {
        var results: [PaneFitResult] = []
        for (name, tab) in Self.tabs {
            // The floor is the pane's honest minimum, which the window holds.
            for w in [PaneMinimum.width(for: tab)] + Self.paneWidths.dropFirst() {
                results.append(PaneFitHarness.measure(name, width: w, height: Self.paneHeight) {
                    SurfacePane(selection: .constant(tab)).environment(\.hostedInPane, true)
                })
            }
        }
        assertAllFit("tabs", results)
    }

    /// The scroller pin in `setUp` took: a vertical scroll view in a pane at
    /// the floor leaves its content the pane less a legacy scroller. Without
    /// this the sweep would quietly measure overlay scrollers again, and pass
    /// the surfaces that only overflow on a Mac without a trackpad.
    func test_theSweepMeasuresUnderAlwaysVisibleScrollers() {
        let w = GruxLayout.detailContentMin
        let box = PaneFitBox()
        _ = PaneFitHarness.measure("scroller-probe", width: w, height: 200, writePNG: false) {
            // Taller than the pane: a legacy scroller only takes its column
            // when there is something to scroll.
            ScrollView(.vertical) { PaneFitWidthProbe(box: box) { Color.clear }.frame(height: 400) }
        }
        let scroller = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        XCTAssertGreaterThan(scroller, 0)
        XCTAssertEqual(box.child.width, w - scroller, accuracy: 0.5,
                       "the scroll view's content column is \(box.child.width)pt in a \(Int(w))pt pane: always-visible scrollers are not in effect")
    }

    /// The Cognition Map with decisions traced, which is how anyone who uses
    /// Jax sees it and how CI saw it once earlier tests had traced some. Empty,
    /// it shows a wrapping sentence and fits anything, which is all
    /// `test_everyTabFitsEveryPaneWidth` sees on a clean host.
    ///
    /// Every whole width from the floor to 40pt past it is held to the width
    /// it was offered with no tolerance, because the overflow this was written
    /// for lived in a band: its stat row answered a fraction of a point too
    /// wide at some widths and not at the ones either side, and the scroll
    /// view turned that fraction into 2pt of ink past the pane. The pane
    /// widths themselves then get the full measurement, ink and all.
    func test_theCognitionMapFitsWithDecisionsTraced() {
        let trace = CognitionTrace.shared
        let saved = trace.events
        defer {
            trace.clearAll()
            for event in saved.reversed() { trace.record(event) }
        }
        trace.note(kind: .directive, trigger: "Learned from your edit: Where is my order",
                   heuristicsFired: ["Keep replies short and skip the apology."], mode: "observe",
                   outcome: "Captured a lesson from a correction.", brand: "acme", correlationId: "pane-fit-1")
        trace.note(kind: .task, trigger: "fact grounding audit (acme)",
                   memoriesRetrieved: ["acme product catalog (ground truth)"], gateVerdict: "clarify",
                   gateReason: "An ungrounded fact is true confusion.", confidence: 0.2, mode: "simulate",
                   outcome: "Blocked publish on 1 invented fact.")
        trace.note(kind: .goalCycle, trigger: "goal pursuit cycle", memoriesRetrieved: ["(mail) 3 unread"],
                   gateVerdict: "queued", mode: "observe", outcome: "Planned: reply to the supplier")
        trace.note(kind: .prompt, trigger: "what is on my calendar tomorrow",
                   heuristicsFired: ["Prefer the calendar", "Ask before moving events"], gateVerdict: "proceed",
                   confidence: 0.9, mode: "assist", outcome: "Answered from the calendar.")
        XCTAssertGreaterThanOrEqual(trace.events.count, 4)

        let floor = PaneMinimum.width(for: .cognitionMap)
        for w in stride(from: floor, through: floor + 40, by: 1) {
            let fitting = PaneFitHarness.fitting(width: w, height: Self.paneHeight) {
                SurfacePane(selection: .constant(.cognitionMap)).environment(\.hostedInPane, true)
            }
            XCTAssertLessThanOrEqual(fitting, w, "tab-cognitionMap with decisions traced answered \(fitting)pt to a \(Int(w))pt pane")
        }
        var results: [PaneFitResult] = []
        for w in [floor] + Self.paneWidths.dropFirst() {
            results.append(PaneFitHarness.measure("tab-cognitionMap-traced", width: w, height: Self.paneHeight) {
                SurfacePane(selection: .constant(.cognitionMap)).environment(\.hostedInPane, true)
            })
        }
        assertAllFit("cognition-traced", results)
    }

    func test_everySettingsSectionFitsEveryPaneWidth() {
        var results: [PaneFitResult] = []
        for tag in Self.settingsSections {
            for w in Self.paneWidths {
                AppState.shared.requestedSettingsTab = tag
                results.append(PaneFitHarness.measure("settings-\(tag)", width: w, height: Self.paneHeight, settle: 0.5) {
                    SurfacePane(selection: .constant(.settings)).environment(\.hostedInPane, true)
                })
            }
        }
        assertAllFit("settings", results)
    }

    // MARK: The panel column

    /// The five widest Recent labels, the Now rows at their longest, the
    /// Optimize card collapsed and expanded, and the whole column.
    func test_thePanelColumnAndItsRowsFit() {
        let widest = SidebarIA.allItems.map(\.key).filter { $0 != "settings" }
            .sorted { SidebarIA.railLabel(forKey: $0).count > SidebarIA.railLabel(forKey: $1).count }
        SidebarStateStore.shared.replacePins([])
        SidebarStateStore.shared.replaceRecents(Array(widest.prefix(PanelFoot.chipCap + 1)))
        let long = String(repeating: "A long title that keeps going past the edge ", count: 3)
        let items = [
            PanelItem(id: "a", cls: .needsYou, icon: "envelope.fill", title: long, detail: "12 waiting since this morning",
                      action: .openApprovals),
            PanelItem(id: "b", cls: .running, icon: "sparkles", title: long, detail: "", action: .openOptimize),
            PanelItem(id: "c", cls: .next, icon: "calendar", title: "Short", detail: long, action: .open(tabKey: "calendar")),
        ]
        let w = Self.panelContentWidth
        var results: [PaneFitResult] = [
            PaneFitHarness.measure("panel-head", width: w, height: 120) {
                PanelHead(onOpen: { _ in }, onOptimize: {})
            },
            PaneFitHarness.measure("panel-input", width: w, height: 80) {
                PanelInput(onTuning: {}, onSend: { _ in })
            },
            PaneFitHarness.measure("panel-now", width: w, height: 200) {
                PanelNowList(items: items, onAction: { _ in })
            },
            PaneFitHarness.measure("panel-foot", width: w, height: 120) {
                PanelFoot(onOpen: { _ in }, onSettings: {})
            },
        ]
        let collapsed = OptimizeHubState()
        results.append(PaneFitHarness.measure("panel-optimize-collapsed", width: w, height: 120) {
            OptimizeHubCard(hub: collapsed)
        })
        let expanded = OptimizeHubState()
        expanded.isExpanded = true
        results.append(PaneFitHarness.measure("panel-optimize-expanded", width: w, height: 560) {
            OptimizeHubCard(hub: expanded)
        })
        OnboardingModel.shared.finish(skippedFirstLook: true)
        let model = PanelModel(stateProvider: { RelevanceState() }, sizeWindow: { _, _ in }, floorHeight: { _ in })
        results.append(PaneFitHarness.measure("panel-root", width: GruxLayout.panelWidth,
                                              height: GruxLayout.panelIdealHeight, settle: 0.6) {
            CommandPanelRoot(model: model)
        })
        assertAllFit("panel", results)
    }

    /// A Recent row with more chips than the panel holds draws only whole
    /// chips (D-chips): every capsule it draws is exactly as wide as that chip
    /// drawn alone, so none is cut at the panel edge, and the chips that do not
    /// fit are not drawn at all. Seen live as "Meta" and "Sel" cut in half
    /// under the old scroll fade. Measured at the panel's column and a
    /// narrower and a wider one, on the five widest labels.
    func test_theRecentRowDrawsOnlyWholeChips() {
        let widest = SidebarIA.allItems.map(\.key).filter { $0 != "settings" }
            .sorted { Self.chipWidth($0) > Self.chipWidth($1) }
        let keys = Array(widest.prefix(PanelFoot.chipCap))
        let natural = keys.map(Self.chipWidth)
        let all = natural.reduce(0, +) + PanelFoot.chipSpacing * CGFloat(keys.count - 1)
        for width in [Self.panelContentWidth - 120, Self.panelContentWidth, Self.panelContentWidth + 60] {
            XCTAssertGreaterThan(all, width, "the five widest chips fit \(Int(width))pt, so this proves nothing")
            let runs = Self.inkRuns(width: width, height: GruxSpacing.xl * 2) {
                PanelFoot.chipRow(keys) { PanelFoot.chipFace($0) }
            }
            PaneFitHarness.note("recent-row@\(Int(width)): drew \(runs.map { Int($0.rounded()) }) of \(natural.map { Int($0.rounded()) })")
            XCTAssertFalse(runs.isEmpty, "the Recent row drew nothing at \(Int(width))pt")
            XCTAssertLessThan(runs.count, keys.count, "all five chips drew at \(Int(width))pt, so one of them is cut")
            for (i, run) in runs.enumerated() where i < natural.count {
                XCTAssertEqual(run, natural[i], accuracy: 2,
                               "chip \(i) (\(SidebarIA.railLabel(forKey: keys[i]))) drew \(Int(run))pt of its \(Int(natural[i]))pt at \(Int(width))pt: cut at the edge")
            }
        }
    }

    /// One Recent chip's own width, drawn alone.
    static func chipWidth(_ key: String) -> CGFloat {
        let host = NSHostingView(rootView: PanelFoot.chipFace(key))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.width
    }

    /// Draws `content` leading-aligned in a `width` slot and returns the width
    /// in points of each horizontal run of columns holding any ink at all, in
    /// order. A chip's capsule is one run; the gap between chips is empty.
    static func inkRuns<V: View>(width: CGFloat, height: CGFloat, @ViewBuilder _ content: () -> V) -> [CGFloat] {
        let root = content().frame(width: width, height: height, alignment: .leading)
            .environmentObject(AppState.shared)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        PaneFitHarness.pump(0.3)
        host.layoutSubtreeIfNeeded()
        defer { window.contentView = nil }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return [] }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let data = rep.bitmapData, rep.bitsPerSample == 8, rep.hasAlpha else { return [] }
        let scale = CGFloat(rep.pixelsWide) / width
        let spp = rep.samplesPerPixel
        let alphaIndex = rep.bitmapFormat.contains(.alphaFirst) ? 0 : spp - 1
        func inked(_ x: Int) -> Bool {
            (0..<rep.pixelsHigh).contains { data[$0 * rep.bytesPerRow + x * spp + alphaIndex] > 2 }
        }
        var runs: [CGFloat] = []
        var start: Int?
        for x in 0...rep.pixelsWide {
            let ink = x < rep.pixelsWide && inked(x)
            if ink, start == nil { start = x }
            if !ink, let s = start { runs.append(CGFloat(x - s) / scale); start = nil }
        }
        return runs
    }

    // MARK: Self-Upgrade cards

    func test_theSelfUpgradeCardsFitEveryPaneWidth() {
        let signedIn = FoundryDirection.primaryAction(FoundryBuildReadiness(
            auth: .signedIn, subscriptionType: "max", cliInstalled: true, foundryEnabled: true,
            sourceAvailable: true, stage: .proposed, buildInFlight: false, escalatedJobId: nil, approvalPending: false))
        let signedOut = FoundryDirection.primaryAction(FoundryBuildReadiness(
            auth: .signedOut, subscriptionType: nil, cliInstalled: true, foundryEnabled: true,
            sourceAvailable: true, stage: .proposed, buildInFlight: false, escalatedJobId: nil, approvalPending: false))
        var building = SelfUpgradeCaptureTests.fixture
        building.status = .accepted
        building.stage = .building
        let inFlight = FoundryDirection.primaryAction(FoundryBuildReadiness(
            auth: .signedIn, subscriptionType: "max", cliInstalled: true, foundryEnabled: true,
            sourceAvailable: true, stage: .building, buildInFlight: true, escalatedJobId: nil, approvalPending: false))
        let cards: [(String, FoundryProposalCardModel, FoundryPrimaryAction)] = [
            ("selfupgrade-card-signed-in", SelfUpgradeCaptureTests.fixture, signedIn),
            ("selfupgrade-card-signed-out", SelfUpgradeCaptureTests.fixture, signedOut),
            ("selfupgrade-card-building", building, inFlight),
        ]
        var results: [PaneFitResult] = []
        for (name, card, action) in cards {
            for w in Self.paneWidths {
                results.append(PaneFitHarness.measure(name, width: w, height: 420) {
                    FoundryProposalCard(card: card, action: action, copied: false,
                                        onPrimary: {}, onCopyHandoff: {}, onNotNow: {})
                        .padding(GruxSpacing.l)
                })
            }
        }
        assertAllFit("selfupgrade", results)
    }

    // MARK: Onboarding

    /// Every screen of the first-run flow at the flow's minimum width.
    func test_everyOnboardingScreenFitsAtItsMinimumWidth() {
        var results: [PaneFitResult] = []
        for stage in OnboardingModel.Stage.allCases where stage != .done {
            results.append(PaneFitHarness.measure("onboarding-\(stage.rawValue)", width: GruxLayout.onboardingMinWidth,
                                                  height: GruxLayout.onboardingMinHeight) {
                ScrollView { OnboardingView.column(for: stage) }
            })
        }
        assertAllFit("onboarding", results)
    }

    // MARK: Sheets and popovers

    func test_theSheetsAndPopoversAPaneOpensFit() {
        let sheets: [(String, () -> AnyView)] = [
            ("sheet-new-event", { AnyView(NewEventSheet(defaultDay: Date(), onDone: { _ in })) }),
            ("sheet-contact-editor", { AnyView(ContactEditorSheet(contact: nil, onDone: { _ in })) }),
            ("sheet-folder-edit", { AnyView(FolderEditSheet(existing: nil, onSave: { _, _, _, _ in })) }),
            ("sheet-compose-email", { AnyView(ComposeEmailSheet()) }),
            ("sheet-mail-accounts", { AnyView(MailAccountsSheet()) }),
            ("sheet-webhook-edit", { AnyView(WebhookEditSheet(existing: nil, onSave: { _, _ in })) }),
            ("sheet-reply-rules", { AnyView(ReplyRulesSheet(brand: "example")) }),
        ]
        var results: [PaneFitResult] = []
        for (name, make) in sheets {
            for w in Self.sheetWidths {
                results.append(PaneFitHarness.measure(name, width: w, height: GruxLayout.sheetMaxHeight) { make() })
            }
        }
        // A popover is its own window at the one width it declares.
        results.append(PaneFitHarness.measure("popover-chat-threads", width: GruxLayout.listColumnIdeal,
                                              height: GruxLayout.sheetMaxHeight) {
            ChatThreadsSidebar()
        })
        results.append(PaneFitHarness.measure("popover-approvals", width: GruxLayout.trayPopoverWidth,
                                              height: GruxLayout.sheetMaxHeight) {
            ApprovalsTrayPanel(queue: ApprovalQueue.shared)
        })
        assertAllFit("sheets", results)
    }
}
