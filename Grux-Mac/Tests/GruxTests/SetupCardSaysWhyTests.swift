import XCTest
@testable import Grux

/// D96 and D100: a setup card names what THIS feature needs, and why.
///
/// The card printed the contract's one sentence per capability on every feature.
/// The Anthropic key's sentence ended "Chat also runs on a local model with no key" (CR-41),
/// which is Chat's story: on Focus log (whose screen reading is pinned to Claude) it
/// promised a stand-in that does not exist and never said why the key is needed, and
/// on Research it sat beside a requirement the engine never had, because deep research
/// routes through `ModelRegistry.resolvedRouting` exactly as Chat does.
@MainActor
final class SetupCardSaysWhyTests: XCTestCase {

    private func row(_ id: String) throws -> FeatureRow {
        try XCTUnwrap(FeatureRegistry.row(id: id), "no registry row \(id)")
    }

    // MARK: - D100, Research runs on a local model

    /// A person with a web search key and a local model has everything deep research
    /// reads: the route serves the model calls with the local placeholder key.
    func testResearchIsReadyWithABraveKeyAndALocalModel() throws {
        let research = try row("research")
        let unmet = FeatureRegistry.unmetBlocking(of: research,
                                                  satisfied: { [.keyBrave, .endpointOllama].contains($0) })
        XCTAssertEqual(unmet, [], "Research asked a local-model user for an Anthropic key it never reads")
    }

    /// The model half is an either-or, and the web search key stays required.
    func testResearchStillNeedsTheWebKeyAndOneModel() throws {
        let research = try row("research")
        XCTAssertEqual(FeatureRegistry.unmetBlocking(of: research, satisfied: { $0 == .keyAnthropic }),
                       [.keyBrave])
        XCTAssertEqual(FeatureRegistry.unmetBlocking(of: research, satisfied: { $0 == .keyBrave }),
                       [.keyAnthropic, .endpointOllama])
        let entries = CapabilitySetupLayout.entries(missing: [.keyAnthropic, .endpointOllama],
                                                    groups: research.anyOf)
        XCTAssertEqual(entries, [.anyOf(needed: 1, requirements: [.keyAnthropic, .endpointOllama])],
                       "the card must read Any 1 of these over the two model paths")
    }

    // MARK: - D96, Focus log says why

    func testFocusCardSaysWhyItNeedsTheKeyAndOffersNoLocalStandIn() {
        let line = CapabilitySetupCard.line(for: .keyAnthropic, featureKey: "focus")
        XCTAssertTrue(line.contains("Focus log"), "the line never says why Focus log needs the key: \(line)")
        XCTAssertFalse(line.localizedCaseInsensitiveContains("local model with no key"),
                       "the line offers a local model Focus log cannot use: \(line)")
    }

    // MARK: - The class

    private func blockingLines() -> [(feature: FeatureRow, requirement: SetupRequirement, line: String)] {
        FeatureRegistry.rows.flatMap { row in
            row.blocking.map { (row, $0, CapabilitySetupCard.line(for: $0, featureKey: row.id)) }
        }
    }

    /// A card never tells a person about a different feature than the one it stands in
    /// for. Read over every row and every blocking item, so a new row inherits it.
    func testNoCardLineNamesAnotherFeature() {
        // Settings is where every card's button goes, not a feature it talks about.
        let labels = Set(FeatureRegistry.rows.map(\.label)).subtracting(["Settings"])
        var checked = 0
        for (feature, requirement, line) in blockingLines() {
            for label in labels where label != feature.label {
                let pattern = "\\b" + NSRegularExpression.escapedPattern(for: label) + "\\b"
                XCTAssertNil(line.range(of: pattern, options: .regularExpression),
                             "\(feature.id) card, \(requirement.rawValue): names \(label): \(line)")
            }
            checked += 1
        }
        XCTAssertGreaterThan(checked, 30, "control: almost no card lines were read")
    }

    /// The contract's own sentences go everywhere a capability is named (Settings, every
    /// `grux` answer, handoff prompts), whichever feature asked, so none may name a feature
    /// beyond the capability's own name (the Calendar permission may say Calendar), the panes
    /// a person is sent to (Settings, Integrations), or the one feature that lists it (the
    /// speech model is Meetings' own step, so "open Meetings" is right).
    func testNoContractSentenceNamesAFeature() {
        let places: Set<String> = ["Settings", "Integrations"]
        for requirement in SetupRequirement.allCases {
            let listers = FeatureRegistry.rows.filter {
                ($0.requires + $0.optional + $0.steps + $0.optionalSteps).contains(requirement)
            }
            let own = listers.count == 1 ? listers[0].label : nil
            for row in FeatureRegistry.rows where !places.contains(row.label)
                && row.label != own && !requirement.label.contains(row.label) {
                let pattern = "\\b" + NSRegularExpression.escapedPattern(for: row.label) + "\\b"
                XCTAssertNil(requirement.remediation.range(of: pattern, options: .regularExpression),
                             "\(requirement.rawValue) names \(row.label): \(requirement.remediation)")
            }
        }
    }

    /// A feature that needs the Anthropic key with no local alternative says why, in
    /// its own name, and offers no local model.
    func testEveryFeatureThatNeedsTheKeyAloneSaysWhy() {
        var checked = 0
        for row in FeatureRegistry.rows where row.requires.contains(.keyAnthropic)
            && !row.anyOf.contains(where: { $0.capabilities.contains(.keyAnthropic) }) {
            let line = CapabilitySetupCard.line(for: .keyAnthropic, featureKey: row.id)
            XCTAssertTrue(line.contains(row.label), "\(row.id) card never says why it needs the key: \(line)")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 0, "control: no feature needs the key alone, so this proves nothing")
    }

    /// The contract's cap on a remediation line holds for a feature's own line too.
    func testEveryCardLineFitsTheContractCap() {
        for (feature, requirement, line) in blockingLines() {
            XCTAssertLessThanOrEqual(line.count, 140, "\(feature.id), \(requirement.rawValue): \(line)")
            XCTAssertFalse(line.isEmpty)
        }
    }

    /// The card reads a sidebar key or a registry id, and the two agree.
    func testTheTabKeyAndTheRegistryIdReadTheSameLine() {
        for (tab, id) in FeatureRegistry.tabAliases {
            for requirement in FeatureRegistry.row(id: id)?.blocking ?? [] {
                XCTAssertEqual(CapabilitySetupCard.line(for: requirement, featureKey: tab),
                               CapabilitySetupCard.line(for: requirement, featureKey: id), "\(tab) \(requirement)")
            }
        }
    }
}
