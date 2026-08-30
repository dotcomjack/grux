import Foundation
import Combine

// TRUE COST BEFORE RUN. The pre-run estimator: given the fully assembled turn
// context, it prices what the send WOULD cost at API rates before a single
// token is spent, names a cheaper route (Haiku, or a discovered local model
// that is free), and reconciles its estimate against the real usage that comes
// back so the heuristic self-calibrates over time.
//
// Every dollar figure it produces is an ESTIMATE and every user-facing string
// carries the word "estimated" (or "est"), because (a) the chars/4 token count
// is approximate and (b) the Foundry/subscription runs are never billed.
@MainActor
final class CostMeter: ObservableObject {
    static let shared = CostMeter()

    // The live pre-run estimate for the next chat send. ChatView renders the
    // cost line under the composer from this; ChatService publishes it right
    // before the hop loop starts.
    @Published var chatEstimate: ChatRunEstimate?

    private init() {}

    // MARK: - Publish (chat pre-send)

    // Called by ChatService.send() once, right before the hop loop, with the
    // exact system blocks / messages / tools the wire will carry. Reads the
    // discovered local model and the calibration factor on the MainActor, then
    // hands plain values to the pure static core.
    func publishChatEstimate(systemBlocks: [[String: Any]],
                             messages: [[String: Any]],
                             tools: [ClaudeTool],
                             modelId: String,
                             provider: String,
                             maxOutputTokens: Int) {
        let inputTokens = TokenEstimator.estimateInputTokens(
            systemBlocks: systemBlocks, messages: messages, tools: tools)
        // The base URL the turn's non-Anthropic route actually points at, asked
        // of the registry that resolved the route.
        //
        // This line used to read `AppState.shared.config.ollamaBaseURL`, on the
        // stated ground that ModelRegistry builds every local-side backend from
        // that one setting. That was true, and then it was not: an explicit
        // `.custom(id)` selection builds its backend AND its key from the saved
        // endpoint's own base URL, while the config field stayed an unrelated
        // free-text box the health poller and the cookbook also read. Press Use
        // on a hosted endpoint, then set that box back to http://localhost:11434,
        // and every turn bills the hosted endpoint while this line called it
        // local, `rates()` returned zero, and the composer printed "$0 estimated
        // (local, free)" on a billed send. That is precisely the failure
        // ModelRates.RateSource exists to close, reopened one text field over.
        //
        // The preset pin rides along because the provider TAG alone cannot tell
        // the two "local" routes apart; `routedBaseURL(provider:)` says why. It
        // is read from the same store, on the same MainActor tick, that
        // ChatService read to build this turn, so the estimate cannot resolve a
        // different pin than the send did.
        let pin = PresetStore.shared.activeChatApplication()?.providerOverride
        let source = Self.rateSource(forProvider: provider,
                                     localBaseURL: ModelRegistry.shared.routedBaseURL(provider: pin))
        // The "cheaper alternative costs $0" claim needs the same evidence the
        // estimate does. A discovered backend sitting at a HOSTED base URL is a
        // paid route wearing the local label, so offering it at $0 would be the
        // same wrong answer one line further down the same view.
        //
        // The DISCOVERY field, not the routed URL, is the right evidence here,
        // and the difference is not cosmetic. `ModelRegistry.local` is discovered
        // against `config.ollamaBaseURL` and against nothing else, so that field
        // is what says whether the free model being offered is real. It is also
        // the only field that can be right on an Anthropic turn, where naming the
        // local server the user already runs is the entire point of the offer.
        let discoveredBase = AppState.shared.config.ollamaBaseURL
        let localModel: String? = (ModelRegistry.shared.local != nil && ModelRates.isLocalBaseURL(discoveredBase))
            ? (ModelRegistry.shared.localTags.first ?? AppState.shared.config.offlineLLMModel)
            : nil
        chatEstimate = Self.estimate(
            inputTokens: inputTokens,
            maxOutputTokens: maxOutputTokens,
            modelId: modelId,
            provider: provider,
            source: source,
            discoveredLocalModel: localModel,
            calibrationFactor: calibrationFactor())
    }

