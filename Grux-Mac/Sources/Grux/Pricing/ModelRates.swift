import Foundation

// THE canonical per-model rate table for the whole app. Before this file the
// codebase carried three hand-maintained USD/MTok tables that had already
// drifted apart on Haiku 4.5 (UsageQuery + FoundryCostMeter said 0.80/4.00,
// ClaudeModelPricing said 1.00/5.00). This is now the one source of truth;
// UsageQuery.AnthropicModelTier, FoundryCostMeter, and ClaudeModelPricing all
// delegate here so a rate can never drift between the Usage card, the Foundry
// cycle accounting, and the session-JSONL replay again.
//
// HAIKU 4.5 DISAGREEMENT, RESOLVED: Anthropic's current published price for
// Claude Haiku 4.5 is $1.00 / MTok input and $5.00 / MTok output (cache read
// $0.10, 5-minute cache write $1.25). The old 0.80/4.00 pair was Haiku 3.5
// pricing that never got refreshed. We adopt 1.00/5.00 as canonical. This means
// the in-app Usage card's Haiku figure ticks UP to the truthful number.
//
// Everything here is pure Foundation, nonisolated static: safe to call from any
// actor, any thread, and from unit tests without a network or a MainActor hop.
enum ModelRates {

    // USD per million tokens, the shape all three legacy tables already used.
    struct Rates: Equatable, Sendable {
        var input: Double
        var output: Double
        var cacheRead: Double
        var cacheWrite: Double

        // A run that is never billed dollars: local models and subscription
        // (Claude Code CLI) runs. The cost surface renders these as "$0
        // estimated (free)" rather than a metered figure.
        static let zero = Rates(input: 0, output: 0, cacheRead: 0, cacheWrite: 0)

        var isZero: Bool {
            input == 0 && output == 0 && cacheRead == 0 && cacheWrite == 0
        }
    }

    // The cheapest KNOWN paid rate. Unknown non-local models resolve to this so
    // an unrecognized id never inflates a reported figure (mirrors the old
    // FoundryCostMeter default-to-Haiku policy, just at the corrected price).
    static let cheapestPaid = Rates(input: 1.00, output: 5.00, cacheRead: 0.10, cacheWrite: 1.25)

    // Ordered most-specific-prefix first so claude-opus-4-8 wins over a bare
    // claude-opus family match and claude-haiku-4-5-20251001 resolves to the
    // Haiku 4.5 row. Values for the exact Claude ids match what ClaudeModelPricing
    // shipped, so the session-replay cost numbers are unchanged by the migration.
    private static let ladder: [(prefix: String, rates: Rates)] = [
        ("claude-fable-5",   Rates(input: 10.00, output: 50.00, cacheRead: 1.00, cacheWrite: 12.50)),
        ("claude-opus-4-8",  Rates(input: 5.00,  output: 25.00, cacheRead: 0.50, cacheWrite: 6.25)),
        ("claude-opus-4-7",  Rates(input: 15.00, output: 75.00, cacheRead: 1.50, cacheWrite: 18.75)),
        ("claude-opus-4-6",  Rates(input: 15.00, output: 75.00, cacheRead: 1.50, cacheWrite: 18.75)),
        ("claude-sonnet-5",  Rates(input: 3.00,  output: 15.00, cacheRead: 0.30, cacheWrite: 3.75)),
        ("claude-sonnet-4-6", Rates(input: 3.00, output: 15.00, cacheRead: 0.30, cacheWrite: 3.75)),
        ("claude-sonnet-4-5", Rates(input: 3.00, output: 15.00, cacheRead: 0.30, cacheWrite: 3.75)),
        ("claude-haiku-4-5", Rates(input: 1.00,  output: 5.00,  cacheRead: 0.10, cacheWrite: 1.25)),
    ]

    // Family fallbacks by substring, for ids the exact ladder misses (OpenRouter
    // "anthropic/claude-3.5-sonnet" style, a future dated suffix, a bare
    // "claude-opus"). Opus/Sonnet families keep FoundryCostMeter's historical
    // public behavior (a stray "opus" still returns an opus rate, not Haiku).
    private static let opusFamily   = Rates(input: 15.00, output: 75.00, cacheRead: 1.50, cacheWrite: 18.75)
    private static let sonnetFamily = Rates(input: 3.00,  output: 15.00, cacheRead: 0.30, cacheWrite: 3.75)
    private static let fableFamily  = Rates(input: 10.00, output: 50.00, cacheRead: 1.00, cacheWrite: 12.50)
    private static let haikuFamily  = Rates(input: 1.00,  output: 5.00,  cacheRead: 0.10, cacheWrite: 1.25)

