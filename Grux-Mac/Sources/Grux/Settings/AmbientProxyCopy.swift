import Foundation

/// D200 item 15 (sense pass 28): Settings, Ambient's "Local Qwen ambient brain"
/// showed a developer's companion port, "Ollama-backed Qwen3" and "Claude is
/// the fallback". The switch reaches only a proxy that answers Grux's own
/// `/api/llm/local` request (`LocalLLMClient`: a `content` field back, which
/// Ollama's own API does not send), and with it off, or when that proxy does
/// not answer, every background job takes chat's route
/// (`AmbientLLM.completeTagged`), which refuses rather than leave the Mac when
/// chat's local model is not running (`AmbientLLM.fallbackRefusal`).
enum AmbientProxyCopy {
    static let title = "Your own proxy for background jobs"
    static let toggle = "Send background jobs to your own proxy"
    static let endpointPrompt = "http://your-proxy/api/llm/local"

    /// `route` is the one background jobs take without the proxy, as
    /// `PrivacyAsk.routes` resolves it for the nightly passes.
    /// The jobs that go through `AmbientLLM.completeTagged`, the only path that asks
    /// the proxy (hourly summaries, the workday log and energy recap, folder sorting,
    /// mail triage and its corrections, notification triage, person and decision memory,
    /// cold email drafts, issue notes). Wave 70: the caption said "and the rest", and
    /// meeting summaries, ambient memories, the coach, dictation clean-up and thread
    /// titles never use the switch.
    static let proxyJobs = "hourly ambient summaries, the workday log, folder sorting, mail and notification triage, and what Grux notes about people and decisions"

    static let otherJobs = "Other jobs, such as meeting summaries, ambient memories, the voice coach, dictation clean-up and thread titles, do not use this switch."

    /// `route` is the one these jobs take without the proxy, as `PrivacyAsk.routes`
    /// resolves it for the nightly passes. `proxyOn` is the switch as saved with an
    /// address in the field, the condition `AmbientLLM.completeTagged` asks.
    static func caption(route: PrivacyAsk.Route, proxyOn: Bool) -> String {
        let jobs = "Grux's background jobs (\(proxyJobs))"
        let now: String
        let fallback: String
        switch route {
        case .thisMac(let model):
            now = "\(jobs) already run on \(model) on this Mac, the model your chat runs on, so you can leave this off."
            fallback = "each job goes to \(model) instead, and does nothing while it is not running."
        case .otherMachine(let model, let host):
            now = "\(jobs) already run on \(model) at \(host), the model your chat runs on."
            fallback = "each job goes to \(model) instead, and does nothing while it is not running."
        case .anthropic:
            now = "\(jobs) already go to Claude with your Anthropic key, the model your chat runs on."
            fallback = "each job goes to Claude instead."
        case .custom(let name, let host):
            now = "\(jobs) already go to \(name) at \(host), the model your chat runs on."
            fallback = "each job goes to \(name) instead."
        case .none:
            now = "Chat has no model yet, so \(jobs) have no model to use either."
            fallback = "each job does nothing until chat has a model."
        }
        if proxyOn {
            return "On: \(jobs) go to your proxy. When it does not answer, " + fallback + " " + otherJobs
        }
        return now + " Turn this on only for a proxy you run yourself that answers Grux's /api/llm/local request; Ollama's own address does not work here. When the proxy does not answer, " + fallback + " " + otherJobs
    }
}