    // Map the turn's provider tag plus the local base URL onto a RateSource.
    //
    // THE PROVIDER TAG ALONE IS NOT ENOUGH, and that is the other half of the
    // model-id bug documented in ModelRates.RateSource. ChatService tags a turn
    // "local" whenever ModelRegistry is offlineReady, and offlineReady only means
    // that some OpenAI-compatible server answered at ollamaBaseURL. Point that
    // setting at OpenRouter, which the endpoints pane in Settings suggests by name
    // and by URL, and every billed turn was tagged "local" and short-circuited to
    // $0 before the rate table was consulted at all. So the URL decides, and the
    // tag only says which URL to read.
    //
    // localBaseURL nil means the caller cannot see the route. That branch keeps
    // the pre-provenance assumption (a "local" tag taken at its word) and exists
    // only for call sites that predate this parameter. The live chat path above
    // asks ModelRegistry.routedBaseURL, which answers nil only for an Anthropic
    // route, and an Anthropic route is tagged "anthropic" and never reaches this
    // branch.
    nonisolated static func rateSource(forProvider provider: String,
                                       localBaseURL: String?) -> ModelRates.RateSource {
        switch provider {
        case "local":
            guard let base = localBaseURL else { return .local }
            return ModelRates.isLocalBaseURL(base) ? .local : .hostedCompat(baseURL: base)
        default:
            return .anthropic
        }
    }

    // MARK: - Pure estimate core

    // The pricing brain, side-effect free and MainActor-independent so tests
    // and the Design Studio can call it directly. Applies the calibration
    // factor to the input-token estimate, prices it at the canonical rate,
    // labels it (always "estimated"), and attaches the cheaper alternative.
    nonisolated static func estimate(inputTokens: Int,
                                     maxOutputTokens: Int,
                                     modelId: String,
                                     provider: String,
                                     source: ModelRates.RateSource? = nil,
                                     discoveredLocalModel: String? = nil,
                                     calibrationFactor: Double = 1.0) -> ChatRunEstimate {
        let factor = max(0.1, calibrationFactor)
        let calibratedInput = Int((Double(inputTokens) * factor).rounded())

        // Provenance decides whether this run is free. `source` nil means the
        // caller could not name the route, so it is derived from the provider tag
        // exactly as the app did before this parameter existed.
        let resolvedSource = source ?? rateSource(forProvider: provider, localBaseURL: nil)
        let rates = ModelRates.rates(forModelID: modelId, source: resolvedSource)

        // A run is free when it rides the subscription CLI (billed against plan
        // quota, never dollars) or when the resolved route prices at zero, which
        // only .local ever does. Note what is NOT in this test any more: a bare
        // `provider == "local"` tag, and the model id's own spelling. Both said
        // free about turns an aggregator was billing.
        let isFree = provider == "subscriptionCLI" || rates.isZero

        let usd: Double
        let label: String
        if isFree {
            usd = 0
            let reason = provider == "subscriptionCLI" ? "subscription" : "local, free"
            label = "$0 estimated (\(reason))"
        } else {
            usd = ModelRates.estimatedUSD(
                inputTokens: calibratedInput, outputTokens: maxOutputTokens,
                cacheReadTokens: 0, cacheCreationTokens: 0, rates: rates)
            label = usdLabel(usd)
        }

        // Cheaper alternative: a discovered local model is free; otherwise
        // Haiku, but only when the current model is actually pricier than Haiku.
        var alt: CheaperAlternative? = nil
        if !isFree {
            if let local = discoveredLocalModel {
                alt = CheaperAlternative(modelId: local, estimatedUSD: 0)
            } else if rates.input > ModelRates.cheapestPaid.input {
                let haikuUSD = ModelRates.estimatedUSD(
                    inputTokens: calibratedInput, outputTokens: maxOutputTokens,
                    cacheReadTokens: 0, cacheCreationTokens: 0, modelID: haikuModelId)
                alt = CheaperAlternative(modelId: haikuModelId, estimatedUSD: haikuUSD)
            }
        }

        return ChatRunEstimate(
            inputTokens: calibratedInput,
            rawInputTokens: max(0, inputTokens),
            maxOutputTokens: maxOutputTokens,
            estimatedUSD: usd,
            modelId: modelId,
            provider: provider,
            cheaperAlternative: alt,
            label: label)
    }