    // Model-id leading tokens that mark a locally hosted (Ollama / vLLM /
    // llama.cpp) model.
    //
    // READ THE RateSource BLOCK BELOW BEFORE USING THIS FOR ANYTHING. It is a
    // GUESS about provenance made from a name, it was measurably wrong on a
    // hosted route, and it now feeds only the legacy id-only entry points at the
    // bottom of this file. Nothing new should consult it.
    private static let localPrefixes = [
        "ollama", "qwen", "llama", "codellama", "gemma", "mistral", "mixtral",
        "phi", "deepseek", "starcoder", "nomic", "vicuna", "orca", "tinyllama",
        "yi", "command-r", "granite", "smollm", "dolphin"
    ]

    // MARK: - Provenance: where the request actually went

    // THE MEASURED BUG THIS TYPE EXISTS TO CLOSE. Local-versus-paid used to be
    // decided from the model id string alone: knownRates(forModelID:) split the
    // id on "/", kept the tail, and returned Rates.zero whenever that tail began
    // with any of the localPrefixes above. Through a hosted aggregator, whose ids
    // are namespaced, every one of these priced a real billable turn at $0:
    //
    //   deepseek/deepseek-chat            -> tail "deepseek-chat"          -> $0
    //   meta-llama/llama-3.3-70b-instruct -> tail "llama-3.3-70b-instruct" -> $0
    //   qwen/qwen3-max                    -> tail "qwen3-max"              -> $0
    //   mistralai/mistral-large           -> tail "mistral-large"          -> $0
    //   google/gemma-3-27b-it             -> tail "gemma-3-27b-it"         -> $0
    //   cohere/command-r-plus             -> tail "command-r-plus"         -> $0
    //
    // The namespace strip made it WORSE rather than better, because the namespace
    // is the single token that names the vendor billing you, and it was the one
    // part being thrown away. openai/gpt-4o matched nothing and landed on the
    // cheapest-paid Haiku rate instead, roughly 2.5x under its real price.
    //
    // This is not a hypothetical route: the endpoints pane in Settings suggests
    // OpenRouter by name and by URL. And onboarding promises "Chat shows the
    // estimated cost of your next send at API rates", so the wrong $0 lands on
    // precisely the number that was supposed to prevent a surprise invoice.
    //
    // A model id is a NAME. A name cannot tell you who is billing you. Only the
    // route can, so the route is what this carries.
    enum RateSource: Equatable, Sendable {
        // Anthropic's own API. The ladder and the family fallbacks apply.
        case anthropic
        // Served by a process on this machine or this LAN. The ONLY case where
        // free is a fact rather than a guess.
        case local
        // Any OpenAI-compatible endpoint that is not on this machine: OpenRouter,
        // a hosted vLLM farm, a cloud inference vendor. Everything here costs
        // money, including the models whose names look local. The URL is carried
        // so a captured RateSource names the endpoint it came from, which is what
        // makes a misclassification readable after the fact instead of only
        // reproducible.
        case hostedCompat(baseURL: String)
    }

    // Known HOSTED rates, USD per million tokens, matched on the FULL namespaced
    // id (never the tail). Ordered most-specific-prefix first, same idiom as the
    // ladder, so gpt-4o-mini cannot be swallowed by gpt-4o.
    //
    // PROVENANCE: the vendor's own published list price, which OpenRouter passes
    // through at par for these ids. cacheRead is the published 50% cached-input
    // rate. cacheWrite equals the INPUT rate rather than a premium, because OpenAI
    // charges nothing extra to populate its cache: a token that misses the cache
    // is billed as an ordinary input token and cached for free. That is a real
    // difference from Anthropic's 1.25x write, not an oversight.
    //
    // DELIBERATELY ABSENT, and this is the half that matters: deepseek/*, qwen/*,
    // meta-llama/*, mistralai/*, google/gemma*, cohere/* and every other id on the
    // aggregator. Their prices move, they differ by which upstream provider the
    // aggregator routes a given request to, and not one of them can be cited here
    // from a settled charge. They fall through to hostedFloor, which reads like
    // the placeholder it is, rather than carrying a number that would read like
    // data. Same argument Cookbook.swift makes for keeping llama4 out of its
    // catalog: a guess presented as fact is worse than a missing row. Add a row
    // the day the number can be cited.
    private static let hostedRates: [(prefix: String, rates: Rates)] = [
        ("openai/gpt-4o-mini", Rates(input: 0.15, output: 0.60, cacheRead: 0.075, cacheWrite: 0.15)),
        ("openai/gpt-4o",      Rates(input: 2.50, output: 10.00, cacheRead: 1.25, cacheWrite: 2.50)),
    ]

