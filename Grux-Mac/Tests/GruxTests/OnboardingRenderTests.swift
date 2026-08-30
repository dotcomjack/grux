import XCTest
import SwiftUI
@testable import Grux

/// Renders every onboarding screen, and can write them out as PNGs.
///
/// This exists because the honest way to look at this flow was blocked. The
/// running app only shows onboarding while `stage != .done`, and the owner's
/// install is `done`, so driving the live app to photograph the flow would mean
/// writing to their `onboarding.json` and putting their working Grux back into
/// first-run. Their data is theirs, so that is not a verification method.
///
/// Rendering the same SwiftUI views through `NSHostingView` gives real layout at
/// a real size without touching a single file. Set `GRUX_SHOT_DIR` to a writable
/// directory and the images land there:
///
///     GRUX_SHOT_DIR=/tmp/onb swift test --filter OnboardingRenderTests
///
/// Without it the views are still rendered and still have to lay out, so the
/// crash-and-layout half runs on every suite.
@MainActor
final class OnboardingRenderTests: XCTestCase {

    /// The two sizes every visual check in this project uses: the narrow floor
    /// and a wide window. A layout that only works at one width has repeatedly
    /// turned out to be broken at the other.
    private let sizes: [(String, CGSize)] = [
        ("840x560", CGSize(width: 840, height: 560)),
        ("2400x1300", CGSize(width: 2400, height: 1300))
    ]

    private func render<V: View>(_ view: V, name: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        for (label, size) in sizes {
            // Matches OnboardingView's own container: the flow constrains its
            // content to 520pt and centres it, so rendering the bare step at
            // 2400 wide would measure a layout that never reaches a user.
            let wrapped = ZStack {
                GruxTheme.base
                // The ScrollView is part of the container under test, not a
                // convenience for the harness. Without it here the render shows
                // a screen the app does not ship, which is how the first pass
                // photographed "How Grux works" with its title clipped away and
                // no way to tell whether the app or the harness was at fault.
                ScrollView {
                    view.frame(maxWidth: 520).padding(40).frame(maxWidth: .infinity)
                }
            }
            .frame(width: size.width, height: size.height)
            // Matches OnboardingView too, and this is not cosmetic detail in a
            // test. Without it the first render came back with a SYSTEM BLUE
            // Continue button, because `.keyboardShortcut(.defaultAction)` makes
            // macOS fill the default button with the system accent. That is
            // precisely the bug OnboardingView's own tint exists to prevent, so
            // a harness that omits it photographs a screen that never ships and
            // would send somebody chasing a defect in the product.
            .tint(GruxTheme.accentPrimary)

            let host = NSHostingView(rootView: wrapped)
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()

            XCTAssertGreaterThan(host.fittingSize.height, 0,
                                 "\(name) at \(label) produced no layout", file: file, line: line)

            guard let dir = ProcessInfo.processInfo.environment["GRUX_SHOT_DIR"] else { continue }
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { continue }
            let url = URL(fileURLWithPath: dir)
                .appendingPathComponent("\(name)-\(label).png")
            try? FileManager.default.createDirectory(atPath: dir,
                                                     withIntermediateDirectories: true)
            try? png.write(to: url)
        }
    }

    func testLevelStepRenders()       { render(LevelStep(), name: "level") }

    // THREE STAGES HAD NO VISUAL COVERAGE AT ALL until 2026-08-22, and they are
    // the three a user meets EARLIEST: identity is screen two, the model key is
    // screen three, and the first look is the one screen that gives before it
    // asks. The harness rendered six of the ten stages and nobody had noticed
    // which four were missing, which is the failure mode a coverage list exists
    // to prevent: it looked thorough.
    func testIdentityStepRenders()    { render(IdentityStep(), name: "identity") }
    func testModelKeyStepRenders()    { render(ModelKeyStep(), name: "modelKey") }

    /// The model key step with a REJECTED key showing, which is the single most
    /// likely thing to go wrong in first run: somebody pastes a truncated key.
    /// The path behind it is sound (a real one token call to the provider, 401
    /// and 403 rejected with a sentence, 429 accepted because rate limited is
    /// not a bad key, and an offline catch that proceeds rather than trapping
    /// somebody on a plane) but the state a user actually SEES had never been
    /// looked at.
    ///
    /// Sets `keyError` directly on the shared model, which is safe in a way the
    /// stage is not: `keyError` is plain `@Published` with no `didSet`, so
    /// nothing is written to the operator's `onboarding.json`. Restored after,
    /// so test order cannot matter.
    func testModelKeyStepRendersARejectedKey() {
        let model = OnboardingModel.shared
        let previous = model.keyError
        defer { model.keyError = previous }

        model.keyError = "That key was rejected. Check you copied all of it."
        render(ModelKeyStep(), name: "modelKeyRejected")
    }
    func testFirstLookStepRenders()   { render(FirstLookStep(), name: "firstLook") }

    /// The first look in the states a headless render can never reach on its
    /// own. `.capturing` is the ONLY one the live step can produce here, because
    /// its `.task` has not finished when layout runs, so the three that matter
    /// most were unphotographed: the two a user actually meets when something
    /// goes wrong, and the one that is the entire point of the screen.
    func testFirstFrameReviewStatesRender() {
        render(FirstFrameReview(fixed: .needsPermission), name: "firstLookNeedsPermission")
        render(FirstFrameReview(fixed: .failed("Screen Recording is on, but macOS returned no frame. Quit and reopen Grux.")),
               name: "firstLookFailed")

        // A stand-in frame. The point is the surrounding chrome and the redacted
        // text, not the picture, and a real capture would put whatever happens to
        // be on the machine into a checked-in screenshot.
        let frame = NSImage(size: NSSize(width: 480, height: 300))
        frame.lockFocus()
        NSColor(calibratedRed: 0.09, green: 0.09, blue: 0.11, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 480, height: 300)).fill()
        NSColor(calibratedRed: 0.48, green: 0.38, blue: 1.0, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(x: 24, y: 220, width: 300, height: 18)).fill()
        frame.unlockFocus()

