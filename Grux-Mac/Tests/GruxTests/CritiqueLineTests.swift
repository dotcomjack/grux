import XCTest
@testable import Grux

/// D135 item 11 (sense pass 14): Design Studio's critique line read
/// "Critique: visual-hierarchy: The design has no type scale ... |
/// responsiveness: No responsive layout ...": the gate's own keys and a pipe
/// between two findings, under a reply in plain words. The line a person reads
/// names each lens in words and keeps each finding its own sentence.
final class CritiqueLineTests: XCTestCase {

    private func verdict(_ status: GateStatus, _ dims: [DimensionVerdict]) -> QualityVerdict {
        QualityVerdict(status: status, dimensions: dims, dupFindings: [], summary: "Blocked by 2 confirmed objection(s): visual-hierarchy, responsiveness.",
                       diffLineCount: 0, ranAt: Date(timeIntervalSince1970: 0))
    }

    private func refuted(_ name: String, _ reason: String) -> DimensionVerdict {
        DimensionVerdict(name: name, approved: false, severity: .high, reason: reason)
    }

    func testEveryLensHasAPlainNameThatIsNotItsKey() {
        for d in CritiqueGate.dimensions {
            let plain = CritiqueGate.plainName(d.name)
            XCTAssertNotEqual(plain, d.name, "\(d.name) is shown by its key")
            XCTAssertFalse(plain.contains("-"), "\(d.name) reads as a key: \(plain)")
            XCTAssertEqual(plain.first.map { $0.isUppercase }, true, "\(d.name): \(plain)")
        }
        XCTAssertEqual(Set(CritiqueGate.dimensions.map { CritiqueGate.plainName($0.name) }).count,
                       CritiqueGate.dimensions.count, "two lenses share a name")
    }

    func testTheSenseFourteenLineReadsInWords() {
        let line = CritiqueGate.personLine(verdict(.fail, [
            refuted("visual-hierarchy", "The design has no type scale, no spacing, and no call to action"),
            refuted("responsiveness", "No responsive layout implementation exists beyond a viewport meta tag."),
        ])) ?? ""
        for d in CritiqueGate.dimensions {
            XCTAssertFalse(line.contains(d.name), "the line shows the key \(d.name): \(line)")
        }
        XCTAssertFalse(line.contains("|"), "two findings joined by a pipe: \(line)")
        XCTAssertTrue(line.contains("\(CritiqueGate.plainName("visual-hierarchy")): The design has no type scale, no spacing, and no call to action. "), line)
        XCTAssertTrue(line.contains("\(CritiqueGate.plainName("responsiveness")): No responsive layout"), line)
        XCTAssertTrue(line.hasPrefix("Critique found 2 things to fix."), line)
    }

    /// One, two and three blockers: the count is whole, and a third is never
    /// dropped without a word.
    func testTheCountIsWholeAtOneTwoAndThree() {
        let all = [refuted("visual-hierarchy", "a."), refuted("responsiveness", "b."), refuted("accessibility", "c.")]
        let one = CritiqueGate.personLine(verdict(.fail, Array(all.prefix(1)))) ?? ""
        XCTAssertTrue(one.hasPrefix("Critique found 1 thing to fix."), one)
        let two = CritiqueGate.personLine(verdict(.fail, Array(all.prefix(2)))) ?? ""
        XCTAssertFalse(two.contains("more"), two)
        let three = CritiqueGate.personLine(verdict(.fail, all)) ?? ""
        XCTAssertTrue(three.hasPrefix("Critique found 3 things to fix."), three)
        XCTAssertTrue(three.hasSuffix("And 1 more."), three)
        XCTAssertFalse(three.contains("accessibility"), three)
    }

    /// An approved lens or a low-severity objection is not a thing to fix.
    func testOnlyBlockingLensesAreCounted() {
        let line = CritiqueGate.personLine(verdict(.fail, [
            refuted("visual-hierarchy", "a."),
            DimensionVerdict(name: "responsiveness", approved: true, severity: .none, reason: "fine."),
            DimensionVerdict(name: "accessibility", approved: false, severity: .low, reason: "nit."),
        ])) ?? ""
        XCTAssertTrue(line.hasPrefix("Critique found 1 thing to fix."), line)
        XCTAssertFalse(line.contains("fine.") || line.contains("nit."), line)
    }

    func testPassAndSkipLinesNameNoKey() {
        let pass = CritiqueGate.personLine(verdict(.pass, CritiqueGate.dimensions.map {
            DimensionVerdict(name: $0.name, approved: true, severity: .none, reason: "ok")
        })) ?? ""
        XCTAssertEqual(pass, "Critique: all 5 reviews cleared this design.")
        XCTAssertEqual(CritiqueGate.personLine(verdict(.error, [])), "(critique skipped: reviewer unavailable)")
        XCTAssertNil(CritiqueGate.personLine(verdict(.pending, [])))
        XCTAssertNil(CritiqueGate.personLine(verdict(.running, [])))
    }
}