    // The floor for a hosted model we hold no cited rate for. It is cheapestPaid,
    // and it is a PLACEHOLDER rather than a claim about that model.
    //
    // Note that the direction is deliberately the opposite of the Anthropic path's
    // policy. There, an unknown id must never INFLATE a figure. Here, an unknown
    // id must never read $0, because $0 is the failure that costs the user real
    // money while the cost line tells them the send is free. Overstating a hosted
    // model is a nuisance the word "estimated" already covers; understating it to
    // zero is the entire bug.
    static let hostedFloor = cheapestPaid

    // MARK: - Rates by provenance (the entry point new code should use)

    // Rate for a model, decided by WHERE the request went rather than by what the
    // model is called. Every new caller should reach for this one.
    static func rates(forModelID modelID: String, source: RateSource) -> Rates {
        let full = modelID.lowercased()
        // Strip a provider prefix like "anthropic/" so "anthropic/claude-opus-4-8"
        // still matches the ladder. Only the Anthropic lookup uses the tail; the
        // hosted table matches on the full id precisely because the namespace is
        // the load-bearing token there.
        let tail = full.split(separator: "/").last.map(String.init) ?? full

        switch source {
        case .local:
            // A process on this machine or this LAN bills nobody, whatever the
            // model is called. The one place a zero rate is a fact.
            return .zero

        case .anthropic:
            return anthropicKnownRates(full: full, tail: tail) ?? cheapestPaid

        case .hostedCompat:
            // NEVER .zero from here, on any path. A local-looking name on a
            // hosted route is exactly what produced the $0 bug.
            for entry in hostedRates where full.hasPrefix(entry.prefix) {
                return entry.rates
            }
            // An aggregator fronting Anthropic ("anthropic/claude-opus-4-8")
            // bills Anthropic's list price, so reuse the ladder this file already
            // owns rather than keeping a second copy of the same numbers that can
            // drift from it, which is the failure the whole file was written for.
            if let anthropicRate = anthropicKnownRates(full: full, tail: tail) {
                return anthropicRate
            }
            return hostedFloor
        }
    }

    // The Anthropic ladder plus the family fallbacks, with no provenance guessing
    // of any kind. Shared by the .anthropic case, the aggregator-fronting-
    // Anthropic case, and the legacy id-only entry points below.
    private static func anthropicKnownRates(full: String, tail: String) -> Rates? {
        for entry in ladder where tail.hasPrefix(entry.prefix) {
            return entry.rates
        }
        // Family fallbacks (substring on the full id).
        if full.contains("opus") { return opusFamily }
        if full.contains("fable") { return fableFamily }
        if full.contains("sonnet") { return sonnetFamily }
        if full.contains("haiku") { return haikuFamily }
        return nil
    }

    // MARK: - Is this base URL on this machine

    // Loopback, a Bonjour .local name, or an RFC1918 LAN address means the model
    // is served by hardware the user already owns, so no invoice exists. Anything
    // else is somebody else's computer, and it charges for the privilege.
    //
    // Pure and total: no DNS, no reachability probe, no network of any kind, so it
    // is safe on any thread and testable without a server. An empty or
    // unparseable base URL returns FALSE, meaning hosted. Unknown provenance has
    // to price as paid, because the failure that costs money is the one that
    // says $0.
    static func isLocalBaseURL(_ baseURL: String) -> Bool {
        let h = host(fromBaseURL: baseURL)
        guard !h.isEmpty else { return false }
        if h == "localhost" || h.hasSuffix(".localhost") { return true }
        if h == "::1" || h == "0:0:0:0:0:0:0:1" { return true }
        if h.hasSuffix(".local") { return true }               // Bonjour name on the LAN
        if let o = ipv4Octets(h) {
            if o[0] == 127 { return true }                              // 127.0.0.0/8
            if o[0] == 10 { return true }                               // 10.0.0.0/8
            if o[0] == 172 && (16...31).contains(o[1]) { return true }  // 172.16.0.0/12
            if o[0] == 192 && o[1] == 168 { return true }               // 192.168.0.0/16
        }
        return false
    }