        render(FirstFrameReview(fixed: .ready(image: frame,
                                              redacted: "Reviewing a pull request in Xcode. The diff touches [REDACTED] and a test file. No credentials were found in this frame.",
                                              redactionCount: 1,
                                              app: "Xcode")),
               name: "firstLookReady")
    }
    func testHowItWorksStepRenders()  { render(HowItWorksStep(), name: "howItWorks") }
    func testPermissionsStepRenders() { render(PermissionsStep(), name: "permissions") }
    func testConnectionsStepRenders() { render(ConnectionsStep(), name: "connections") }
    func testUpdateStepRenders()      { render(UpdateStep(), name: "update") }
    func testCloneStepRenders()       { render(CloneStep(), name: "clone") }

    /// The update screen with REAL CONTENT in it, which the live step cannot
    /// show here: it fills itself from a `.task` and a headless render lays out
    /// before that completes, so `update-*.png` is only ever the spinner. Every
    /// claim on this screen is machine-specific, so "does it read correctly once
    /// filled in" is exactly what a screenshot should settle.
    func testUpdateSummaryRendersWithContent() {
        let studio = HardwareProfile(chipName: "Apple M4 Max",
                                     physicalMemoryBytes: 128 * 1_073_741_824,
                                     gpuWorkingSetBytes: 96 * 1_073_741_824,
                                     cpuCoreCount: 16, hasUnifiedMemory: true,
                                     isAppleSilicon: true)
        render(ModelUpdateSummary(report: .build(profile: studio,
                                                 hasCloudModel: true,
                                                 localServerRunning: true,
                                                 installedTags: ["llama3.1:8b", "gemma3:4b"])),
               name: "updateFilled")

        // The other end of the range, where the honest answer is that this Mac
        // cannot run one and Grux says so without dressing it up.
        let air = HardwareProfile(chipName: "Apple M1", physicalMemoryBytes: 8 * 1_073_741_824,
                                  gpuWorkingSetBytes: 5 * 1_073_741_824,
                                  cpuCoreCount: 8, hasUnifiedMemory: true,
                                  isAppleSilicon: true)
        render(ModelUpdateSummary(report: .build(profile: air,
                                                 hasCloudModel: false,
                                                 localServerRunning: false,
                                                 installedTags: [])),
               name: "updateSmallMac")
    }

    /// Some screens are TALLER than the window is allowed to be, so the flow has
    /// to scroll. This measures the first half of that claim and asserts the
    /// second.
    ///
    /// `OnboardingView` declares `minHeight: 520`. "How Grux works" lays out
    /// three autonomy tiers and five explanations and needs roughly double that.
    /// Before the ScrollView it clipped its own title at the 840x560 floor and
    /// left "Got it" on the bottom edge, which at the smallest supported size
    /// meant the user could not reach the control that leaves the screen.
    ///
    /// The source check is deliberate and is the part that survives. Height
    /// alone cannot fail: a tall step is fine INSIDE a scroll view and fatal
    /// outside one, and there is no way to ask a rendered SwiftUI tree which it
    /// is in. So the measurement establishes that the risk is real and the scan
    /// establishes that the mitigation is still there.
    func testTallStepsExistAndTheFlowScrolls() throws {
        let minWindowHeight: CGFloat = 520
        var tallest: CGFloat = 0

        for view in [AnyView(HowItWorksStep()), AnyView(ConnectionsStep()),
                     AnyView(LevelStep()), AnyView(PermissionsStep()),
                     AnyView(UpdateStep())] {
            let host = NSHostingView(rootView: view.frame(width: 520).padding(40))
            host.layoutSubtreeIfNeeded()
            tallest = max(tallest, host.fittingSize.height)
        }

        XCTAssertGreaterThan(tallest, minWindowHeight,
                             "no step is taller than the minimum window, so this test is no "
                             + "longer measuring anything and the ScrollView requirement below "
                             + "may have become vacuous")

        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/Grux/Onboarding/OnboardingView.swift"),
            encoding: .utf8)

        XCTAssertTrue(source.contains("ScrollView"),
                      "a step lays out at \(Int(tallest))pt inside a window whose minimum height "
                      + "is \(Int(minWindowHeight))pt, so OnboardingView must scroll or the "
                      + "bottom of that screen, including its only button, is unreachable")
    }

    /// None of the new screens may depend on an injected environment object.
    /// `OnboardingView` is hosted inside the app shell today, but the setup card
    /// shipped that exact assumption and it turned into a crash the moment a
    /// second window rendered it without one.
    func testEveryStepRendersWithNoEnvironmentObject() {
        for (_, size) in sizes {
            for view in [AnyView(LevelStep()), AnyView(HowItWorksStep()),
                         AnyView(PermissionsStep()), AnyView(ConnectionsStep()),
                         AnyView(UpdateStep()), AnyView(CloneStep())] {
                let host = NSHostingView(rootView: view.frame(width: size.width))
                host.frame = NSRect(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
            }
        }
    }
}