    // Design-Studio-facing route comparison: price the SAME run three ways so
    // the picker can show metered API vs the Claude Code subscription (plan
    // quota) vs a free-if-local model. `critiqueUSD` is the estimated cost of the
    // post-generation CritiqueGate review, which runs on the Anthropic API no
    // matter which route generated the design (0 when it is skipped for lack of a
    // key). It is folded into EVERY route so the "free" routes stop reading $0
    // while a real review is billed against the API key. Feeds DesignRouteCost
    // straight into DesignRunEstimate.
    //
    // Label invariant the studio view relies on: each label carries the word
    // "estimated" at most once (the subscription no-review label carries it zero
    // times, since a plan run is billed against quota rather than estimated).
    nonisolated static func routeComparison(inputTokens: Int,
                                            maxOutputTokens: Int,
                                            modelId: String,
                                            critiqueUSD: Double = 0) -> [DesignRouteCost] {
        let genAPIUSD = ModelRates.estimatedUSD(
            inputTokens: inputTokens, outputTokens: maxOutputTokens,
            cacheReadTokens: 0, cacheCreationTokens: 0, modelID: modelId)
        let review = max(0, critiqueUSD)
        let hasReview = review > 0

        // API route: generation AND the review are both metered on the API.
        let apiUSD = genAPIUSD + review
        let apiLabel = hasReview ? "\(usdLabel(apiUSD)) (gen + review)" : usdLabel(apiUSD)

        // Subscription route: generation rides the plan quota, so its only real
        // out-of-pocket dollars are the API review. Without a review it stays
        // "metered (plan quota)", not "estimated" (a plan run is billed, not free).
        let subLabel = hasReview
            ? "subscription gen on plan quota, review \(usdLabel(review))"
            : "subscription, $0 metered (plan quota)"

        // Local route: $0 if genuinely local, but a custom endpoint (OpenRouter)
        // on this route IS metered, so never claim "free" unconditionally. The
        // API review still costs real dollars whenever a key is present.
        let localLabel = hasReview
            ? "local gen (or custom endpoint), review \(usdLabel(review))"
            : "local or custom endpoint, $0 estimated if local"

        return [
            DesignRouteCost(route: .api, modelId: modelId,
                            estimatedUSD: apiUSD, label: apiLabel),
            DesignRouteCost(route: .subscriptionCLI, modelId: modelId,
                            estimatedUSD: review, label: subLabel),
            DesignRouteCost(route: .localModel, modelId: modelId,
                            estimatedUSD: review, label: localLabel)
        ]
    }

    // MARK: - Critique cost

    // The post-generation CritiqueGate review runs on the Anthropic API (Sonnet)
    // no matter which route generated the design, and only when an API key is
    // present (without one the gate is skipped). Pricing it lets the "free"
    // routes surface the real review dollars instead of reading $0. The generated
    // HTML is approximated by the run's output budget, clamped to the gate's own
    // html cap; the first review dimension warms that payload into the prompt
    // cache and the rest read it cheaply (the gate's warm-then-fan-out pattern).
    nonisolated static func critiqueEstimatedUSD(generatedOutputTokens: Int,
                                                 hasAnthropicKey: Bool) -> Double {
        guard hasAnthropicKey else { return 0 }
        let htmlTokens = min(max(0, generatedOutputTokens), critiqueHTMLCapTokens)
        let sharedInput = htmlTokens + critiqueFramingTokens
        let model = CritiqueGate.critiqueModel
        let reviewers = max(1, CritiqueGate.dimensions.count)
        // Reviewer 1 writes the shared payload into cache; reviewers 2..N read it.
        let warm = ModelRates.estimatedUSD(
            inputTokens: critiquePerDimInputTokens, outputTokens: critiquePerDimOutputTokens,
            cacheReadTokens: 0, cacheCreationTokens: sharedInput, modelID: model)
        let readOne = ModelRates.estimatedUSD(
            inputTokens: critiquePerDimInputTokens, outputTokens: critiquePerDimOutputTokens,
            cacheReadTokens: sharedInput, cacheCreationTokens: 0, modelID: model)
        return warm + Double(reviewers - 1) * readOne
    }

    // Critique cost-model constants. CritiqueGate reviews the generated HTML
    // across its dimensions on Sonnet, sharing one cached copy of the payload.
    private static let critiqueHTMLCapTokens = 15_000    // CritiqueGate.htmlCap (60k chars) / 4
    private static let critiqueFramingTokens = 800       // reviewer framing + copy-law reference
    private static let critiquePerDimInputTokens = 140   // per-dimension tail + user message
    private static let critiquePerDimOutputTokens = 400  // a short verdict (the gate's cap is 1800)

    // Canonical primary dollar label. $N numerals, carries the amount and the
    // word "estimated" EXACTLY ONCE (a sibling view renders this label verbatim
    // and depends on the single occurrence), 4 dp for sub-cent chat sends and
    // 2 dp once a figure clears a dollar.
    nonisolated static func usdLabel(_ usd: Double) -> String {
        let clamped = max(0, usd)
        let amount = clamped >= 1
            ? String(format: "$%.2f", clamped)
            : String(format: "$%.4f", clamped)
        return "\(amount) estimated"
    }

