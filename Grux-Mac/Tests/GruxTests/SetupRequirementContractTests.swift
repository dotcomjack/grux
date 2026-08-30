import XCTest
@testable import Grux

/// Proves SetupRequirement is a faithful transcription of the frozen contract,
/// instead of asserting it in a doc comment.
///
/// This test exists because the claim was false. SetupContract.swift said every
/// case carried its label and remediation "verbatim from the contract tables"
/// while holding 3 of the 40 ids, and 2 of those 3 had text that no longer
/// matched. Nothing caught it, because nothing compared the two files.
///
/// The contract ships INSIDE this package at `docs/contract.md`, so the path is
/// resolved from #filePath and never leaves the repository.
///
/// It used to live in a sibling repo reached by climbing six directory levels out
/// of the clone. That repo has no git remote, so it could not be cloned by anyone:
/// this suite could only pass on one machine, and every stranger who checked the
/// package out got an unreadable contract. The walk also assumed the clone sat
/// inside a `.worktrees/` directory, which is true of exactly one checkout.
///
/// A missing contract FAILS rather than skips: "I could not check" is not the same
/// as "it matches", and a silent skip would restore exactly the blind spot this
/// test was written to close.
final class SetupRequirementContractTests: XCTestCase {

    /// (id, label, remediation) for every capability row in the contract tables.
    private func contractRows() throws -> [String: (label: String, remediation: String)] {
        let here = URL(fileURLWithPath: #filePath)          // .../Grux-Mac/Tests/GruxTests/<this>
        let contract = here
            .deletingLastPathComponent()                     // GruxTests
            .deletingLastPathComponent()                     // Tests
            .deletingLastPathComponent()                     // Grux-Mac, the package root
            .appendingPathComponent("docs/contract.md")

        guard let text = try? String(contentsOf: contract, encoding: .utf8) else {
            XCTFail("""
                Could not read the frozen contract at \(contract.path).
                This test compares every SetupRequirement string against it, so a
                missing contract means the transcription is UNVERIFIED, which is
                not a pass. The contract ships in this repository at docs/contract.md,
                so an unreadable one means the checkout is incomplete.
                """)
            return [:]
        }

        // | `key.anthropic` | Anthropic API key | Add your Anthropic API key ... |
        let pattern = #"^\|\s*`((?:key|perm|endpoint|step)\.[a-z0-9_]+)`\s*\|\s*([^|]+?)\s*\|\s*([^|]+?)\s*\|\s*$"#
        let re = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        var rows: [String: (String, String)] = [:]
        let ns = text as NSString
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let id = ns.substring(with: m.range(at: 1))
            guard rows[id] == nil else { continue }          // first occurrence wins
            rows[id] = (ns.substring(with: m.range(at: 2)), ns.substring(with: m.range(at: 3)))
        }
        return rows
    }

    func testEveryContractCapabilityHasACase() throws {
        let rows = try contractRows()
        XCTAssertFalse(rows.isEmpty, "parsed zero capability rows, the table format changed")
        let cases = Set(SetupRequirement.allCases.map(\.rawValue))
        let missing = Set(rows.keys).subtracting(cases).sorted()
        XCTAssertTrue(missing.isEmpty, "contract ids with no Swift case: \(missing)")
    }

    func testEveryCaseExistsInTheContract() throws {
        let rows = try contractRows()
        let orphans = SetupRequirement.allCases
            .map(\.rawValue)
            .filter { rows[$0] == nil }
            .sorted()
        XCTAssertTrue(orphans.isEmpty, "Swift cases with no contract row, this is drift: \(orphans)")
    }

    func testLabelAndRemediationAreVerbatim() throws {
        let rows = try contractRows()
        for req in SetupRequirement.allCases {
            guard let row = rows[req.rawValue] else { continue }   // covered by the orphan test
            XCTAssertEqual(req.label, row.label,
                           "\(req.rawValue) label drifted from the contract")
            XCTAssertEqual(req.remediation, row.remediation,
                           "\(req.rawValue) remediation drifted from the contract")
        }
    }

    /// The contract caps remediation length. Measured, not trusted.
    func testRemediationsStayUnderTheContractCeiling() {
        for req in SetupRequirement.allCases {
            XCTAssertLessThan(req.remediation.count, 140,
                              "\(req.rawValue) remediation is \(req.remediation.count) chars")
        }
    }

    /// A deliberate tripwire. The two bidirectional tests above already prove the
    /// enum and the contract agree with each other, so they stay green when a
    /// capability is added to BOTH. This one fails on any change to the size of
    /// the setup surface, which is the moment to ask whether the new capability
    /// belongs in onboarding at all.
    ///
    /// The count is spelled in the test NAME on purpose, so updating the number
    /// without reading why is awkward. Was 42. Became 43 on 2026-08-23 with
    /// `step.terminal_sessions_explained`, the consent gate for Grux driving
    /// headless terminal sessions on the user's own subscription credential.
    /// Became 41 on 2026-08-28 with CR-34, which DELETED the two scalar provider
    /// key capabilities: a provider key is not a slot on the app, it is one key
    /// per user-added endpoint held by CustomEndpointStore, and no feature and no
    /// blueprint had declared either since CR-31 removed them from `chat`.
    func testAllFortyOneCapabilitiesArePresent() throws {
        let rows = try contractRows()
        XCTAssertEqual(rows.count, 41, "contract capability count changed, expected 41")
        XCTAssertEqual(SetupRequirement.allCases.count, 41)
    }
}
