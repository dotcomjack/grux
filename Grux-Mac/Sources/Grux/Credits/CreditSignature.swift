import Foundation

/// Every key Grux holds that spends a prepaid credit. One `CreditState` shape
/// serves all of them (P-R-3); the raw values are the keys in `credits.json`.
enum CreditProvider: String, Codable, CaseIterable {
    case jev
    case openRouter = "openrouter"
    case elevenLabs = "elevenlabs"
    case replicate
    case anthropic
}

/// How each provider says, in its OWN response, that the credit is gone.
///
/// KNOW, NEVER GUESS. The operator, 2026-09-21: "we don't assume anything, we
/// must know that credits are out." A 500, a timeout, a 401 bad key, a 429
/// rate limit and a body that does not parse all say nothing about the
/// balance, and every one of them answers false here. Only a status AND a body
/// shape the provider documents as out of credit answers true.
///
/// A provider that documents no such response answers false, with the gap
/// named where it is. A missed notice costs one person a quieter Mac; a false
/// one tells a person with money in the account that it is empty, and teaches
/// them to ignore the next one.
///
/// Pure: status and bytes in, a yes or no out. No clock, no store, no network.
enum CreditSignature {
    static func isExhausted(_ provider: CreditProvider, status: Int, body: Data) -> Bool {
        switch provider {
        case .jev: return jev(status: status, body: body)
        case .openRouter: return openRouter(status: status, body: body)
        case .elevenLabs: return elevenLabs(status: status, body: body)
        case .replicate: return replicate(status: status, body: body)
        case .anthropic: return anthropic(status: status, body: body)
        }
    }

    /// TypeSafe Jev. UNDOCUMENTED, SO THIS IS OFF.
    ///
    /// Checked 2026-09-21. https://docs.typesafe.ai/api, section Errors, lists
    /// exactly four statuses: 401 (missing or invalid key), 422 (validation),
    /// 429 (rate limit) and 529 (overloaded). https://api.typesafe.ai/openapi.json
    /// (version 0.2.0) declares only 200 and 422. The SDK exception pages
    /// (https://docs.typesafe.ai/sdk/python/api/exceptions and the JavaScript
    /// APIError subclasses) map 400, 401, 403, 404, 422, 429 and 5xx, and name
    /// no payment, credit or balance error. Two third party SDK issues assert a
    /// 402 exists but quote no body. Nor has it been observed: Grux had spent
    /// $0.12 of the $5 credit when this was written (Phase R plan baseline).
    ///
    /// So the response is neither documented nor observed, and guessing "402
    /// means out of credit" is exactly the inference this packet forbids. When
    /// the shape is known (documented, or captured from a live response), this
    /// one function is the whole change: the provider already reports every
    /// response here and the notice, the Usage card line and the episode rules
    /// are wired and tested.
    static func jev(status: Int, body: Data) -> Bool {
        false
    }

    /// OpenRouter. Documented, checked 2026-09-21:
    /// https://openrouter.ai/docs/api_reference/errors-and-debugging says a 402
    /// means "Your account or API key has insufficient credits. Add more
    /// credits and retry the request.", with the body
    /// `{"error": {"code": 402, "message": ..., "metadata"?: {...}}}`.
    ///
    /// https://openrouter.ai/docs/api_reference/limits ("Handling 402 errors")
    /// splits the 402 by `error.metadata.limit_source`, and two of its cases are
    /// NOT an empty balance:
    /// - `openrouter_in_flight_budget` (reason `in_flight_budget_exhausted`):
    ///   too many requests in flight right now, the balance is positive, and it
    ///   clears on its own after `Retry-After`. Transient, so false.
    /// - reason `weight_exceeds_budget` (limit_source `openrouter_credits`): this
    ///   one request is too large for the budget while the balance is still
    ///   positive; a smaller request succeeds. Not "out", so false.
    /// `openrouter_key_limit` (the key's own credit cap is used up) and
    /// `openrouter_credits` without that reason, or a 402 with no metadata at
    /// all, are the credit being gone: true.
    static func openRouter(status: Int, body: Data) -> Bool {
        guard status == 402,
              let error = object(body)?["error"] as? [String: Any],
              (error["code"] as? Int) == 402 else { return false }
        let metadata = error["metadata"] as? [String: Any]
        if metadata?["limit_source"] as? String == "openrouter_in_flight_budget" { return false }
        if metadata?["reason"] as? String == "weight_exceeds_budget" { return false }
        return true
    }

