import XCTest
@testable import Grux

/// D34: the Design Studio cost line read "$0.0418 estimated, API key | subscription,
/// $0 metered (" and stopped: the other routes were joined to the chosen one with
/// the same bar, so "API key | subscription" read as one choice, and the line was
/// cut where it met the edge.
final class DesignStudioEstimateLineTests: XCTestCase {

    private func estimate(alternatives: [DesignRouteCost]) -> DesignRunEstimate {
        DesignRunEstimate(
            inputTokens: 1000, maxOutputTokens: 2000,
            primary: DesignRouteCost(route: .api, modelId: "m", estimatedUSD: 0.0418, label: "$0.0418 estimated"),
            alternatives: alternatives)
    }

    func test_theChosenRouteStandsAloneAndTheOthersAreNamedAsSuch() {
        let sub = DesignRouteCost(route: .subscriptionCLI, modelId: "m", estimatedUSD: 0,
                                  label: "subscription, $0 metered (plan quota)")
        let local = DesignRouteCost(route: .localModel, modelId: "m", estimatedUSD: 0,
                                    label: "local or custom endpoint, $0 estimated if local")
        XCTAssertEqual(DesignStudioView.estimateText(estimate(alternatives: [sub, local])),
                       "$0.0418 estimated, \(ExecutionRoute.api.displayName). "
                       + "Other routes: subscription, $0 metered (plan quota); local or custom endpoint, $0 estimated if local")
    }

    func test_withNoOtherRouteTheLineIsTheChosenOneOnly() {
        XCTAssertEqual(DesignStudioView.estimateText(estimate(alternatives: [])),
                       "$0.0418 estimated, \(ExecutionRoute.api.displayName)")
    }

    func test_theLineNeverJoinsRoutesWithABar() {
        let sub = DesignRouteCost(route: .subscriptionCLI, modelId: "m", estimatedUSD: 0, label: "subscription")
        XCTAssertFalse(DesignStudioView.estimateText(estimate(alternatives: [sub])).contains("|"))
    }

    /// The line wraps instead of being cut at the composer's edge.
    func test_theEstimateLineWraps() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf: root.appendingPathComponent("Sources/Grux/DesignStudio/DesignStudioView.swift"),
                             encoding: .utf8)
        let start = try XCTUnwrap(src.range(of: "private var estimateLine: some View {"))
        let body = String(src[start.upperBound...].prefix(600))
        XCTAssertTrue(body.contains(".fixedSize(horizontal: false, vertical: true)"), "the estimate line is cut, not wrapped")
    }
}
