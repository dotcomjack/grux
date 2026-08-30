import SwiftUI

// JaxHQView: the Jax HQ surface. Jax is Grux with the user's own judgment switched
// on. The Chat tab is conversational Jax; this is the OVERSIGHT HQ where the clone's
// autonomous work surfaces for review:
//
//   1. PENDING APPROVALS : the decision gate's queue (ApprovalQueue.shared). Jax
//      never acts on a guardrailed action autonomously; it queues it here for a
//      one-tap verdict, with the resolved comms persona shown.
//   2. TODAY'S BRIEFING  : the latest voice-first briefing (BriefingEngine.shared),
//      spoken in the configured voice, with [read aloud] to hear it again.
//   3. GOALS IN MOTION   : what Jax is chasing between check-ins (the in-progress
//      roadmap tier, RoadmapStore.shared).
//   4. ACTIVITY LOG      : a recent timeline derived from the approval queue's full
//      history (queued / approved / skipped) plus the last briefing spoken.
//
// Binds to the REAL sibling singletons (no parallel state), renders entirely in
// GruxTheme so it reads as a first-class CURRENT surface, money is $N, zero em/en
// dashes, tight controls.
struct JaxHQView: View {
    @ObservedObject private var queue = ApprovalQueue.shared
    @ObservedObject private var briefings = BriefingEngine.shared
    @ObservedObject private var roadmap = RoadmapStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                hero
                // The support-reply review queue lives here now (UI/UX decision
                // 1A): one hub for what needs you, brand-filtered.
                JaxDraftsSection()
                // What Jax filtered out (no-reply / marketing / muted), visible
                // and recoverable instead of silently logged.
                JaxFilteredSection()
                // What Jax learned from your edits (Phase 2): lessons that now
                // shape future drafts, with the correction that taught them.
                JaxLessonsSection()
                // Per-brand send autonomy + graduation (Phase 4): OBSERVE by
                // default; LIVE auto-sends only what the output gate clears.
                JaxSendAutonomySection()
                JaxApprovalsSection(
                    approvals: queue.pending,
                    onApprove: { id in Task { await queue.approveAndExecute(id) } },
                    onSkip: { queue.skip($0) }
                )
                JaxBriefingSection(
                    briefing: briefings.latest,
                    isSpeaking: briefings.isBriefing
                )
                JaxGoalsSection(items: chasing)
                JaxActivitySection(history: queue.items, latestBriefing: briefings.latest)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(GruxTheme.base)
        .onAppear {
            queue.load()
            roadmap.load()
        }
    }

    // Goals in motion = the roadmap items the user is actively pushing. Newest activity
    // first so the freshest pursuit is on top.
    private var chasing: [RoadmapItem] {
        roadmap.items
            .filter { $0.status == .inProgress }
            .sorted { $0.order < $1.order }
    }

    // MARK: Hero

    private var hero: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle()
                    .fill(GruxTheme.iridescent)
                    .frame(width: 38, height: 38)
                    .shadow(color: GruxTheme.violetGlow(strong: true), radius: 12)
                Image(systemName: "sparkle")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 1) {
                MetaAdsEyebrow(text: "Your clone, between check-ins", tint: GruxTheme.accentPrimaryLight)
                Text("Jax HQ")
                    .font(GruxTheme.Font.title)
                    .foregroundStyle(GruxTheme.textPrimary)
            }
            Spacer()
            statPill(count: queue.pendingCount, label: "PENDING", tint: GruxTheme.warnAmber, icon: "checkmark.seal.fill")
            statPill(count: chasing.count, label: "CHASING", tint: GruxTheme.accentPrimaryLight, icon: "scope")
        }
    }

    private func statPill(count: Int, label: String, tint: Color, icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10, weight: .bold))
            Text("\(count)").font(.system(size: 12, weight: .heavy, design: .rounded))
            Text(label).font(GruxTheme.Font.microCaps).kerning(1.2)
        }
        .foregroundStyle(count > 0 ? tint : GruxTheme.textTertiary)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill((count > 0 ? tint : Color.white).opacity(count > 0 ? 0.14 : 0.05)))
        .overlay(Capsule().strokeBorder((count > 0 ? tint : Color.white).opacity(count > 0 ? 0.35 : 0.10), lineWidth: 1))
    }
}
