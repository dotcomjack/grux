import XCTest
@testable import Grux

/// W57-FIX 3: first run's Connect your accounts had one paste field for Notion
/// and said "connected" the moment the secret was saved, while Notion writes
/// only with its database too (`NotionClient.isConnected`) and every other
/// screen (Credentials, the setup cards, the agent handoff) says it is not set
/// up. A credential with a second half is connected only when the resolver
/// says so, and the row asks for the second half.
@MainActor
final class FirstRunPairedCredentialTests: XCTestCase {

    func testASavedKeyWithASecondHalfIsNotConnectedUntilTheResolverAgrees() {
        // Every combination of: saved on this screen, resolver satisfied, has a second half.
        for savedHere in [false, true] {
            for satisfied in [false, true] {
                for hasCompanion in [false, true] {
                    let expected = satisfied || (savedHere && !hasCompanion)
                    XCTAssertEqual(OnboardingModel.connectionDone(savedHere: savedHere, satisfied: satisfied,
                                                                  hasCompanion: hasCompanion),
                                   expected, "saved \(savedHere) satisfied \(satisfied) companion \(hasCompanion)")
                }
            }
        }
    }

    func testNotionOnFirstRunHasItsSecondHalf() {
        XCTAssertTrue(OnboardingModel.connectionOrder.contains(.keyNotion))
        XCTAssertNotNil(CapabilityResolver.companion(for: .keyNotion))
    }

    /// The screen uses the rule and draws the second field.
    func testTheConnectionsRowUsesTheRuleAndDrawsTheSecondField() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Grux/Onboarding/OnboardingSteps.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let step = try XCTUnwrap(source.range(of: "struct ConnectionsStep: View {"))
        let end = try XCTUnwrap(source.range(of: "// MARK: - The update phase", range: step.upperBound..<source.endIndex))
        let body = String(source[step.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("OnboardingModel.connectionDone("), "the row decides connected some other way")
        XCTAssertFalse(body.contains("saved.contains(req.rawValue) || CapabilityResolver.isSatisfied(req)"))
        XCTAssertTrue(body.contains("CapabilityResolver.companion(for: req)"), "the row has no field for the second half")
        XCTAssertTrue(body.contains("companion.save("), "the second field does not save through the companion")
    }
}
