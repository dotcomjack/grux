import XCTest
import SwiftUI
@testable import Grux

/// D200 item 1 (sense pass 28, `jaxHQ-1.png`): with no mail account, Jax HQ
/// dimmed its WHOLE page behind the mail setup card, so its PENDING APPROVALS
/// ("Save your note ...", "Start a self-upgrade cycle") read greyed out and their
/// Approve buttons took no click, though nothing in an approval needs mail. The
/// gate now has a mode where only the parts that need the capability dim, and
/// Jax HQ marks its mail parts.
final class JaxHQGateTests: XCTestCase {

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    // MARK: The gate's two decisions, every combination

    func testTheGateHandsDimmingToPartsOnlyWhenTheCardIsUpAndThePaneAsked() {
        XCTAssertTrue(CapabilityGate<EmptyView>.leavesDimmingToParts(needsSetup: true, keepsUnneededPartsLive: true),
                      "a pane that marks its own parts must stay live around the card")
        XCTAssertFalse(CapabilityGate<EmptyView>.leavesDimmingToParts(needsSetup: true, keepsUnneededPartsLive: false),
                       "every other gated pane still dims whole")
        XCTAssertFalse(CapabilityGate<EmptyView>.leavesDimmingToParts(needsSetup: false, keepsUnneededPartsLive: true),
                       "with the capability there, nothing is dimmed and no card is drawn")
        XCTAssertFalse(CapabilityGate<EmptyView>.leavesDimmingToParts(needsSetup: false, keepsUnneededPartsLive: false))
    }

    func testAMarkedPartDimsOnlyWhileACardIsUp() {
        XCTAssertTrue(CapabilityGate<EmptyView>.dimsPart(pendingTab: "jaxHQ"),
                      "a mail part must dim while the mail card is up")
        XCTAssertFalse(CapabilityGate<EmptyView>.dimsPart(pendingTab: nil),
                       "outside a parts-mode gate, or once mail is set up, a marked part is live")
    }

    // MARK: Jax HQ uses the mode and marks exactly its mail parts

    func testJaxHQAsksTheGateToKeepItsUnneededPartsLive() throws {
        let pane = try source("Sources/Grux/Shell/SurfacePane.swift")
        XCTAssertTrue(pane.contains(#"JaxHQView().capabilityGated("jaxHQ", keepsUnneededPartsLive: true)"#),
                      "Jax HQ must not be dimmed whole behind the mail card")
    }

    /// Each section's own text in JaxHQView's body, from its name to the next
    /// section (or the end of the stack).
    private func sectionChunks() throws -> [String: String] {
        let src = try source("Sources/Grux/Jax/JaxHQView.swift")
        let body = try XCTUnwrap(src.range(of: "var body: some View {")).upperBound
        let end = try XCTUnwrap(src.range(of: ".padding(20)", range: body..<src.endIndex)).lowerBound
        let stack = String(src[body..<end])
        let names = ["CapabilitySetupSlot", "JaxDraftsSection", "JaxFilteredSection", "JaxLessonsSection",
                     "JaxSendAutonomySection", "JaxApprovalsSection", "JaxBriefingSection",
                     "JaxGoalsSection", "JaxActivitySection"]
        var starts: [(String, String.Index)] = []
        for name in names {
            let r = try XCTUnwrap(stack.range(of: name + "("), "\(name) is not in Jax HQ's body")
            starts.append((name, r.lowerBound))
        }
        starts.sort { $0.1 < $1.1 }
        var chunks: [String: String] = [:]
        for (i, (name, start)) in starts.enumerated() {
            let stop = i + 1 < starts.count ? starts[i + 1].1 : stack.endIndex
            chunks[name] = String(stack[start..<stop])
        }
        return chunks
    }

    func testOnlyTheMailPartsOfJaxHQDim() throws {
        let chunks = try sectionChunks()
        for mailPart in ["JaxDraftsSection", "JaxFilteredSection", "JaxLessonsSection",
                         "JaxSendAutonomySection", "JaxBriefingSection"] {
            XCTAssertTrue(chunks[mailPart]?.contains(".needsGatedCapability()") == true,
                          "\(mailPart) reads mail, so it dims while the mail card is up")
        }
        for livePart in ["JaxApprovalsSection", "JaxGoalsSection", "JaxActivitySection"] {
            XCTAssertFalse(chunks[livePart]?.contains(".needsGatedCapability()") ?? true,
                           "\(livePart) needs no mail account, so it stays live behind the card")
        }
    }

    func testTheMailCardSitsAboveTheApprovalsItDoesNotBlock() throws {
        let src = try source("Sources/Grux/Jax/JaxHQView.swift")
        let slot = try XCTUnwrap(src.range(of: "CapabilitySetupSlot()"), "Jax HQ must draw its setup card")
        let approvals = try XCTUnwrap(src.range(of: "JaxApprovalsSection("))
        let firstMail = try XCTUnwrap(src.range(of: "JaxDraftsSection("))
        XCTAssertLessThan(slot.lowerBound, approvals.lowerBound)
        XCTAssertLessThan(slot.lowerBound, firstMail.lowerBound,
                          "the card comes first, so a stranger reads what Jax HQ needs before the dimmed parts")
    }

    /// The parts-mode gate renders in a bare host like the whole-pane gate.
    @MainActor
    func testThePartsModeGateRendersWithNoEnvironment() {
        let host = NSHostingView(rootView: VStack {
            CapabilitySetupSlot()
            Text("mail part").needsGatedCapability()
            Text("live part")
        }.capabilityGated("jaxHQ", keepsUnneededPartsLive: true))
        host.frame = NSRect(x: 0, y: 0, width: 840, height: 560)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.height, 0)
    }
}
