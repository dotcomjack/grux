import XCTest
@testable import Grux

/// W64-FIX P1-1 (wave 64 review): the nightly passes (`PersonMemory`,
/// `DecisionLog`) and the rest of the ambient family call
/// `AmbientLLM.completeTagged`, whose fallback took
/// `ModelRegistry.resolvedRouting(provider: nil)`. With chat set to a local
/// model and none running, `resolvedProvider` turns `.local` into `.anthropic`,
/// so the day's transcript went to Anthropic with a stored key at 3 AM while
/// chat itself refuses that state (`ChatReadiness.offlinePinnedButNoLocalModel`)
/// and Settings, Ambient said it stays on this Mac or that nothing is written.
/// The fallback now refuses exactly where chat does.
@MainActor
final class AmbientFallbackRouteTests: XCTestCase {

    private let custom = ActiveProvider.custom(UUID())

    /// Every chosen x routed pair: a local choice is refused only when it fell
    /// back to Anthropic, and nothing else is.
    func testTheFallbackRefusesOnlyALocalChoiceThatFellBack() {
        let all: [ActiveProvider] = [.anthropic, .local, custom]
        for chosen in all {
            for routed in all {
                let refused = AmbientLLM.fallbackRefusal(chosen: chosen, routed: routed) != nil
                XCTAssertEqual(refused, chosen == .local && routed == .anthropic, "chosen \(chosen) routed \(routed)")
            }
        }
    }

    /// The same rule as chat: refused exactly when chat's readiness says the
    /// local choice has no model, with or without an Anthropic key.
    func testTheRuleIsChatsRule() {
        let all: [ActiveProvider] = [.anthropic, .local, custom]
        for chosen in all {
            for routed in all {
                for key in [false, true] {
                    for local in [false, true] {
                        let chat = ChatReadiness.evaluate(hasAnthropicKey: key, localModelAvailable: local,
                                                          chosenProvider: chosen, routedProvider: routed)
                        XCTAssertEqual(AmbientLLM.fallbackRefusal(chosen: chosen, routed: routed) != nil,
                                       chat == .offlinePinnedButNoLocalModel,
                                       "chosen \(chosen) routed \(routed) key \(key) local \(local)")
                    }
                }
            }
        }
    }

    /// W64-FIX round 2 P2-3: dictation correction, the memory extractor,
    /// meeting summaries and the coaches each took `resolvedRouting(provider:
    /// nil)` themselves and reached Anthropic the same way. The route itself
    /// now keeps a local choice local: with chat set to a local model and none
    /// running, the default branch answers as the explicit local branch does
    /// (the local server, whose failure is the caller's error), never Anthropic.
    func testTheDefaultRouteKeepsALocalChoiceLocal() throws {
        let all: [ActiveProvider] = [.anthropic, .local, custom]
        for chosen in all {
            for routed in all {
                XCTAssertEqual(ModelRegistry.localChoiceFellBack(chosen: chosen, routed: routed),
                               AmbientLLM.fallbackRefusal(chosen: chosen, routed: routed) != nil,
                               "one rule: chosen \(chosen) routed \(routed)")
            }
        }
        let src = try String(contentsOfFile: #filePath.replacingOccurrences(
            of: "Tests/GruxTests/AmbientFallbackRouteTests.swift", with: "Sources/Grux/Backend/ModelRegistry.swift"))
        let fn = try XCTUnwrap(src.range(of: "func resolvedRouting(provider: String?, modelOverride: String?)"))
        let body = src[fn.upperBound...].prefix(2400)
        let def = try XCTUnwrap(body.range(of: "default:"))
        let afterDefault = body[def.upperBound...].prefix(800)
        XCTAssertTrue(afterDefault.contains("Self.localChoiceFellBack(chosen: activeProvider, routed: resolvedProvider)"),
                      String(afterDefault))
        XCTAssertTrue(afterDefault.contains("return localRouting(modelOverride: modelOverride)"), String(afterDefault))
        let localCase = try XCTUnwrap(body.range(of: "case \"local\":"))
        XCTAssertTrue(body[localCase.upperBound...].prefix(900).contains("return localRouting(modelOverride: modelOverride)"))
    }

    /// The refusal is checked before the fallback resolves a route, and the
    /// call throws instead of sending.
    func testCompleteTaggedChecksBeforeItRoutes() throws {
        let src = try String(contentsOfFile: #filePath.replacingOccurrences(
            of: "Tests/GruxTests/AmbientFallbackRouteTests.swift", with: "Sources/Grux/LocalLLM.swift"))
        let check = try XCTUnwrap(src.range(of: "fallbackRefusal(chosen: registry.activeProvider, routed: registry.resolvedProvider)"))
        let route = try XCTUnwrap(src.range(of: "registry.resolvedRouting(provider: nil, modelOverride: nil)"))
        XCTAssertLessThan(check.lowerBound, route.lowerBound)
        let between = src[check.upperBound..<route.lowerBound]
        XCTAssertTrue(between.contains("throw AmbientLLMError.localModelNotRunning"), String(between))
    }

    /// The caption says what the refusal means for a local route.
    func testTheCaptionSaysALocalRouteWritesNothingWhileItIsDown() {
        for route in [PrivacyAsk.Route.thisMac(model: "Grux Local 2B"),
                      .otherMachine(model: "Grux Local 2B", host: "mini.local")] {
            for brain in [false, true] {
                let text = NightlyPassCaption.text(brainOn: brain, route: route, claudeKey: false)
                XCTAssertTrue(text.contains("they write nothing while it is not running"), text)
            }
        }
        let cloud = NightlyPassCaption.text(brainOn: false, route: .anthropic, claudeKey: true)
        XCTAssertFalse(cloud.contains("while it is not running"), cloud)
    }
}
