import SwiftUI

// How a voice decision looks to a person, in one place. The ambient HUD, the
// live rail in Chat and the notification banner all render the same event, so
// they read from here rather than each inventing a colour and a phrase.
//
// Nothing internal reaches the face. A command id like "tab:calendar" or
// "not_a_command" is an identifier, and identifiers are banned from every
// surface a person looks at.

extension VoiceDecisionEvent {
    enum Tone: Equatable {
        /// Not for Grux. Grey, and deliberately quiet.
        case chatter
        /// Grux acted. Green, with the latency.
        case decided
        /// Grux stopped to ask. Amber.
        case asked
        /// Grux will not do this by voice. Rose.
        case refused
    }

    var tone: Tone {
        switch outcome {
        case .ignored:    return .chatter
        case .executed:   return .decided
        case .askedFirst: return .asked
        case .refused:    return .refused
        }
    }

    /// What was said. Trimmed so a long sentence cannot push the latency off
    /// the edge of a 320pt HUD.
    var heardLine: String {
        let t = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > 72 ? String(t.prefix(69)) + "..." : t
    }

    /// The latency, shown only where it means something. Chatter that Grux
    /// correctly ignored does not need a stopwatch next to it.
    var latencyLine: String { tone == .chatter ? "" : "\(latencyMs) ms" }

    /// What Grux did about it, in words.
    var actionLine: String {
        switch outcome {
        case .ignored:    return "not for Grux"
        case .askedFirst: return "asked first: \(Self.plainAction(commandId))"
        case .refused:    return "never by voice: \(Self.plainAction(commandId))"
        case .executed:   return Self.plainAction(commandId)
        }
    }

    /// Turns an internal command id into something a person reads.
    static func plainAction(_ commandId: String) -> String {
        if commandId == VoiceCommandRouter.sayToChat { return "sent to chat" }
        if commandId == LocalDecisionProvider.notACommand { return "not for Grux" }
        if commandId == "mute" { return "muted" }
        if commandId == "unmute" { return "listening" }
        if commandId.hasPrefix("macro:") { return "ran " + String(commandId.dropFirst("macro:".count)) }
        if commandId.hasPrefix("tab:") {
            let key = String(commandId.dropFirst("tab:".count))
            return "opened " + (tabLabel(key) ?? key)
        }
        return commandId
    }

    /// The sidebar's own label for a tab key, so the rail and the sidebar
    /// never call the same surface two different things.
    static func tabLabel(_ key: String) -> String? {
        for group in SidebarIA.groups {
            if let item = group.items.first(where: { $0.key == key }) { return item.label }
        }
        return nil
    }
}

extension VoiceDecisionEvent.Tone {
    var color: Color {
        switch self {
        case .chatter: return GruxTheme.textSecondary
        case .decided: return GruxTheme.successMint
        case .asked:   return GruxTheme.warnAmber
        case .refused: return GruxTheme.destructiveRose
        }
    }
}
