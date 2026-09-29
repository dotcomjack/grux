import XCTest
@testable import Grux

/// Chat is the face, and the composer footer is the part of it a person looks
/// at most. Measured 2026-09-20 it carried a raw model identifier, a four
/// decimal price, a truncated token count and a second model identifier.
final class ComposerFooterTests: XCTestCase {

    func test_noRawModelIdentifierReachesTheFace() {
        let line = ComposerFooter.line(
            modelDisplayName: ComposerFooter.displayName(id: "llama3.2:3b", registryName: nil),
            estimatedUSD: 0.0294)
        XCTAssertFalse(line.contains("llama3.2:3b"), "line was \(line)")
        XCTAssertFalse(line.contains(":"), "an identifier-shaped token is on the face: \(line)")
    }

    /// The exact identifiers measured on the running app.
    func test_theIdentifiersThatActuallyShippedBecomeNames() {
        XCTAssertEqual(ComposerFooter.displayName(id: "llama3.2:3b", registryName: nil), "Llama3.2")
        XCTAssertEqual(ComposerFooter.displayName(id: "qwen3.5:4b", registryName: nil), "Qwen3.5")
        XCTAssertEqual(ComposerFooter.displayName(id: "anthropic/claude-sonnet-5", registryName: nil),
                       "Sonnet 5")
    }

    func test_theRegistrysOwnNameWinsWhenThereIsOne() {
        XCTAssertEqual(ComposerFooter.displayName(id: "llama3.2:3b", registryName: "Llama 3.2"), "Llama 3.2")
    }

    func test_aFreeSendSaysFreeRatherThanZeroDollars() {
        XCTAssertEqual(ComposerFooter.cost(0), "free")
        XCTAssertTrue(ComposerFooter.line(modelDisplayName: "Llama 3.2", estimatedUSD: 0).contains("free"))
    }

    /// The measured figure from the running app. Four decimal places is
    /// accounting; a person deciding whether to hit send needs a phrase.
    func test_aSubCentSendDoesNotRenderAsFourDecimalPlaces() {
        XCTAssertEqual(ComposerFooter.cost(0.0004), "under a cent")
        let line = ComposerFooter.line(modelDisplayName: "Sonnet", estimatedUSD: 0.0004)
        XCTAssertFalse(line.contains("0.0004"), "line was \(line)")
        XCTAssertFalse(line.contains("$0.00"), "line was \(line)")
    }

    func test_aPricedSendShowsMoneyAsNumeralsWithTheSymbol() {
        XCTAssertEqual(ComposerFooter.cost(0.0294), "about $0.03")
        XCTAssertEqual(ComposerFooter.cost(1.5), "about $1.50")
    }

    func test_noTokenCountReachesTheFace() {
        let line = ComposerFooter.line(modelDisplayName: "Sonnet", estimatedUSD: 0.03)
        XCTAssertFalse(line.lowercased().contains("tok"), "line was \(line)")
    }

    func test_withNoEstimateTheLineIsJustTheModel() {
        XCTAssertEqual(ComposerFooter.line(modelDisplayName: "Sonnet", estimatedUSD: nil), "Sonnet")
    }
}

/// The footer is wired to the plain formatter, and the pieces that used to be
/// on the face are gone from the view itself.
final class ComposerFooterWiringTests: XCTestCase {
    private func chatView() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/ChatView.swift")
        let t = try String(contentsOf: url, encoding: .utf8)
        XCTAssertGreaterThan(t.count, 500, "ChatView did not load")
        return t
    }

    func test_theChipShowsANameNotAnIdentifier() throws {
        let t = try chatView()
        XCTAssertTrue(t.contains("ComposerFooter.displayName(id: activeModelId"),
                      "the model chip is back to rendering a raw identifier")
    }

    func test_theTokenCountAndTheSecondModelIdAreGoneFromTheFooter() throws {
        let t = try chatView()
        XCTAssertFalse(t.contains("in ~\\(kTokens("), "the token count is back on the face")
        XCTAssertFalse(t.contains("cheaper: \\(name)"), "the cheaper nudge names an identifier again")
        XCTAssertFalse(t.contains("String(format: \"$%.4f\""), "four decimal pricing is back on the face")
    }

    func test_theFooterAsksTheSharedFormatterForTheCost() throws {
        let t = try chatView()
        XCTAssertTrue(t.contains("ComposerFooter.cost(usd)"),
                      "the footer formats money itself again")
    }
}
