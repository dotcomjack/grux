import XCTest
import SwiftUI
@testable import Grux

/// The first-run panel, in pixels, on the suite's clean state. Writes the
/// capture the evidence file cites when GRUX_FIRST_RUN_PANEL_CAPTURE is set.
@MainActor
final class FirstRunPanelCaptureTests: XCTestCase {
    private var savedRecents: [String] = []
    private var savedPins: [String] = []
    private var onboardingWasPresenting = false

    override func setUp() async throws {
        // R6.2: recents are process-wide and leak between classes; a first
        // run has none.
        let store = SidebarStateStore.shared
        savedRecents = store.recents
        savedPins = store.pinned
        store.replaceRecents([])
        store.replacePins([])
        onboardingWasPresenting = OnboardingModel.shared.isPresenting
        // Another class may leave the hub open; finishing onboarding must be
        // what opens it.
        OptimizeHubState.shared.isExpanded = false
    }

    override func tearDown() async throws {
        let store = SidebarStateStore.shared
        store.replaceRecents(savedRecents)
        store.replacePins(savedPins)
        OptimizeHubState.shared.isExpanded = false
        if onboardingWasPresenting, !OnboardingModel.shared.isPresenting { OnboardingModel.shared.reset() }
    }

    /// The panel's vertical bands, in points from the top, from the layout
    /// tokens the panel is built with: the head holds the orb, the input
    /// sits one gap under it, Now (or the hub) fills the middle, and the
    /// foot sits on the bottom padding.
    static let bands: [(name: String, top: CGFloat, bottom: CGFloat)] = {
        let gap = GruxSpacing.l
        let headBottom = gap + GruxLayout.panelOrb
        let inputTop = headBottom + gap
        let inputBottom = inputTop + GruxLayout.paneBarHeight
        let footTop = GruxLayout.panelIdealHeight - gap - GruxLayout.panelOrb
        return [("head", gap, headBottom),
                ("input", inputTop, inputBottom),
                ("now or hub", inputBottom + gap, GruxLayout.panelIdealHeight / 2),
                ("foot", footTop, GruxLayout.panelIdealHeight - gap)]
    }()

    func test_theFirstRunPanelHasNoRecentChipsAndTheHubExpanded() throws {
        let state = AppState.shared
        XCTAssertFalse(state.config.legacyShell)
        XCTAssertTrue(SidebarStateStore.shared.recents.isEmpty, "the suite's state already has recents")
        OnboardingModel.shared.finish(skippedFirstLook: true)
        XCTAssertEqual(OnboardingModel.shared.stage, .done)
        // R6.1: red until Task 10 makes finish() open the hub.
        XCTAssertTrue(OptimizeHubState.shared.isExpanded, "first run lands with the hub open")

        // R5.16: Now from a hand-built first-run state (setup gaps and
        // nothing waiting), never the suite's shared approval queue.
        let firstRun = RelevanceState(setupGaps: RelevanceState.live().setupGaps)
        let model = PanelModel(stateProvider: { firstRun }, sizeWindow: { _, _ in })
        let size = NSSize(width: GruxLayout.panelWidth, height: GruxLayout.panelIdealHeight)
        let host = NSHostingView(rootView: CommandPanelRoot(model: model).environmentObject(state)
            .frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        if let out = ProcessInfo.processInfo.environment["GRUX_FIRST_RUN_PANEL_CAPTURE"] {
            try png.write(to: URL(fileURLWithPath: out))
        }
        window.contentView = nil

        // R6.3: the right size, not empty, and something drawn in every band.
        let scale = window.backingScaleFactor
        XCTAssertEqual(rep.size, size, "the capture is not 420 x 560 points")
        XCTAssertEqual(rep.pixelsWide, Int(size.width * scale), "pixel width at scale \(scale)")
        XCTAssertEqual(rep.pixelsHigh, Int(size.height * scale), "pixel height at scale \(scale)")
        XCTAssertGreaterThan(png.count, 10_000, "the render came out empty")

        let pixels = try Pixels(rep)
        let background = pixels.mostCommon()
        for band in Self.bands {
            let rows = Int(band.top * scale)..<Int(band.bottom * scale)
            XCTAssertTrue(pixels.anyDiffers(from: background, inRows: rows),
                          "nothing drawn in the \(band.name) band (\(band.top) to \(band.bottom) pt)")
        }
    }
}

/// Raw 8-bit pixels of a bitmap, read directly rather than through
/// `colorAt`, which is too slow for a whole capture.
private struct Pixels {
    let data: UnsafeMutablePointer<UInt8>
    let width: Int, height: Int, bytesPerRow: Int, samples: Int
    let rep: NSBitmapImageRep   // keeps `data` alive

    init(_ rep: NSBitmapImageRep) throws {
        XCTAssertEqual(rep.bitsPerSample, 8, "unexpected bitmap depth")
        XCTAssertFalse(rep.isPlanar, "unexpected planar bitmap")
        self.rep = rep
        data = try XCTUnwrap(rep.bitmapData)
        width = rep.pixelsWide
        height = rep.pixelsHigh
        bytesPerRow = rep.bytesPerRow
        samples = rep.samplesPerPixel
    }

    func pixel(_ x: Int, _ y: Int) -> [UInt8] {
        let o = y * bytesPerRow + x * samples
        return (0..<samples).map { data[o + $0] }
    }

    /// The panel background: the colour most of the capture is.
    func mostCommon() -> [UInt8] {
        var counts: [[UInt8]: Int] = [:]
        for y in stride(from: 0, to: height, by: 2) {
            for x in stride(from: 0, to: width, by: 2) { counts[pixel(x, y), default: 0] += 1 }
        }
        return counts.max { $0.value < $1.value }?.key ?? []
    }

    /// Whether any pixel in `rows` differs from `background` by more than a
    /// rendering tolerance in some channel.
    func anyDiffers(from background: [UInt8], inRows rows: Range<Int>) -> Bool {
        for y in rows where y < height {
            for x in 0..<width {
                let p = pixel(x, y)
                for i in 0..<min(p.count, background.count) where abs(Int(p[i]) - Int(background[i])) > 16 {
                    return true
                }
            }
        }
        return false
    }
}
