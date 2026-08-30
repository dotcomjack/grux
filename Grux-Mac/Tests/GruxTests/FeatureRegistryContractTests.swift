import XCTest
@testable import Grux

/// Proves FeatureRegistry still matches `docs/feature-registry.md`.
///
/// The Swift literal is generated from that document, which makes it correct on
/// the day it is written and says nothing about any day after. This test is the
/// part that keeps it true: it re-parses the registry and compares row by row,
/// so a row added, removed, retiered or given a different capability in the
/// document fails the suite instead of silently disagreeing with the code that
/// claims to transcribe it.
///
/// A missing document FAILS rather than skips, for the same reason as
/// SetupRequirementContractTests: "I could not check" is not "it matches".
@MainActor
final class FeatureRegistryContractTests: XCTestCase {

    private struct DocRow: Equatable {
        var label: String
        var tier: String
        var requires: [String]
        var optional: [String]
        var steps: [String]
        var optionalSteps: [String]
    }

    private func documentRows() -> [String: DocRow] {
        let here = URL(fileURLWithPath: #filePath)
        let registry = here
            .deletingLastPathComponent()   // GruxTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // Grux-Mac, the package root
            .appendingPathComponent("docs/feature-registry.md")

        guard let text = try? String(contentsOf: registry, encoding: .utf8) else {
            XCTFail("""
                Could not read the feature registry at \(registry.path).
                This test is the only thing keeping FeatureRegistry.swift honest,
                so an unreadable document means UNVERIFIED, not a pass. The registry
                ships in this repository at docs/feature-registry.md, so an
                unreadable one means the checkout is incomplete.
                """)
            return [:]
        }

        func ids(_ cell: String) -> [String] {
            let trimmed = cell.trimmingCharacters(in: .whitespaces)
            if trimmed == "none" || trimmed.isEmpty { return [] }
            let re = try! NSRegularExpression(pattern: #"`((?:key|perm|endpoint|step)\.[a-z0-9_]+)`"#)
            let ns = trimmed as NSString
            return re.matches(in: trimmed, range: NSRange(location: 0, length: ns.length))
                .map { ns.substring(with: $0.range(at: 1)) }
        }

        var out: [String: DocRow] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let cells = line.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            // | id | label | tier | requires | optional | steps | optionalSteps |
            guard cells.count >= 8 else { continue }
            let rawId = cells[1]
            guard rawId.hasPrefix("`"), rawId.hasSuffix("`") else { continue }
            let id = String(rawId.dropFirst().dropLast())
            guard cells[3] == "core" || cells[3] == "labs" else { continue }
            guard out[id] == nil else { continue }
            out[id] = DocRow(label: cells[2], tier: cells[3],
                             requires: ids(cells[4]), optional: ids(cells[5]),
                             steps: ids(cells[6]), optionalSteps: ids(cells[7]))
        }
        return out
    }

    func testRowSetsMatchExactly() {
        let doc = documentRows()
        XCTAssertFalse(doc.isEmpty, "parsed zero registry rows, the table shape changed")
        let swiftIds = Set(FeatureRegistry.rows.map(\.id))
        let docIds = Set(doc.keys)
        XCTAssertTrue(docIds.subtracting(swiftIds).isEmpty,
                      "registry rows missing from Swift: \(docIds.subtracting(swiftIds).sorted())")
        XCTAssertTrue(swiftIds.subtracting(docIds).isEmpty,
                      "Swift rows with no registry entry, this is drift: \(swiftIds.subtracting(docIds).sorted())")
        // 39 since CR-31 added `social`, which was a real tab wired to SocialView
        // and capabilityGated("social") with no registry row at all, so its gate
        // no-opped and it could not be marked labs. The literal is deliberate: the
        // set comparisons above catch drift between the two files, and this catches
        // a row added to BOTH without anyone deciding to add it.
        XCTAssertEqual(FeatureRegistry.rows.count, 39)
    }

    func testEveryRowMatchesTheDocument() {
        let doc = documentRows()
        for row in FeatureRegistry.rows {
            guard let d = doc[row.id] else { continue }   // covered above
            XCTAssertEqual(row.label, d.label, "\(row.id) label drifted")
            XCTAssertEqual(row.tier.rawValue, d.tier, "\(row.id) tier drifted")
            XCTAssertEqual(row.requires.map(\.rawValue), d.requires, "\(row.id) requires drifted")
            XCTAssertEqual(row.optional.map(\.rawValue), d.optional, "\(row.id) optional drifted")
            XCTAssertEqual(row.steps.map(\.rawValue), d.steps, "\(row.id) steps drifted")
            XCTAssertEqual(row.optionalSteps.map(\.rawValue), d.optionalSteps, "\(row.id) optionalSteps drifted")
        }
    }

    /// The orphan rule the contract's own checker enforces, mirrored here so it
    /// holds in Swift too: a capability nothing declares is dead weight, and a
    /// capability a row names that does not exist is a typo nobody caught.
    func testEveryReferencedCapabilityIsARealContractId() {
        let known = Set(SetupRequirement.allCases.map(\.rawValue))
        for row in FeatureRegistry.rows {
            for req in row.requires + row.optional + row.steps + row.optionalSteps {
                XCTAssertTrue(known.contains(req.rawValue),
                              "\(row.id) names \(req.rawValue), which is not a contract capability")
            }
        }
    }

    // MARK: State

    /// Only ready and needsSetup are produced today. This pins the collapse so a
    /// later change to `state(of:)` is a deliberate edit and not a surprise.
    func testStateOnlyProducesReadyOrNeedsSetup() {
        for row in FeatureRegistry.rows {
            let s = FeatureRegistry.capabilityState(of: row)
            XCTAssertTrue(s == .ready || s == .needsSetup, "\(row.id) produced \(s.rawValue)")
        }
    }

    /// A feature with no blocking requirements can never sit in needs-setup, or
    /// a fresh install would look broken on tabs that need nothing at all.
    func testFeaturesWithNoBlockingRequirementsAreAlwaysReady() {
        for row in FeatureRegistry.rows where row.blocking.isEmpty {
            XCTAssertEqual(FeatureRegistry.capabilityState(of: row), .ready,
                           "\(row.id) requires nothing yet reported needsSetup")
        }
    }

    func testTabAliasesResolve() {
        XCTAssertEqual(FeatureRegistry.row(forTab: "jaxHQ")?.id, "jax.hq")
        XCTAssertEqual(FeatureRegistry.row(forTab: "metaAds")?.id, "meta.ads")
        XCTAssertEqual(FeatureRegistry.row(forTab: "selfUpgrade")?.id, "self.upgrade")
        // A key that is its own id needs no alias.
        XCTAssertEqual(FeatureRegistry.row(forTab: "mailbox")?.id, "mailbox")
        // An unknown tab must not crash and must not claim needs-setup, because
        // a tab with no registry row has nothing to set up.
        XCTAssertNil(FeatureRegistry.row(forTab: "not-a-tab"))
        XCTAssertEqual(FeatureRegistry.state(forTab: "not-a-tab"), .ready)
    }
}
