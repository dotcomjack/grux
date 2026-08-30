import SwiftUI

// The signature CTA. A small native glass pill that hands a deep-audit prompt to
// Grux's own chat: it stages the prompt on AppState.pendingChatPrompt and routes
// to the chat tab (exactly how AgentsView / HomeView / GruxApp already switch
// tabs). It does NOT auto-send; ChatView pre-fills the composer so the user can edit
// before sending. Droppable on a brand, family, ad, or attention item.
//
// Prompt source: a pre-baked prompt when the engine provides one, else a
// per-target template generated here. Zero em/en dashes, dollars as $N.
struct SendToClaudeButton: View {
    enum Scope { case empire, brand, family, ad, attention }

    let scope: Scope
    var label: String? = nil          // display label of the target (brand name, ad name, family)
    var brand: String? = nil
    var nodeId: String? = nil
    var crid: String? = nil
    var changedVariable: String? = nil
    var variableValue: String? = nil
    var bakedPrompt: String? = nil     // the engine's send_to_claude_prompt, used verbatim when present
    var compact: Bool = false          // icon-only pill for dense rows

    var body: some View {
        Button(action: fire) {
            HStack(spacing: 5) {
                Image(systemName: "sparkles")
                    .font(.system(size: compact ? 10 : 11, weight: .bold))
                if !compact {
                    Text("Send to Claude")
                        .font(GruxTheme.Font.microCaps)
                        .kerning(1.0)
                }
            }
            .foregroundStyle(GruxTheme.accentPrimaryLight)
            .padding(.horizontal, compact ? 7 : 11)
            .padding(.vertical, compact ? 5 : 6)
            .background(Capsule().fill(GruxTheme.accentPrimary.opacity(0.16)))
            .overlay(Capsule().strokeBorder(GruxTheme.accentPrimary.opacity(0.40), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Hand this to Claude in chat for a full audit, research, and a recommended action")
    }

    private func fire() {
        let prompt = bakedPrompt ?? generatedPrompt()
        AppState.shared.pendingChatPrompt = prompt
        AppState.shared.requestedTab = "chat"
    }

    private func generatedPrompt() -> String {
        let b = (brand ?? "this brand").uppercased()
        let name = label ?? (nodeId ?? crid ?? b)
        switch scope {
        case .empire:
            return "Fully audit, analyze, and research the Meta ads across every brand. Review the empire roll-up totals, each brand's active ads, the concept-family lineage, spend pacing against the caps, the winners and the graveyard, and the open A/B tests. Pull firm outside research on what is working in these categories right now. Then decide whether we should act: scale, kill, reallocate budget, or spin up new A/B tests, and name the exact one-variable changes to test next. Recommend concrete moves with the reasoning and the risk."
        case .brand:
            return "Fully audit, analyze, and research the Meta ads for \(b). Review every active ad, the concept-family lineage, spend pacing against the daily and weekly caps, the winners and the graveyard, and the open A/B tests. Pull firm outside research on what is working for this category right now. Then decide whether we should act: scale, kill, reallocate budget, or spin up new A/B tests, and name the exact one-variable changes to test next. Recommend concrete moves with the reasoning and the risk."
        case .family:
            return "Fully audit the concept family \(name) for \(b). Walk the lineage from the root through every variant, the one variable each branch changed, the CPA and ROAS trend, and the Bayesian P(B>A) standing. Research comparable angles in the market. Then decide: promote a winner, kill the laggards, or branch a new one-variable test, and say which variable and value."
        case .ad:
            let varLine = changedVariable.map { v in
                " The one tested variable is \(v)" + (variableValue.map { "=\($0)" } ?? "") + "."
            } ?? ""
            return "Fully audit \(b) ad \(name).\(varLine) Look at the creative, the targeting (person location, age, gender, device, placement, day-parting), the spend, CPA, ROAS, frequency and fatigue, learning progress, the cost-per-result trend, and the best-performing audience segment. Research whether this angle has room to scale. Then decide whether we should hold, scale, kill, or spawn a new A/B test off it, and name the single variable to change next."
        case .attention:
            return "Fully audit and research \(name) for \(b), then decide whether we should act on it. Look at the data behind it, pull firm outside research, and recommend a concrete move (scale, kill, reallocate, or a new one-variable A/B test) with the reasoning and the risk."
        }
    }
}
