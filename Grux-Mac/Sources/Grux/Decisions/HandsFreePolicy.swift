import Foundation

/// What a spoken command may do without asking. Fixed by design, not a
/// setting: reversible things happen on the spot, anything that reaches
/// another person or cannot be undone stops in Approvals first, and shell,
/// publishing, payments and permission grants never run by voice alone.
enum HandsFreeClass: Equatable {
    case onTheSpot
    case asksFirst
    case never
}

enum HandsFreePolicy {
    static func classify(action: MacroAction) -> HandsFreeClass {
        switch action {
        case .runShell, .runInTerminalCell, .runAppleScript, .speakShellOutput:
            return .never
        case .launchApp, .openURL, .spawnTerminalsToGrid, .playMusic, .prepareCleanWorkspace, .speak,
             .delay, .awaitSilence, .openEmpireDashboard:
            return .onTheSpot
        }
    }

    /// A macro is as strict as its strictest enabled step.
    static func classify(macro: Macro) -> HandsFreeClass {
        var worst: HandsFreeClass = .onTheSpot
        for step in macro.actions where step.enabled {
            switch classify(action: step.action) {
            case .never: return .never
            case .asksFirst: worst = .asksFirst
            case .onTheSpot: break
            }
        }
        return worst
    }
}
