import Foundation

/// D186: what the chat model is told about itself, so a question about Grux is
/// answered from facts. Sense pass 24 (6:36 AM Nov 7) measured Grux Local 2B
/// with nothing to go on: "Do you work without internet?" got "I don't have an
/// internet connection", "Can I use a smarter model?" got "switch to one
/// through your system settings", and "How do I turn off Talks back?" got "the
/// Voice & Ambient app". The route comes from `PrivacyAsk.routes`, the one the
/// privacy answer reads, so the two never disagree about where chat goes.
enum AboutYou {
    static func block(name: String, route: PrivacyAsk.Route, offline: Bool, localModelsLine: String) -> String {
        var lines = [
            "ABOUT_YOU (true facts about you and this app; answer any question about yourself from these, never guess):",
            "- Your name is \(name). The app is Grux AI. It is free and needs no account.",
        ]
        switch route {
        case .thisMac(let model):
            lines.append("- Your replies come from \(model), a model running on this Mac, so chat works with no internet connection.")
        case .otherMachine(let model, let host):
            lines.append("- Your replies come from \(model) on \(host), another machine Grux is set to use, so chat needs that machine reachable.")
        case .anthropic:
            lines.append("- Your replies come from Claude, through the Anthropic API, over the internet.")
        case .custom(let name, let host):
            lines.append("- Your replies come from \(name) at \(host), over the network.")
        case .none(let step):
            lines.append("- Chat has no model to answer with yet. " + (step ?? "Settings, \(SettingsPane.models.label) sets one up."))
        }
        if offline { lines.append("- Offline mode is on, so web search is off.") }
        // Where Local Models opens comes from the line first run and the self
        // answers print; "the Local Models tab" named a tab a new install hides.
        lines.append("- A bigger or smarter model: \(localModelsLine) "
            + "Or add a cloud API key in Settings, \(SettingsPane.models.label).")
        lines.append("- Reading replies aloud: \(VoiceAsk.switchName) in Tuning, under \(TuningCopy.Card.talks.title). "
            + "To quiet you at once: \(VoiceAsk.muteButton).")
        return lines.joined(separator: "\n")
    }

    @MainActor
    static func block(state: AppState) -> String {
        block(name: UserIdentity.assistantName, route: PrivacyAsk.routes(state: state).route,
              offline: state.config.offlineMode,
              localModelsLine: HowItWorksCopy.localModelsLine(door: FeatureRegistry.disposition(for: "cookbook"),
                                                              developerUnlocked: state.config.developerSurfacesUnlocked))
    }
}
