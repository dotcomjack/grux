import XCTest
@testable import Grux

/// D117 (sense pass 12, `jaxHQ-page1.png`): Jax HQ read "spoken 3:00 PM" and
/// the Activity log "Spoke the on-demand briefing" on a Mac where nothing was
/// spoken. Every briefing was labelled spoken, while the passive refresh never
/// speaks and a briefing with spoken briefings off (the default), replies
/// aloud off, muted or silent never reaches a speaker. A briefing now records
/// whether it was spoken, and the labels say "written" otherwise.
final class BriefingSpokenLabelTests: XCTestCase {

    private func briefing(spoken: Bool?, slot: Briefing.Slot = .onDemand) -> Briefing {
        Briefing(date: Date(timeIntervalSince1970: 1_800_000_000), slot: slot,
                 spokenText: "Morning, here is where we stand.", items: [], spoken: spoken)
    }

    /// Every gate, each one alone closed: only all open speaks.
    func test_aBriefingIsSpokenOnlyWhenEveryGateIsOpen() {
        XCTAssertTrue(BriefingEngine.speaks(asked: true, spokenBriefingsEnabled: true, speakRepliesAloud: true,
                                            voiceMuted: false, silent: false))
        XCTAssertFalse(BriefingEngine.speaks(asked: false, spokenBriefingsEnabled: true, speakRepliesAloud: true,
                                             voiceMuted: false, silent: false), "the passive refresh")
        XCTAssertFalse(BriefingEngine.speaks(asked: true, spokenBriefingsEnabled: false, speakRepliesAloud: true,
                                             voiceMuted: false, silent: false), "spoken briefings off, the default")
        XCTAssertFalse(BriefingEngine.speaks(asked: true, spokenBriefingsEnabled: true, speakRepliesAloud: false,
                                             voiceMuted: false, silent: false), "replies aloud off")
        XCTAssertFalse(BriefingEngine.speaks(asked: true, spokenBriefingsEnabled: true, speakRepliesAloud: true,
                                             voiceMuted: true, silent: false), "muted")
        XCTAssertFalse(BriefingEngine.speaks(asked: true, spokenBriefingsEnabled: true, speakRepliesAloud: true,
                                             voiceMuted: false, silent: true), "SILENT or HEADLESS")
    }

    func test_theBriefingStampSaysSpokenOnlyForASpokenBriefing() {
        XCTAssertTrue(JaxBriefingSection.stamp(briefing(spoken: true)).hasPrefix("spoken "))
        XCTAssertTrue(JaxBriefingSection.stamp(briefing(spoken: false)).hasPrefix("written "))
        XCTAssertTrue(JaxBriefingSection.stamp(briefing(spoken: nil)).hasPrefix("written "),
                      "a briefing saved before this knew nothing about speaking; it never claims it")
    }

    func test_theActivityLogSaysSpokeOnlyForASpokenBriefing() {
        let spoke = JaxActivitySection.briefingEntry(briefing(spoken: true, slot: .morning))
        XCTAssertEqual(spoke.text, "Spoke the morning briefing")
        XCTAssertEqual(spoke.kind, .spoke)
        let wrote = JaxActivitySection.briefingEntry(briefing(spoken: false))
        XCTAssertEqual(wrote.text, "Wrote the on-demand briefing")
        XCTAssertEqual(wrote.kind, .wrote)
        XCTAssertEqual(JaxActivitySection.briefingEntry(briefing(spoken: nil, slot: .night)).text, "Wrote the night briefing")
    }

    /// A briefing on disk from before carries no `spoken`; it reads as not spoken.
    func test_aBriefingSavedBeforeDecodesAsNotSpoken() throws {
        let old = """
        {"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","date":800000000,"slot":"onDemand",
         "spokenText":"Morning.","items":[]}
        """
        let b = try JSONDecoder().decode(Briefing.self, from: Data(old.utf8))
        XCTAssertNil(b.spoken)
        XCTAssertTrue(JaxBriefingSection.stamp(b).hasPrefix("written "))
    }

    /// The views draw the tested lines, and the engine records the answer
    /// before it persists the briefing.
    func test_theViewsAndTheEngineUseTheTestedRule() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func src(_ p: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(p), encoding: .utf8)
        }
        let section = try src("Sources/Grux/Jax/JaxBriefingSection.swift")
        XCTAssertTrue(section.contains("Text(Self.stamp(briefing))"))
        XCTAssertFalse(section.contains("Text(\"spoken \\("))
        let activity = try src("Sources/Grux/Jax/JaxActivitySection.swift")
        XCTAssertTrue(activity.contains("out.append(Self.briefingEntry(b))"))
        XCTAssertEqual(activity.components(separatedBy: "\"Spoke the ").count, 2, "one Spoke line")
        let rule = try XCTUnwrap(activity.range(of: "static func briefingEntry("))
        let spokeLine = try XCTUnwrap(activity.range(of: "\"Spoke the "))
        XCTAssertLessThan(rule.lowerBound, spokeLine.lowerBound, "the Spoke line lives inside the tested rule")
        let engine = try src("Sources/Grux/Jax/BriefingEngine.swift")
        let decided = try XCTUnwrap(engine.range(of: "let spoke = Self.speaks("))
        let made = try XCTUnwrap(engine.range(of: "items: items, spoken: spoke)"))
        let persisted = try XCTUnwrap(engine.range(of: "persist(briefing)"))
        XCTAssertLessThan(decided.lowerBound, made.lowerBound)
        XCTAssertLessThan(made.lowerBound, persisted.lowerBound)
    }
}
