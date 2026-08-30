import XCTest
@testable import Grux

// Coverage for the pre-run cost meter: canonical rate resolution (exact prefix,
// family fallback, unknown policy, local-is-free), the chars/4 token heuristic,
// the DesignStudio route comparison shape, the calibration median math, and the
// "estimated" label invariant. No network, no disk assumptions.
final class CostMeterTests: XCTestCase {

    // MARK: - ModelRates: exact + prefix resolution

    func test_rates_exactClaudeIds() {
        XCTAssertEqual(ModelRates.rates(forModelID: "claude-fable-5").input, 10.00)
        XCTAssertEqual(ModelRates.rates(forModelID: "claude-fable-5").output, 50.00)
        XCTAssertEqual(ModelRates.rates(forModelID: "claude-opus-4-8").input, 5.00)
        XCTAssertEqual(ModelRates.rates(forModelID: "claude-opus-4-7").input, 15.00)
        XCTAssertEqual(ModelRates.rates(forModelID: "claude-sonnet-4-6").input, 3.00)
        XCTAssertEqual(ModelRates.rates(forModelID: "claude-sonnet-5").input, 3.00)
    }

    func test_rates_haikuIsCorrected_oneAndFive_notPointEight() {
        // The whole point of consolidation: Haiku 4.5 is the published 1.00/5.00,
        // not the stale 0.80/4.00 two of the old tables carried.
        let r = ModelRates.rates(forModelID: "claude-haiku-4-5")
        XCTAssertEqual(r.input, 1.00)
        XCTAssertEqual(r.output, 5.00)
        XCTAssertEqual(r.cacheRead, 0.10)
        XCTAssertEqual(r.cacheWrite, 1.25)
    }

    func test_rates_prefixMatch_datedHaikuId() {
        // The dated production id must resolve to the Haiku 4.5 row via prefix.
        let dated = ModelRates.rates(forModelID: "claude-haiku-4-5-20251001")
        XCTAssertEqual(dated.input, 1.00)
        XCTAssertEqual(dated.output, 5.00)
    }

    func test_rates_mostSpecificPrefixWins_opus48NotFamily() {
        // claude-opus-4-8 (5/25) must beat the bare "opus" family fallback (15/75).
        XCTAssertEqual(ModelRates.rates(forModelID: "claude-opus-4-8").input, 5.00)
        XCTAssertEqual(ModelRates.rates(forModelID: "claude-opus-4-8").output, 25.00)
    }

    func test_rates_familyFallback_bySubstring() {
        // An id the exact ladder misses still lands on the right family.
        XCTAssertEqual(ModelRates.rates(forModelID: "claude-opus-9-9").input, 15.00)
        XCTAssertEqual(ModelRates.rates(forModelID: "anthropic/claude-3.5-sonnet").input, 3.00)
    }

    func test_rates_providerPrefixStripped() {
        XCTAssertEqual(ModelRates.rates(forModelID: "anthropic/claude-opus-4-8").input, 5.00)
    }

    // MARK: - ModelRates: local + unknown policy

    func test_rates_localModelsAreZero() {
        for id in ["qwen3:8b", "llama3.1:latest", "gemma2", "ollama/mistral", "codellama:13b"] {
            XCTAssertTrue(ModelRates.rates(forModelID: id).isZero, "\(id) should price at zero")
            XCTAssertTrue(ModelRates.knownRates(forModelID: id)?.isZero == true, "\(id) is a known-free model")
        }
    }

    func test_rates_unknownPaidModel_fallsBackToCheapestKnown() {
        // Unknown non-local id: cheapest known paid rate, so it can never inflate.
        let r = ModelRates.rates(forModelID: "some-mystery-model-x")
        XCTAssertEqual(r, ModelRates.cheapestPaid)
        // knownRates draws the distinction: genuinely unknown returns nil.
        XCTAssertNil(ModelRates.knownRates(forModelID: "some-mystery-model-x"))
    }

    func test_estimatedUSD_math() {
        // 1M input + 1M output on Haiku (1/5) = $1 + $5 = $6.
        let usd = ModelRates.estimatedUSD(
            inputTokens: 1_000_000, outputTokens: 1_000_000,
            cacheReadTokens: 0, cacheCreationTokens: 0, modelID: "claude-haiku-4-5")
        XCTAssertEqual(usd, 6.0, accuracy: 1e-9)
    }

    // MARK: - TokenEstimator: chars/4

