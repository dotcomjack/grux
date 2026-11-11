import Foundation

/// Settings, Ambient's "Nightly passes over the transcript" said both jobs send
/// the transcript to "the local one when it is running, otherwise the cloud
/// model you configured", on a Mac with no cloud model (D187 item 5). The
/// "local one" is your own proxy for background jobs (`AmbientLLM`), off by default,
/// and the fallback is the route chat's background jobs take
/// (`PrivacyAsk.routes`), which may be this Mac's own model. A local route
/// that is down sends nothing elsewhere (`AmbientLLM.fallbackRefusal`, W64-FIX).
enum NightlyPassCaption {
    /// `brainOn` is `AmbientLLM`'s own test (the switch on and an endpoint
    /// typed); `claudeKey` is a stored Anthropic key, which `PersonMemory`
    /// retries on when the proxy's reply cannot be read.
    static func text(brainOn: Bool, route: PrivacyAsk.Route, claudeKey: Bool) -> String {
        let lead = "Two jobs can read the day's ambient transcript overnight. Both are off by default, and both need ambient listening on to have anything to read."
        let chat: String?
        switch route {
        case .thisMac(let model):
            chat = "\(model) on this Mac, the model your chat runs on, so it stays on this Mac, and they write nothing while it is not running"
        case .otherMachine(let model, let host):
            chat = "\(model) at \(host), the model your chat runs on, and they write nothing while it is not running"
        case .anthropic:
            chat = "Claude with your Anthropic key, the model your chat runs on, so it leaves your Mac"
        case .custom(let name, let host):
            chat = "\(name) at \(host), the model your chat runs on, so it leaves your Mac"
        case .none:
            chat = nil
        }
        var out = lead
        if brainOn {
            if let chat {
                out += " Both send it to your proxy endpoint below, and to \(chat) when that endpoint does not answer."
            } else {
                out += " Both send it to your proxy endpoint below, and write nothing when it does not answer, since chat has no model yet."
            }
            if claudeKey {
                out += " Notes on people retry on Claude with your Anthropic key when the proxy's reply cannot be read."
            }
        } else if let chat {
            out += " Both send it to \(chat)."
        } else {
            out += " Chat has no model yet, so there is no model to send it to and they write nothing."
        }
        return out
    }
}
