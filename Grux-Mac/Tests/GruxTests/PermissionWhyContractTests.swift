import XCTest
@testable import Grux

/// `why` is the case for granting a macOS permission, shown before the system
/// prompt fires. It is transcribed from contract section 1.2.1, and this suite
/// re-parses that document rather than trusting the transcription, for the
/// reason the registry already demonstrated: a hand copy drifts, and drift sits
/// behind a doc comment asserting it cannot.
///
/// Filed after the operator granted all nine permissions on a fresh install and
/// reported that nothing explained what any of them did.
final class PermissionWhyContractTests: XCTestCase {

    /// Section 1.2.1's table, parsed from the frozen contract at `docs/contract.md`.
    /// Same walk the other contract suites use.
    ///
    /// Unreadable FAILS rather than skips. This used to `throw XCTSkip`, which is
    /// the precise blind spot the sibling suites' comments warn about: a skip on a
    /// missing contract reports green while verifying nothing, and the contract was
    /// then reachable only by climbing six levels into a repo with no git remote,
    /// so every checkout but one skipped silently and looked fine.
    private static func contractWhy() throws -> [String: String] {
        let contract = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // GruxTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // Grux-Mac, the package root
            .appendingPathComponent("docs/contract.md")

        guard let text = try? String(contentsOf: contract, encoding: .utf8) else {
            XCTFail("""
                Could not read the frozen contract at \(contract.path).
                This test compares every perm `why` string against it, so a missing
                contract means the transcription is UNVERIFIED, which is not a pass.
                The contract ships in this repository at docs/contract.md, so an
                unreadable one means the checkout is incomplete.
                """)
            return [:]
        }

        // Only section 1.2.1, so a `perm.` row in some other table cannot be
        // mistaken for a why row.
        guard let start = text.range(of: "### 1.2.1") else {
            XCTFail("""
                The contract has no section 1.2.1, which is where CR-29 put the
                permission `why` table. A contract that lost the section this suite
                reads is drift, not a reason to skip.
                """)
            return [:]
        }
        let after = text[start.upperBound...]
        let end = after.range(of: "\n### ") ?? after.range(of: "\n## ")
        let section = end.map { String(after[..<$0.lowerBound]) } ?? String(after)

        var rows: [String: String] = [:]
        let re = try NSRegularExpression(
            pattern: #"^\|\s*`(perm\.[a-z0-9_]+)`\s*\|\s*([^|]+?)\s*\|\s*$"#,
            options: [.anchorsMatchLines])
        let ns = section as NSString
        for m in re.matches(in: section, range: NSRange(location: 0, length: ns.length)) {
            rows[ns.substring(with: m.range(at: 1))] = ns.substring(with: m.range(at: 2))
        }
        return rows
    }

    private var permissions: [SetupRequirement] {
        SetupRequirement.allCases.filter { $0.rawValue.hasPrefix("perm.") }
    }

    // MARK: - the contract binding

    func testEveryPermissionHasAWhyAndItMatchesTheContract() throws {
        let contract = try Self.contractWhy()
        XCTAssertFalse(contract.isEmpty, "parsed zero rows from section 1.2.1; the parser is wrong")

        for req in permissions {
            let expected = contract[req.rawValue]
            XCTAssertNotNil(expected,
                "\(req.rawValue) has no row in contract section 1.2.1. Every perm capability "
                + "needs one, or the permission screen has nothing to say about it.")
            if let expected {
                XCTAssertEqual(req.why, expected,
                    "\(req.rawValue) drifted from the contract.\n  swift:    \(req.why)\n  contract: \(expected)")
            }
        }
    }

    func testContractHasNoWhyRowForACapabilityThatNoLongerExists() throws {
        let contract = try Self.contractWhy()
        let live = Set(permissions.map(\.rawValue))
        for id in contract.keys {
            XCTAssertTrue(live.contains(id),
                "contract section 1.2.1 explains \(id), which is not a capability any more")
        }
    }

    // MARK: - the copy rules, which are the whole point

    /// The rule that makes this copy honest rather than a pitch. A user who is
    /// told only what they gain assumes the worst about what they lose, and the
    /// truth here is mild: almost nothing breaks, a feature just stays off.
    func testEveryWhyNamesAConsequenceOfDeclining() {
        for req in permissions {
            let t = req.why.lowercased()
            let names = ["decline", "without it", "without them", "stays off", "stay off"]
                .contains { t.contains($0) }
            XCTAssertTrue(names,
                "\(req.rawValue) says what you gain but never what happens if you say no:\n  \(req.why)")
        }
    }

    /// It has to be longer than the card text to be worth having as a separate
    /// field, and short enough to read on a permission screen.
    func testEveryWhyIsSubstantialButNotAnEssay() {
        for req in permissions {
            XCTAssertGreaterThan(req.why.count, 80,
                "\(req.rawValue) why is too thin to justify a separate field: \"\(req.why)\"")
            XCTAssertLessThanOrEqual(req.why.count, 260,
                "\(req.rawValue) why is \(req.why.count) chars, over the 260 the contract allows")
        }
    }

    /// Never blame the user and never claim the app is broken without a grant,
    /// which is the failure mode the contract calls out by name.
    func testNoWhyClaimsTheAppIsBrokenWithoutIt() {
        let banned = ["you must", "required", "will not work", "won't work", "unusable", "broken"]
        for req in permissions {
            let t = req.why.lowercased()
            for b in banned {
                XCTAssertFalse(t.contains(b),
                    "\(req.rawValue) why uses \"\(b)\"; none of these permissions are required:\n  \(req.why)")
            }
        }
    }

    /// Non-permission capabilities are configured rather than granted, and their
    /// remediation already names the action. An empty `why` there is correct,
    /// and a non-empty one means somebody filled in a field that nothing shows.
    func testNonPermissionCapabilitiesHaveNoWhy() {
        for req in SetupRequirement.allCases where !req.rawValue.hasPrefix("perm.") {
            XCTAssertTrue(req.why.isEmpty,
                "\(req.rawValue) is not a permission but carries a why string that no screen renders")
        }
    }
}