    /// ElevenLabs. Documented, checked 2026-09-21, in two shapes:
    /// - https://elevenlabs.io/docs/eleven-api/resources/errors: every error is
    ///   `{"detail": {"type", "code", "message", ...}}`; type `payment_required`
    ///   is "User has insufficient credits or payment is required", HTTP 402,
    ///   and its one code is `insufficient_credits`, "Your account does not have
    ///   enough credits for this operation."
    /// - https://elevenlabs.io/docs/help-center/technical/api-error-code-400-or-401:
    ///   a 400 or 401 whose `detail.status` is `quota_exceeded`, "You have
    ///   insufficient quota to complete the request."
    /// A 401 is ALSO how a bad key answers (`invalid_api_key`), which is why the
    /// status alone never decides: only `quota_exceeded` in the body does.
    static func elevenLabs(status: Int, body: Data) -> Bool {
        guard let detail = object(body)?["detail"] as? [String: Any] else { return false }
        switch status {
        case 402:
            return detail["code"] as? String == "insufficient_credits"
                || detail["type"] as? String == "payment_required"
        case 400, 401:
            return detail["status"] as? String == "quota_exceeded"
        default:
            return false
        }
    }

    /// Replicate. UNDOCUMENTED, SO THIS IS OFF.
    ///
    /// Checked 2026-09-21. https://replicate.com/docs/topics/billing/prepaid-credit
    /// says only that "as soon as your balance hits zero, we will prevent any
    /// new work from starting", with no status or body. The HTTP reference
    /// (https://replicate.com/docs/reference/http) and its OpenAPI schema
    /// (https://api.replicate.com/openapi.json, 1.0.0-a1: 200, 201, 202, 204,
    /// 400, 404, 413, 500) name no 402 and no credit error, and the error code
    /// list (https://replicate.com/docs/reference/error-codes) is prediction
    /// failures only. The official client reads any error as RFC 7807 problem
    /// details without naming an out of credit type. Neither documented nor
    /// observed, so false, and `ReplicateClient` already reports every submit
    /// here for the day it is known.
    static func replicate(status: Int, body: Data) -> Bool {
        false
    }

    /// Anthropic, the person's own chat key. Documented and observed, checked
    /// 2026-09-21 against https://platform.claude.com/docs/en/api/errors:
    /// every error is `{"type": "error", "error": {"type", "message"}, ...}`.
    ///
    /// An empty balance is NOT a documented status of its own. It arrives as a
    /// 400 `invalid_request_error`, the same status and type as a malformed
    /// request, with the sentence "Your credit balance is too low to access
    /// the Anthropic API." That exact response was received on this install on
    /// 2026-08-23 (the 563 refused calls in `ProviderHealth`) and again 358
    /// times in the week before 2026-09-21 (the rotated wake log, the last one
    /// three days before), so the sentence is the only thing that tells the two
    /// 400s apart, and it is read only inside that envelope.
    ///
    /// Three documented refusals are NOT an empty balance, and all answer
    /// false: 402 `billing_error` ("an issue with your billing or payment
    /// information", a card problem, not a balance), a 400 at a spend limit
    /// the person set themselves, and a 429 at a tier's monthly spend cap or
    /// a rate limit, which clear on their own. The first failure of each kind
    /// is still logged by `CreditMonitor`, so a new shape gets captured.
    static func anthropic(status: Int, body: Data) -> Bool {
        guard status == 400,
              let root = object(body), root["type"] as? String == "error",
              let error = root["error"] as? [String: Any],
              error["type"] as? String == "invalid_request_error",
              let message = error["message"] as? String else { return false }
        return message.lowercased().contains("credit balance is too low")
    }

    /// The body as a JSON object, or nil for anything else: empty, HTML, a
    /// truncated body, a bare array. Nil is always "not known", never a yes.
    private static func object(_ body: Data) -> [String: Any]? {
        guard !body.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }
}
