import XCTest
@testable import Grux

/// The skills picker in the Chat composer, and what a picked skill does to
/// the message somebody is in the middle of writing.
final class ComposerSkillsTests: XCTestCase {

    /// The invocation names the skill exactly as the system prompt's
    /// LEARNED_SKILLS block does, or the model has to guess which one is meant.
    func testTheInvocationNamesTheSkillVerbatim() {
        XCTAssertEqual(ComposerSkills.invocation(for: "ship-release-notes"),
                       "Use my ship-release-notes skill: ")
    }

    func testPickingIntoAnEmptyDraftLeavesJustTheInvocation() {
        XCTAssertEqual(ComposerSkills.apply("ship-release-notes", to: ""),
                       "Use my ship-release-notes skill: ")
        XCTAssertEqual(ComposerSkills.apply("ship-release-notes", to: "  \n"),
                       "Use my ship-release-notes skill: ")
    }

    /// What the person already typed is kept, after the skill. Losing a
    /// half-written message to a picker is the failure this guards.
    func testPickingKeepsWhatWasAlreadyTyped() {
        XCTAssertEqual(ComposerSkills.apply("ship-release-notes", to: "for version 3.0"),
                       "Use my ship-release-notes skill: for version 3.0")
    }

    func testPickingTheSameSkillTwiceChangesNothing() {
        let once = ComposerSkills.apply("ship-release-notes", to: "for version 3.0")
        XCTAssertEqual(ComposerSkills.apply("ship-release-notes", to: once), once)
    }

    /// The chip says how many skills sit behind it, so an empty picker is not
    /// something a person has to open to discover.
    func testTheChipCountsWhatIsBehindIt() {
        XCTAssertEqual(ComposerSkills.chipLabel(count: 0), "SKILLS")
        XCTAssertEqual(ComposerSkills.chipLabel(count: 3), "SKILLS 3")
    }
}
