import Foundation

// Detects the synthetic "monthly usage limit" signal the `claude` CLI emits
// in stream-json when the user's Claude.ai subscription exceeds its monthly
// quota. Captured shape from a real limit-hit on 2026-04-25:
//
//   assistant event: model "<synthetic>", error "rate_limit",
//                    content text "You've hit your org's monthly usage limit"
//   result event:    is_error true, api_error_status 429, stop_reason "stop_sequence",
//                    result text "You've hit your org's monthly usage limit"
//
// We accept any of three signals so a future minor wording change doesn't
// silently flip back to "marked as failed":
//   1. structural: `"error":"rate_limit"`         (assistant event)
//   2. structural: `"api_error_status":429`        (result event)
//   3. textual:    /monthly usage limit|monthly limit (has been )?reached/i
//
// The text fallback is only checked alongside one of the structural fields'
// surrounding type so a tool_result that happens to discuss the phrase
// (e.g. a worker writing docs *about* rate limits) doesn't poison.
public enum LimitSignal {

    /// Returns true if the raw stream-json line indicates the worker hit the
    /// Anthropic monthly subscription limit. Caller passes the unparsed JSON
    /// line - operating on raw text avoids any dependence on the
    /// StreamJSONParser internals (which today don't surface error fields).
    public static func detect(rawLine: String) -> Bool {
        // Strongest signals first - these are unambiguous regardless of text
        // content. Both fields are unique to limit-hit synthetic events: the
        // happy path never contains them.
        if rawLine.contains(#""error":"rate_limit""#) { return true }
        if rawLine.contains(#""api_error_status":429"#) { return true }

        // Text fallback. Restrict to assistant or result events so a literal
        // string inside a tool_result (e.g. a Bash output referencing the
        // phrase) can't false-positive. The synthetic-model marker is also a
        // reliable signpost the CLI generated this on the limit-hit path.
        let isLikelyLimitEvent =
            rawLine.contains(#""type":"assistant""#) ||
            rawLine.contains(#""type":"result""#) ||
            rawLine.contains(#""model":"<synthetic>""#)
        guard isLikelyLimitEvent else { return false }

        let phrases = [
            "monthly usage limit",
            "monthly limit has been reached",
            "reached your monthly usage limit",
            "your subscription's monthly limit",
            "exceeded your monthly limit"
        ]
        let lower = rawLine.lowercased()
        for p in phrases where lower.contains(p) { return true }
        return false
    }

    /// Extract the `result.text` (if any) for a limit-hit result event so the
    /// orchestrator can surface it in the AgentStep log. Returns nil for any
    /// non-result line. Best-effort - we don't strictly validate the schema.
    public static func extractResultText(rawLine: String) -> String? {
        guard rawLine.contains(#""type":"result""#) else { return nil }
        guard let data = rawLine.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj["result"] as? String
    }
}