    func test_tokenEstimator_charsOverFour_roundsUp() {
        XCTAssertEqual(TokenEstimator.estimateTokens(chars: 0), 0)
        XCTAssertEqual(TokenEstimator.estimateTokens(chars: 4), 1)
        XCTAssertEqual(TokenEstimator.estimateTokens(chars: 5), 2)   // 1.25 -> 2
        XCTAssertEqual(TokenEstimator.estimateTokens(chars: 400), 100)
        XCTAssertEqual(TokenEstimator.estimateTokens(text: "abcdefgh"), 2)
    }

    func test_tokenEstimator_inputTokens_countsBlocksMessagesTools() {
        let systemBlocks: [[String: Any]] = [["type": "text", "text": String(repeating: "a", count: 400)]]
        let messages: [[String: Any]] = [["role": "user", "content": String(repeating: "b", count: 400)]]
        let tools = [ClaudeTool(name: "t", description: "d", inputSchema: ["type": "object"])]
        let n = TokenEstimator.estimateInputTokens(systemBlocks: systemBlocks, messages: messages, tools: tools)
        // Well over the ~200 tokens from the two 400-char payloads alone; the
        // point is it counts all three surfaces and returns a positive ceiling.
        XCTAssertGreaterThan(n, 100)
    }

    func test_tokenEstimator_skipsBase64ImagePayload() {
        let bigImage = String(repeating: "Z", count: 100_000)
        let withImage: [[String: Any]] = [[
            "role": "user",
            "content": [["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": bigImage]]]
        ]]
        let n = TokenEstimator.estimateInputTokens(systemBlocks: [], messages: withImage, tools: [])
        // A 100k-char base64 blob must NOT become 25k tokens; images are skipped.
        XCTAssertLessThan(n, 50)
    }

    // MARK: - CostMeter.estimate

    // Count non-overlapping occurrences of a substring, for the single-occurrence
    // label invariant a sibling view depends on.
    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    func test_estimate_labelAlwaysContainsEstimated() {
        let paid = CostMeter.estimate(inputTokens: 8000, maxOutputTokens: 2000,
                                      modelId: "claude-opus-4-8", provider: "anthropic")
        // Invariant: the primary label carries "estimated" EXACTLY once.
        XCTAssertEqual(occurrences(of: "estimated", in: paid.label), 1, "paid label: \(paid.label)")
        XCTAssertNotNil(paid.estimatedUSD)
        XCTAssertGreaterThan(paid.estimatedUSD ?? 0, 0)

        let free = CostMeter.estimate(inputTokens: 8000, maxOutputTokens: 2000,
                                      modelId: "qwen3:8b", provider: "local")
        XCTAssertEqual(occurrences(of: "estimated", in: free.label), 1, "free label: \(free.label)")
        XCTAssertEqual(free.estimatedUSD, 0)
    }

    func test_estimate_cheaperAlternative_haikuForPricierModel() {
        let est = CostMeter.estimate(inputTokens: 8000, maxOutputTokens: 2000,
                                     modelId: "claude-opus-4-8", provider: "anthropic")
        XCTAssertEqual(est.cheaperAlternative?.modelId, "claude-haiku-4-5")
        XCTAssertNotNil(est.cheaperAlternative)
    }

    func test_estimate_cheaperAlternative_localBeatsHaiku() {
        let est = CostMeter.estimate(inputTokens: 8000, maxOutputTokens: 2000,
                                     modelId: "claude-opus-4-8", provider: "anthropic",
                                     discoveredLocalModel: "llama3.1")
        XCTAssertEqual(est.cheaperAlternative?.modelId, "llama3.1")
        XCTAssertEqual(est.cheaperAlternative?.estimatedUSD, 0)
    }

    func test_estimate_haikuHasNoCheaperAlternative() {
        // Already the cheapest paid model, and no local discovered: no alt.
        let est = CostMeter.estimate(inputTokens: 8000, maxOutputTokens: 2000,
                                     modelId: "claude-haiku-4-5", provider: "anthropic")
        XCTAssertNil(est.cheaperAlternative)
    }

    func test_estimate_calibrationFactorScalesInput() {
        let base = CostMeter.estimate(inputTokens: 10_000, maxOutputTokens: 0,
                                      modelId: "claude-haiku-4-5", provider: "anthropic",
                                      calibrationFactor: 1.0)
        let doubled = CostMeter.estimate(inputTokens: 10_000, maxOutputTokens: 0,
                                         modelId: "claude-haiku-4-5", provider: "anthropic",
                                         calibrationFactor: 2.0)
        XCTAssertEqual(doubled.inputTokens, base.inputTokens * 2)
        XCTAssertEqual((doubled.estimatedUSD ?? 0), (base.estimatedUSD ?? 0) * 2, accuracy: 1e-9)
    }

    // MARK: - Route comparison

    func test_routeComparison_shape() {
        let routes = CostMeter.routeComparison(inputTokens: 8000, maxOutputTokens: 2000,
                                               modelId: "claude-opus-4-8")
        XCTAssertEqual(routes.count, 3)
        XCTAssertEqual(routes.map { $0.route }, [.api, .subscriptionCLI, .localModel])
        // API is metered and non-zero for a paid model.
        XCTAssertGreaterThan(routes[0].estimatedUSD ?? 0, 0)
        // Subscription and local are both free.
        XCTAssertEqual(routes[1].estimatedUSD, 0)
        XCTAssertEqual(routes[2].estimatedUSD, 0)
        // API + local carry "estimated" exactly once (single-occurrence invariant).
        XCTAssertEqual(occurrences(of: "estimated", in: routes[0].label), 1, "api label: \(routes[0].label)")
        XCTAssertEqual(occurrences(of: "estimated", in: routes[2].label), 1, "local label: \(routes[2].label)")
        // The local label no longer claims an unconditional "free": a custom
        // endpoint (OpenRouter) on this route is metered, so it names that.
        XCTAssertTrue(routes[2].label.contains("custom endpoint"), "local label: \(routes[2].label)")
        XCTAssertFalse(routes[2].label.contains("free"), "local label must not claim free: \(routes[2].label)")
        // Subscription reads as metered against plan quota, NOT "estimated"
        // (which implied a free run); no "estimated" token on this label.
        XCTAssertTrue(routes[1].label.contains("metered"), "subscription label: \(routes[1].label)")
        XCTAssertTrue(routes[1].label.contains("plan quota"), "subscription label: \(routes[1].label)")
        XCTAssertEqual(occurrences(of: "estimated", in: routes[1].label), 0, "subscription label: \(routes[1].label)")
    }

    // MARK: - Critique cost folding (route-aware review honesty)

    func test_critiqueEstimatedUSD_zeroWithoutKey_positiveWithKey() {
        // No key: the gate is skipped, so there is no review cost to price.
        XCTAssertEqual(CostMeter.critiqueEstimatedUSD(generatedOutputTokens: 8000, hasAnthropicKey: false), 0)
        // Key present: the review is real API dollars.
        let withKey = CostMeter.critiqueEstimatedUSD(generatedOutputTokens: 8000, hasAnthropicKey: true)
        XCTAssertGreaterThan(withKey, 0)
        // A bigger generated artifact costs more to review (more HTML to read)...
        let bigger = CostMeter.critiqueEstimatedUSD(generatedOutputTokens: 14000, hasAnthropicKey: true)
        XCTAssertGreaterThan(bigger, withKey)
        // ...but the cached fan-out plus short verdicts keep it a sane sub-dollar figure.
        XCTAssertLessThan(bigger, 1.0)
    }

    func test_routeComparison_foldsCritiqueCostIntoEveryRoute() {
        let review = 0.05  // a real API review cost (key present)
        let routes = CostMeter.routeComparison(inputTokens: 8000, maxOutputTokens: 2000,
                                               modelId: "claude-opus-4-8", critiqueUSD: review)
        let api = routes[0], sub = routes[1], local = routes[2]
        // API: generation PLUS review, still exactly one "estimated".
        XCTAssertGreaterThan(api.estimatedUSD ?? 0, review)
        XCTAssertEqual(occurrences(of: "estimated", in: api.label), 1, "api: \(api.label)")
        // The formerly-"$0 free" routes now surface the real review dollars.
        XCTAssertEqual(sub.estimatedUSD ?? -1, review, accuracy: 1e-9)
        XCTAssertEqual(local.estimatedUSD ?? -1, review, accuracy: 1e-9)
        XCTAssertTrue(sub.label.contains("review"), "subscription: \(sub.label)")
        XCTAssertTrue(local.label.contains("review"), "local: \(local.label)")
        // Single-occurrence invariant holds on the review-bearing labels too.
        XCTAssertEqual(occurrences(of: "estimated", in: sub.label), 1, "subscription: \(sub.label)")
        XCTAssertEqual(occurrences(of: "estimated", in: local.label), 1, "local: \(local.label)")
    }

    func test_routeComparison_localLabelHonestAboutCustomEndpoint() {
        // No critique cost: the local label must still stop overstating "free"
        // because a paid custom endpoint (OpenRouter) can ride this route.
        let routes = CostMeter.routeComparison(inputTokens: 8000, maxOutputTokens: 2000,
                                               modelId: "claude-opus-4-8")
        let local = routes[2]
        XCTAssertTrue(local.label.contains("custom endpoint"), local.label)
        XCTAssertFalse(local.label.contains("free"), local.label)
        XCTAssertEqual(occurrences(of: "estimated", in: local.label), 1, local.label)
    }

    // MARK: - Calibration: raw recording + convergence (feedback-loop fix)

    func test_estimate_recordsRawInputTokens_notCalibrated() {
        let raw = 10_000
        let e1 = CostMeter.estimate(inputTokens: raw, maxOutputTokens: 0,
                                    modelId: "claude-haiku-4-5", provider: "anthropic",
                                    calibrationFactor: 1.0)
        let e3 = CostMeter.estimate(inputTokens: raw, maxOutputTokens: 0,
                                    modelId: "claude-haiku-4-5", provider: "anthropic",
                                    calibrationFactor: 3.0)
        // The calibrated (priced) input scales with the factor...
        XCTAssertEqual(e1.inputTokens, raw)
        XCTAssertEqual(e3.inputTokens, raw * 3)
        // ...but the RAW input recorded for calibration never does. Recording the
        // calibrated value was the feedback loop that made the factor converge to
        // sqrt(true) and permanently understate cost.
        XCTAssertEqual(e1.rawInputTokens, raw)
        XCTAssertEqual(e3.rawInputTokens, raw)
    }

    func test_calibration_convergesToTrueRatio_notSqrt() {
        // The wire actually charges 2.25x the raw chars/4 estimate.
        let raw = 8_000
        let trueRatio = 2.25
        let actual = Int((Double(raw) * trueRatio).rounded())

        // Simulate the reconciliation loop the way recordActual now stores it: each
        // row pairs the RAW estimate (est.rawInputTokens) with the real actual,
        // independent of the factor in force. From any start the median pins on the
        // true ratio in one step and stays there (a stable fixed point).
        var factor = 1.0
        for _ in 0..<5 {
            let est = CostMeter.estimate(inputTokens: raw, maxOutputTokens: 0,
                                         modelId: "claude-haiku-4-5", provider: "anthropic",
                                         calibrationFactor: factor)
            let row = CalibrationRow(estimatedTokens: est.rawInputTokens, actualTokens: actual, date: Date())
            factor = CostMeter.medianFactor(rows: [row])
        }
        XCTAssertEqual(factor, trueRatio, accuracy: 0.02, "raw recording converges to the true ratio")
        // The old post-calibration bug converged to sqrt(2.25) = 1.5; assert we are
        // clearly above that biased fixed point.
        XCTAssertGreaterThan(factor, 2.0, "not the sqrt-biased factor the old loop produced")

        // And the priced input at the converged factor equals the true prompt size.
        let priced = CostMeter.estimate(inputTokens: raw, maxOutputTokens: 0,
                                        modelId: "claude-haiku-4-5", provider: "anthropic",
                                        calibrationFactor: factor)
        XCTAssertEqual(Double(priced.inputTokens), Double(actual), accuracy: Double(actual) * 0.02)
    }

    // MARK: - Calibration median

    func test_calibrationFactor_defaultsToOne_whenEmpty() {
        XCTAssertEqual(CostMeter.medianFactor(rows: []), 1.0)
    }

    func test_calibrationFactor_ignoresZeroEstimateRows() {
        let rows = [CalibrationRow(estimatedTokens: 0, actualTokens: 500, date: Date())]
        XCTAssertEqual(CostMeter.medianFactor(rows: rows), 1.0)
    }

    func test_calibrationFactor_oddCount_isMiddleValue() {
        // factors: 1.0, 2.0, 3.0 -> median 2.0
        let rows = [
            CalibrationRow(estimatedTokens: 100, actualTokens: 100, date: Date()),
            CalibrationRow(estimatedTokens: 100, actualTokens: 200, date: Date()),
            CalibrationRow(estimatedTokens: 100, actualTokens: 300, date: Date())
        ]
        XCTAssertEqual(CostMeter.medianFactor(rows: rows), 2.0, accuracy: 1e-9)
    }

    func test_calibrationFactor_evenCount_isMeanOfMiddleTwo() {
        // factors: 1.0, 2.0, 3.0, 4.0 -> median (2.0 + 3.0)/2 = 2.5
        let rows = [
            CalibrationRow(estimatedTokens: 100, actualTokens: 100, date: Date()),
            CalibrationRow(estimatedTokens: 100, actualTokens: 200, date: Date()),
            CalibrationRow(estimatedTokens: 100, actualTokens: 300, date: Date()),
            CalibrationRow(estimatedTokens: 100, actualTokens: 400, date: Date())
        ]
        XCTAssertEqual(CostMeter.medianFactor(rows: rows), 2.5, accuracy: 1e-9)
    }
}
