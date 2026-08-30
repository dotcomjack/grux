import SwiftUI

// The onboarding cockpit. Shown on a brand that is not yet live: a checklist
// that takes it from SIMULATE (act_PLACEHOLDER) to a real, tracked, spend-capable
// Meta ad account. Each step shows done/pending and who owns it (YOU for a human
// Meta-account action, GRUX for steps Claude drives). The current step is called
// out with a Send to Claude so the user can hand the next move straight to chat.
struct MetaAdsOnboardingCard: View {
    let brandKey: String
    let brandName: String
    let onboarding: BrandOnboarding

    var body: some View {
        GruxGlassCard {
            VStack(alignment: .leading, spacing: 14) {
                header
                progressBar
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(Array(onboarding.steps.enumerated()), id: \.offset) { _, step in
                        stepRow(step)
                    }
                }
                if let next = onboarding.nextStep, !next.isEmpty {
                    nextStepStrip(next)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay(
            RoundedRectangle(cornerRadius: GruxTheme.Radius.hud, style: .continuous)
                .strokeBorder(GruxTheme.accentPrimary.opacity(0.30), lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "rocket.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(GruxTheme.accentPrimaryLight)
            VStack(alignment: .leading, spacing: 1) {
                MetaAdsEyebrow(text: "Onboarding to live ads", tint: GruxTheme.accentPrimaryLight)
                Text("\(brandName) is in SIMULATE")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(GruxTheme.textPrimary)
            }
            Spacer()
            Text("\(onboarding.doneCount)/\(onboarding.totalCount)")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(GruxTheme.accentPrimaryLight)
        }
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule().fill(GruxTheme.iridescent)
                    .frame(width: max(4, geo.size.width * CGFloat(onboarding.doneCount) / CGFloat(max(1, onboarding.totalCount))))
            }
        }
        .frame(height: 6)
    }

    private func stepRow(_ step: (label: String, done: Bool, owner: String)) -> some View {
        HStack(spacing: 10) {
            Image(systemName: step.done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(step.done ? GruxTheme.successMint : GruxTheme.textTertiary)
            Text(step.label)
                .font(.system(size: 12, weight: step.done ? .medium : .semibold))
                .foregroundStyle(step.done ? GruxTheme.textTertiary : GruxTheme.textPrimary)
                .strikethrough(step.done, color: GruxTheme.textTertiary)
            Spacer(minLength: 6)
            ownerTag(step.owner, done: step.done)
        }
    }

    private func ownerTag(_ owner: String, done: Bool) -> some View {
        let isYou = owner == "you"
        let tint = isYou ? GruxTheme.warnAmber : GruxTheme.accentPrimaryLight
        return Text(isYou ? "YOU" : "GRUX")
            .font(GruxTheme.Font.microCaps)
            .foregroundStyle(done ? GruxTheme.textTertiary : tint)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill((done ? GruxTheme.textTertiary : tint).opacity(0.14)))
    }

    private func nextStepStrip(_ next: String) -> some View {
        let blockedYou = onboarding.blockedOn == "you"
        let tint = blockedYou ? GruxTheme.warnAmber : GruxTheme.accentPrimaryLight
        return VStack(alignment: .leading, spacing: 8) {
            Divider().overlay(GruxTheme.iridescentRim).opacity(0.5)
            HStack(spacing: 8) {
                Image(systemName: blockedYou ? "person.fill" : "sparkles")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(tint)
                Text(blockedYou ? "NEEDS YOU" : "GRUX NEXT")
                    .font(GruxTheme.Font.microCaps)
                    .foregroundStyle(tint)
                Spacer()
                SendToClaudeButton(
                    scope: .brand,
                    label: brandName,
                    brand: brandKey,
                    bakedPrompt: claudePrompt,
                    compact: true
                )
            }
            Text(next)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(GruxTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var claudePrompt: String {
        "Walk me through the next step of onboarding \(brandName.uppercased()) to live Meta ads: \(onboarding.nextStep ?? "the next action"). Do every part you can yourself, and if any step needs me (a Meta account action), give me the exact minimal clicks. Current progress: \(onboarding.doneCount) of \(onboarding.totalCount) steps done."
    }
}