    // The Haiku id used for the cheaper-alternative pricing; a prefix the rate
    // table resolves to the Haiku 4.5 row.
    nonisolated static let haikuModelId = "claude-haiku-4-5"

    // MARK: - Reconciliation / calibration

    // Fold one hop's real usage back against the estimate we published pre-send,
    // so calibrationFactor() can correct the chars/4 heuristic over time. The
    // wire splits the prompt into fresh input + cache-read + cache-create; their
    // sum is the whole prompt the estimate tried to predict.
    func recordActual(inputTokens: Int,
                      outputTokens: Int,
                      cacheReadTokens: Int,
                      cacheCreationTokens: Int,
                      modelId: String) {
        guard let est = chatEstimate, est.rawInputTokens > 0 else { return }
        let actualPrompt = inputTokens + cacheReadTokens + cacheCreationTokens
        guard actualPrompt > 0 else { return }
        var rows = Self.loadCalibration()
        // Store the RAW (pre-calibration) estimate, NOT est.inputTokens (which the
        // in-force factor already multiplied). Recording the calibrated value fed
        // the factor back into its own measurement, so medianFactor converged to
        // sqrt(true error) and left every dollar figure permanently understated.
        rows.append(CalibrationRow(
            estimatedTokens: est.rawInputTokens, actualTokens: actualPrompt, date: Date()))
        if rows.count > Self.calibrationCap {
            rows = Array(rows.suffix(Self.calibrationCap))
        }
        Self.saveCalibration(rows)
    }

    // Median of actual/estimated across the calibration log. Defaults to 1.0
    // with no history so a fresh install prices straight off the heuristic.
    func calibrationFactor() -> Double {
        Self.medianFactor(rows: Self.loadCalibration())
    }

    // Pure median math, exposed static so the arithmetic is unit-testable
    // without touching disk.
    nonisolated static func medianFactor(rows: [CalibrationRow]) -> Double {
        let factors = rows
            .filter { $0.estimatedTokens > 0 }
            .map { Double($0.actualTokens) / Double($0.estimatedTokens) }
            .sorted()
        guard !factors.isEmpty else { return 1.0 }
        let mid = factors.count / 2
        if factors.count % 2 == 0 {
            return (factors[mid - 1] + factors[mid]) / 2.0
        }
        return factors[mid]
    }

    // MARK: - Calibration persistence

    static let calibrationCap = 500
    // v2 filename bump: the pre-fix log stored post-calibration estimates, which
    // poisoned medianFactor. Reading a fresh file drops those rows so the factor
    // relearns off raw estimates instead of inheriting the sqrt-biased history.
    nonisolated static var calibrationURL: URL {
        Persistence.supportDir.appendingPathComponent("cost-meter-calibration-v2.json")
    }

    nonisolated static func loadCalibration() -> [CalibrationRow] {
        guard let data = try? Data(contentsOf: calibrationURL) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([CalibrationRow].self, from: data)) ?? []
    }

    nonisolated static func saveCalibration(_ rows: [CalibrationRow]) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(rows) else { return }
        Persistence.write(data, to: calibrationURL)
    }
}

// MARK: - Value types

// A pre-run chat cost estimate. All figures are estimates; `label` always
// contains the word "estimated".
struct ChatRunEstimate: Codable, Equatable, Sendable {
    // The calibrated input-token count used to PRICE the run (rawInputTokens times
    // the in-force calibration factor).
    let inputTokens: Int
    // The RAW, un-calibrated input estimate (chars/4). Recorded against real usage
    // so the calibration factor measures actual/raw and cannot chase its own tail.
    let rawInputTokens: Int
    let maxOutputTokens: Int
    let estimatedUSD: Double?
    let modelId: String
    let provider: String
    let cheaperAlternative: CheaperAlternative?
    let label: String
}

// The cheaper way to run the same turn: a lower-cost model (Haiku) or a
// discovered local model at $0.
struct CheaperAlternative: Codable, Equatable, Sendable {
    let modelId: String
    let estimatedUSD: Double
}

// One reconciliation sample: what the estimator predicted vs what the wire
// actually charged in prompt tokens.
struct CalibrationRow: Codable, Equatable, Sendable {
    let estimatedTokens: Int
    let actualTokens: Int
    let date: Date
}
