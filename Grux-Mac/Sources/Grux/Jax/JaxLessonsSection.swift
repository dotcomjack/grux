import SwiftUI

// JaxLessonsSection: the visible record of what Jax learned from the user's
// edits. When they revise a draft, CorrectionLearner distills the change into a durable
// lesson that shapes future drafts. This surface makes those lessons inspectable
// and recoverable: a wrong lesson is one tap from gone (CorrectionLearner.forget
// removes it from both the store and the profile), and the before/now snippets
// show exactly what changed so the lesson is auditable. Brand-filtered like
// the Drafts and Filtered sections. Every action is local and safe.
struct JaxLessonsSection: View {
    @ObservedObject private var store = CorrectionLessonStore.shared
    @ObservedObject private var brand = BrandFilter.shared

    private var shown: [CorrectionLesson] {
        store.lessons.filter { brand.scope.matches(voice: $0.brand) }
    }

    var body: some View {
        // Stay quiet when there is nothing learned for the current brand: this is
        // a secondary surface, it should not shout an empty box.
        if !shown.isEmpty {
            JaxSection(
                title: "Lessons learned", icon: "graduationcap.fill",
                tint: GruxTheme.accentPrimaryLight, count: shown.count,
                trailing: AnyView(
                    DestructiveButton(
                        "Clear all",
                        question: "Forget every correction \(UserIdentity.assistantName) has learned?",
                        detail: "These are the lessons built from your own corrections, so this "
                            + "undoes that training and \(UserIdentity.assistantName) starts making those mistakes again "
                            + "until you correct them once more. This cannot be undone.",
                        confirmLabel: "Forget all lessons"
                    ) { CorrectionLessonStore.shared.clear() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(GruxTheme.textTertiary)
                )
            ) {
                Text("What \(UserIdentity.assistantName) learned from your edits. These shape future drafts.")
                    .font(.system(size: 11.5)).foregroundStyle(GruxTheme.textTertiary)
                    .padding(.bottom, 4)
                ForEach(shown) { JaxLessonRow(item: $0) }
            }
        }
    }
}

private struct JaxLessonRow: View {
    let item: CorrectionLesson

    private let gold = Color(red: 0x8a/255, green: 0x64/255, blue: 0x20/255)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.lesson)
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(GruxTheme.textPrimary)

            HStack(spacing: 6) {
                // The roster's display text, matching the Drafts and Autonomy
                // pills two sections up the same scroll view. Rendering the raw
                // token here made one brand read as two.
                pill(BrandRoster.label(forId: item.brand), gold)
                if let category = item.category {
                    pill(category, GruxTheme.textTertiary)
                }
                Spacer()
            }

            Text("From: \(item.subject)")
                .font(.system(size: 11.5)).foregroundStyle(GruxTheme.textTertiary).lineLimit(1)

            VStack(alignment: .leading, spacing: 2) {
                Text("was: \(item.beforeSnippet)")
                    .foregroundStyle(GruxTheme.textTertiary)
                Text("now: \(item.afterSnippet)")
                    .foregroundStyle(GruxTheme.textTertiary)
            }
            .font(.system(size: 11, design: .monospaced)).lineLimit(2)

            HStack(spacing: 8) {
                Spacer()
                DestructiveButton("Delete",
                                  question: "Forget this lesson?",
                                  detail: "\(UserIdentity.assistantName) stops applying this correction and will make the "
                                      + "mistake again until you correct it once more.",
                                  confirmLabel: "Forget lesson") { CorrectionLearner.forget(item.id) }
                    .foregroundStyle(GruxTheme.destructiveRose)
            }
            .font(.system(size: 12, weight: .semibold)).padding(.top, 2)
        }
        .padding(12)
        .background(Color(red: 0x14/255, green: 0x12/255, blue: 0x0d/255))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(GruxTheme.textTertiary.opacity(0.12), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func pill(_ text: String, _ color: Color) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9.5, weight: .bold)).tracking(0.4)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(color.opacity(0.16)).foregroundStyle(color).clipShape(Capsule())
    }
}
