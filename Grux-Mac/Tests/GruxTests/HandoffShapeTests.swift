import XCTest
@testable import Grux

/// The shape of the handoff document, which is the half a stranger recognises.
///
/// A person who has read one handoff should be able to skim any other, and that is the entire
/// value of fixing the headings. These pin the shape rather than the copy: what the sections
/// are, what order they come in, that the document fits a terminal, and that the boundary
/// between what an agent may do and what only a person may do is never crossed.
@MainActor
final class HandoffShapeTests: XCTestCase {

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: FeatureSelection.defaultsKey)
        super.tearDown()
    }

    private func everything() -> String {
        AgentHandoff.promptFor(agent: Array(AgentHandoff.delegable),
                               human: SetupRequirement.allCases
                                   .filter { !AgentHandoff.delegable.contains($0) })
    }

    /// All six, in order, each on its own line.
    func testTheSixHeadingsAppearExactlyOnceAndInOrder() {
        let prompt = everything()
        let lines = prompt.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        var found: [String] = []
        for line in lines where AgentHandoff.headings.contains(line) {
            found.append(line)
        }
        XCTAssertEqual(found, AgentHandoff.headings,
            "headings rendered as \(found), expected \(AgentHandoff.headings)")
    }

    /// A HEADING IS A WHOLE LINE, never a word inside a sentence.
    ///
    /// Without this the test above passes on a document whose sections are prose. The check
    /// that matters is that a reader can find them by scanning the left margin.
    func testEveryHeadingIsAlone_OnItsOwnLine() {
        let lines = everything().split(separator: "\n").map(String.init)
        for heading in AgentHandoff.headings {
            XCTAssertTrue(lines.contains(heading),
                "\(heading) never appears as a line of its own")
        }
    }

    /// PASTED INTO A TERMINAL. 76 columns, and this covers the generated half too, which is
    /// the half that used to run long because nobody had hand-broken it.
    ///
    /// THE LITERAL 76 IS DELIBERATE. This first read `$0.count > AgentHandoff.width`, which
    /// is the same constant the renderer wraps to, so setting the width to 200 moved the
    /// assertion with it and the test passed against a document running to 200 columns.
    /// Measured, by planting exactly that. A requirement that comes from outside the code,
    /// and the width of a terminal does, has to be written down in the test as a number and
    /// not read back out of the thing being tested.
    func testNothingExceedsSeventySixColumns() {
        let prompt = everything()
        let over = prompt.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { $0.count > 76 }
        XCTAssertTrue(over.isEmpty,
            "\(over.count) line(s) run past 76 columns, longest "
            + "\(over.map(\.count).max() ?? 0): \(over.first ?? "")")
    }

    /// And the constant the renderer uses is the one the requirement names.
    func testTheRendererWrapsToSeventySix() {
        XCTAssertEqual(AgentHandoff.width, 76,
            "the handoff wraps to \(AgentHandoff.width), and the grammar says 76 because it "
            + "is pasted into a terminal")
    }

    /// And it is actually wrapping, not just short by luck. A document whose longest line is
    /// 40 would pass the check above while proving nothing about the wrapper.
    func testTheDocumentIsActuallyBeingWrapped() {
        let longest = everything().split(separator: "\n").map(\.count).max() ?? 0
        XCTAssertGreaterThan(longest, 60,
            "longest line is \(longest), so the wrapper is not being exercised and the "
            + "76 column assertion above is vacuous")
    }

    /// A wrapped bullet continues UNDER ITS OWN TEXT, not under the dash.
    ///
    /// At the same indent as the dash a continuation line reads as a new item, which in the
    /// one document that gets pasted somewhere else and read by a stranger is the worst place
    /// for a list to become ambiguous.
    func testAWrappedBulletHangsUnderItsText() {
        let lines = everything().split(separator: "\n").map(String.init)
        var checked = 0
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- "), i + 1 < lines.count else { continue }
            let next = lines[i + 1]
            let nextTrimmed = next.trimmingCharacters(in: .whitespaces)
            // A continuation, rather than the next bullet or a blank line.
            guard !nextTrimmed.isEmpty, !nextTrimmed.hasPrefix("- "),
                  !AgentHandoff.headings.contains(next), !nextTrimmed.hasSuffix(":") else {
                continue
            }
            let dashIndent = line.prefix { $0 == " " }.count
            let contIndent = next.prefix { $0 == " " }.count
            XCTAssertGreaterThan(contIndent, dashIndent,
                "a wrapped bullet continues at the dash's own indent, so it reads as a new "
                + "item:\n\(line)\n\(next)")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 0,
            "no wrapped bullet was found, so this test proved nothing")
    }

    /// THE BOUNDARY. Nothing under YOURS may be a consent decision.
    func testNoConsentStepIsEverHandedToAnAgent() {
        let prompt = everything()
        guard let yours = prompt.range(of: "\nYOURS\n"),
              let mine = prompt.range(of: "\nMINE\n") else {
            return XCTFail("could not find the YOURS section")
        }
        let section = String(prompt[yours.upperBound..<mine.lowerBound])
        for step in AgentHandoff.consentSteps {
            XCTAssertFalse(section.contains(step.label),
                "\(step.rawValue) is offered to an agent under YOURS")
        }
    }

    // MARK: - Scoping

    /// A SCOPED HANDOFF CAN NEVER NAME SOMETHING THE UNSCOPED ONE WOULD NOT.
    ///
    /// `grux handoff meetings` answers "what would it take to get this working", and the
    /// value of that answer is that it is SHORTER. A scope that quietly widened, or that
    /// named a capability belonging to a feature nobody asked about, would be worse than no
    /// scoping at all: it reads as a precise list and is not one.
    func testAScopedHandoffIsASubsetOfTheWholeOne() {
        FeatureSelection.choose(Set(FeatureRegistry.rows.map(\.id)))

        guard let meetings = FeatureRegistry.rows.first(where: { $0.id == "meetings" }) else {
            return XCTFail("no meetings feature to scope to")
        }
        let scoped = AgentHandoff.promptFor(features: ["meetings"])
        let whole = AgentHandoff.prompt()

        let claimed = Set(meetings.blocking + meetings.optional + meetings.optionalSteps)
        var namedInScope = 0
        for req in SetupRequirement.allCases where scoped.contains(req.label) {
            namedInScope += 1
            XCTAssertTrue(claimed.contains(req),
                "\(req.rawValue) is in a handoff scoped to Meetings and Meetings does not "
                + "claim it")
            XCTAssertTrue(whole.contains(req.label),
                "\(req.rawValue) appears when scoped but not in the unscoped handoff")
        }
        XCTAssertGreaterThan(namedInScope, 0,
            "the scoped handoff named nothing at all, so this proves nothing")
    }

    /// And it is genuinely narrower, or scoping is decoration.
    func testScopingActuallyNarrows() {
        FeatureSelection.choose(Set(FeatureRegistry.rows.map(\.id)))
        let one = AgentHandoff.promptFor(features: ["meetings"])
        let all = AgentHandoff.prompt()

        func named(_ text: String) -> Int {
            SetupRequirement.allCases.filter { text.contains($0.label) }.count
        }
        XCTAssertLessThan(named(one), named(all),
            "a handoff scoped to one feature names as much as the whole machine's, so the "
            + "scope is not being applied")
    }

    /// An empty scope is not "everything". It is a caller that asked for nothing, and the
    /// document has to say so rather than quietly widening to the whole machine.
    func testAnEmptyScopeNamesNothing() {
        let empty = AgentHandoff.promptFor(features: [])
        for req in SetupRequirement.allCases {
            XCTAssertFalse(empty.contains(req.label),
                "\(req.rawValue) is named in a handoff scoped to no features at all")
        }
        XCTAssertTrue(empty.contains("CONTEXT"), "an empty scope still renders the shape")
    }

    /// EXTRA IS COUNTED, so a seventh heading cannot arrive by habit.
    ///
    /// The grammar allows one optional section for a command that genuinely has something
    /// else to say. Counting it is what keeps that an exception: erosion here is gradual by
    /// nature, and a number in a test makes it a decision instead.
    func testExtraIsUsedNowhereYet() {
        let prompt = everything()
        let extras = prompt.split(separator: "\n").filter { $0 == "EXTRA" }.count
        XCTAssertEqual(extras, 0,
            "EXTRA is used \(extras) time(s). It is allowed, but it is meant to be rare, so "
            + "raise this number deliberately and say why in the commit.")
    }

    /// VERIFY tells the truth about what Grux can detect, and the numbers come from the
    /// resolver rather than from prose.
    ///
    /// This paragraph was wrong for a whole phase. It said Grux "does not go looking to see
    /// whether you installed them", flatly, after four steps had become detected. Telling an
    /// agent its work will not be noticed when it will is how somebody ticks a box by hand
    /// that was already true.
    func testVerifyCountsMatchTheResolver() {
        let prompt = everything()
        let detected = CapabilityResolver.detectedSteps.count
        let attested = CapabilityResolver.selfAttestedSteps.count

        XCTAssertTrue(prompt.contains("grux status --json"),
            "VERIFY does not name the command that verifies anything")
        XCTAssertTrue(prompt.contains("\(detected + attested) setup steps"),
            "VERIFY does not state the total number of steps")
        XCTAssertTrue(prompt.contains("\(detected) are ones Grux measures for itself"),
            "VERIFY does not say how many steps Grux detects, or says the wrong number")
        XCTAssertFalse(prompt.contains("it does not go looking"),
            "VERIFY still carries the claim that Grux detects nothing, which stopped being "
            + "true when the first step became detected")
    }
}