    // Host out of a base URL, lowercased, with scheme, userinfo, port, path and
    // IPv6 brackets removed.
    //
    // Hand-rolled rather than URLComponents because the value it reads is a
    // free-text Settings box that is routinely missing its scheme
    // ("localhost:11434"), and URLComponents parses that as scheme "localhost"
    // with host nil. That would classify the user's own Ollama as hosted and
    // price every genuinely free local turn as paid, which is the same class of
    // wrong answer in the opposite direction.
    private static func host(fromBaseURL baseURL: String) -> String {
        var s = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let scheme = s.range(of: "://") { s = String(s[scheme.upperBound...]) }
        if let slash = s.firstIndex(of: "/") { s = String(s[..<slash]) }
        if let at = s.lastIndex(of: "@") { s = String(s[s.index(after: at)...]) }
        // Bracketed IPv6 with an optional port, "[::1]:11434".
        if s.hasPrefix("["), let close = s.firstIndex(of: "]") {
            return String(s[s.index(after: s.startIndex)..<close])
        }
        // A bare IPv6 literal carries several colons and no port, so only strip a
        // port when there is exactly one colon to strip.
        if s.filter({ $0 == ":" }).count == 1, let colon = s.firstIndex(of: ":") {
            s = String(s[..<colon])
        }
        return s
    }

    // Four numeric 0...255 octets, or nil. Written strictly so a public hostname
    // that merely starts with a private-looking label, "10.example.com", cannot
    // be mistaken for a LAN address.
    private static func ipv4Octets(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var out: [Int] = []
        for p in parts {
            guard !p.isEmpty, p.allSatisfy({ $0.isNumber }),
                  let v = Int(p), (0...255).contains(v) else { return nil }
            out.append(v)
        }
        return out
    }

    // MARK: - Legacy id-only path

    // LEGACY, id-only, and kept working deliberately. Rate for a KNOWN model, or
    // nil for a genuinely unrecognized paid id. Local-LOOKING ids resolve to
    // Rates.zero via the localPrefixes guess.
    //
    // WHY IT STILL EXISTS: its two callers price history, and history records a
    // model id and nothing about the route. ClaudeSessionJSONL replays Claude Code
    // session files and relies on nil-for-unknown to bill $0 rather than a
    // cheapest-known fallback. FoundryGovernor's cycle accounting sums usage rows
    // the same way. Both are Anthropic-side by construction, so the localPrefixes
    // guess cannot reach a hosted route from either one.
    //
    // Anything that CAN name its route must use rates(forModelID:source:) instead.
    static func knownRates(forModelID modelID: String) -> Rates? {
        let full = modelID.lowercased()
        // Strip a provider prefix like "anthropic/" or "ollama/" so
        // "anthropic/claude-opus-4-8" still matches the ladder.
        let tail = full.split(separator: "/").last.map(String.init) ?? full

        if localPrefixes.contains(where: { tail.hasPrefix($0) }) {
            return .zero
        }
        return anthropicKnownRates(full: full, tail: tail)
    }

    // LEGACY, id-only. Same provenance guess as knownRates(forModelID:), with the
    // unknown-model policy applied: an unrecognized paid model falls back to the
    // cheapest known rate so it can never inflate a figure. Prefer
    // rates(forModelID:source:).
    static func rates(forModelID modelID: String) -> Rates {
        knownRates(forModelID: modelID) ?? cheapestPaid
    }

    // Cost formula copied from FoundryCostMeter.estimatedUSD: tokens x rate /
    // 1e6, summed over the four token classes. The single place the app turns
    // token counts into dollars.
    //
    // Takes resolved Rates rather than a model id so a caller that already knows
    // the provenance prices with it instead of re-entering the id-only guess
    // through the back door, which is how the $0 bug would otherwise survive the
    // fix at this one call.
    static func estimatedUSD(inputTokens: Int, outputTokens: Int,
                             cacheReadTokens: Int, cacheCreationTokens: Int,
                             rates r: Rates) -> Double {
        let m = 1_000_000.0
        return Double(inputTokens) * r.input / m
            + Double(outputTokens) * r.output / m
            + Double(cacheReadTokens) * r.cacheRead / m
            + Double(cacheCreationTokens) * r.cacheWrite / m
    }

    // LEGACY, id-only convenience over the formula above. Prices through the
    // provenance guess; see rates(forModelID:).
    static func estimatedUSD(inputTokens: Int, outputTokens: Int,
                             cacheReadTokens: Int, cacheCreationTokens: Int,
                             modelID: String) -> Double {
        estimatedUSD(inputTokens: inputTokens, outputTokens: outputTokens,
                     cacheReadTokens: cacheReadTokens,
                     cacheCreationTokens: cacheCreationTokens,
                     rates: rates(forModelID: modelID))
    }
}
