import XCTest
import SwiftUI
@testable import Grux

/// Every Now row reads whole in the narrowest panel. The detail is the line
/// that says what to do, and it was cut on every pane at the default window:
/// "Claude sign-in expired   Agents cannot run until you si..." (sense pass 5,
/// `s5-shots/home-1.png`, D68).
@MainActor
final class PanelNowFitTests: XCTestCase {

    /// The Now list's width in the narrowest panel: the panel is the window's
    /// floor (`GruxLayout.panelWidth`) and `CommandPanelRoot` pads it by
    /// `GruxSpacing.l` on each side.
    private let narrowest = GruxLayout.panelWidth - 2 * GruxSpacing.l

    /// Every row Relevance can put in Now with a long detail, at once.
    private var crowded: RelevanceState {
        var s = RelevanceState()
        s.claudeSignInExpired = true
        s.chatNeedsModel = true
        s.approvalsPending = 1
        s.oldHookNeedsRemoval = true
        s.updateOffer = UpdateOffer(version: "3.2.0", viaHomebrew: true)
        s.jobsWaitingOnYou = [RunningJob(id: "j1", title: "Back up the Mini")]
        return s
    }

    func test_everyNowRowReadsWholeInTheNarrowestPanel() {
        let items = Relevance.now(crowded, cap: 20)
        XCTAssertTrue(items.contains { $0.id == "claude.signIn" }, "the fixture lost the sign-in row")
        let r = PaneFitHarness.measure("now-crowded", width: narrowest, height: 700) {
            PanelNowList(items: items, onAction: { _ in })
        }
        XCTAssertTrue(r.cutChips.isEmpty, "a Now row was cut: \(r.line)")
        XCTAssertTrue(r.fits, r.line)
    }

    func test_aWidePanelStillReadsWhole() {
        let items = Relevance.now(crowded, cap: 20)
        let r = PaneFitHarness.measure("now-crowded", width: 900, height: 700) {
            PanelNowList(items: items, onAction: { _ in })
        }
        XCTAssertTrue(r.fits, r.line)
    }

    /// The probe itself: a one-line text squeezed narrower than its words is
    /// seen, the same text with room is not, and a text free to wrap is not.
    func test_theTextProbeSeesACutLineAndOnlyACutLine() {
        let words = "Agents cannot run until you sign in"
        func line() -> some View { Text(words).font(GruxType.caption) }
        let cut = PaneFitHarness.measure("planted-cut-text", width: 120, height: 100, writePNG: false) {
            HStack {
                GruxProbeHost(words: words) { line().lineLimit(1) }
                    .frame(width: 80)
                Spacer()
            }
        }
        XCTAssertEqual(cut.cutChips.map(\.title), [words], "a cut line went unseen: \(cut.line)")
        let roomy = PaneFitHarness.measure("planted-roomy-text", width: 600, height: 100, writePNG: false) {
            GruxProbeHost(words: words) { line().lineLimit(1) }
        }
        XCTAssertTrue(roomy.cutChips.isEmpty, "a line with room read as cut: \(roomy.line)")
        let wrapped = PaneFitHarness.measure("planted-wrapped-text", width: 80, height: 200, writePNG: false) {
            GruxProbeHost(words: words) { line().fixedSize(horizontal: false, vertical: true) }
        }
        XCTAssertTrue(wrapped.cutChips.isEmpty, "a wrapped line read as cut: \(wrapped.line)")
    }
}

/// Wraps a planted text in the probe the way a surface does, reading the
/// sweep's recorder from the environment.
private struct GruxProbeHost<Shown: View>: View {
    let words: String
    @ViewBuilder var shown: () -> Shown
    @Environment(\.gruxChipCuts) private var cuts

    var body: some View {
        GruxTextCutProbe(text: words, cuts: cuts) {
            shown()
            Text(words).font(GruxType.caption).fixedSize(horizontal: false, vertical: true).hidden()
        }
    }
}
