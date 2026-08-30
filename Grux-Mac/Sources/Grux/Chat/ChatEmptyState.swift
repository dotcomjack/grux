import SwiftUI

/// The first thing a new user ever reads inside Grux, and until now the one
/// screen in the app that assumed they were not new.
///
/// ## The bug this exists to fix
///
/// Chat is the default landing tab, so its empty state is the literal first
/// sentence Grux says to anybody. It offered three suggestion chips, hardcoded:
/// "What should I work on?", "Roast my task stack", "Plan today". On a fresh
/// install ALL THREE fail, and they fail quietly rather than loudly:
///
/// - there are no tasks, so "roast my task stack" roasts an empty list,
/// - there are no projects, so "what should I work on" has nothing to rank,
/// - the calendar permission has usually not been granted, so "plan today"
///   plans against nothing.
///
/// A first-run user clicks the most inviting thing on screen and Grux answers
/// with a shrug. That is the worst possible first impression for an assistant
/// whose entire pitch is that it already knows your machine, and no test covered
/// it because the empty state had no tests at all.
///
/// ## The rule this encodes
///
/// NEVER OFFER AN ACTION THAT CANNOT WORK RIGHT NOW. The app already commits to
/// this everywhere else: the setup contract says a missing capability must
/// surface as `needs-setup` in place and never as an error. A suggestion chip is
/// the same promise in a friendlier costume, so it answers to the same rule.
///
/// ## Why it is its own view
///
/// It was a private computed property on `ChatView`, which is 1000+ lines and
/// needs a live `AppState`, so nothing could render it and nothing could assert
/// on it. Pulling it out with its inputs passed in makes both possible, and
/// `suggestions(isFirstRun:hasTasks:)` is a pure function precisely so the chip
/// logic can be tested without SwiftUI at all.
struct ChatEmptyState: View {

    /// No tasks and no prior conversation. Not "has never launched": somebody
    /// who cleared their history is, for the purposes of what Grux can usefully
    /// offer, in the same position as somebody who just installed it.
    let isFirstRun: Bool
    let hasTasks: Bool
    /// Whether the wake word listener is actually running.
    ///
    /// This copy used to tell every returning user to say "hey grux" from
    /// anywhere. `config.wakeWordEnabled` ships FALSE, and measured 2026-08-22
    /// the wake word is named ZERO times in the whole onboarding flow, so the
    /// app was instructing people to use a feature that was off and that nobody
    /// had ever told them existed. Saying it only when it is on is the whole fix.
    let wakeWordOn: Bool
    let onPick: (String) -> Void

    /// The chips, as data, so the interesting half is testable.
    ///
    /// Each string is sent VERBATIM as the user's first message, so these are
    /// not labels, they are utterances. They read as something a person would
    /// actually type for that reason.
    static func suggestions(isFirstRun: Bool, hasTasks: Bool) -> [String] {
        if isFirstRun {
            // All three work against a machine Grux knows nothing about, and all
            // three move the user toward operating rather than chatting.
            return ["What can you actually do?",
                    "Help me plan my first project",
                    "What should I set up first?"]
        }
        var out = ["What should I work on?", "Plan today"]
        // Only offered when there is a stack to roast. This is the whole fix in
        // one line: the chip is absent rather than disappointing.
        if hasTasks { out.insert("Roast my task stack", at: 1) }
        return out
    }

    private var headline: String {
        isFirstRun ? "Tell me what you are working on." : "Ready."
    }

    private var eyebrow: String { isFirstRun ? "FIRST RUN" : "READY" }

    /// Static and pure for the same reason `suggestions` is: the interesting
    /// half of this view is which sentence it picks, and that should be
    /// assertable without standing up SwiftUI.
    static func blurb(isFirstRun: Bool, wakeWordOn: Bool) -> String {
        if isFirstRun {
            // Says plainly that it knows nothing yet. An assistant that opens by
            // implying familiarity it does not have spends trust it has not
            // earned, and the first wrong answer collects on it.
            return "I read the window you are in, and I can reach the mail, calendar, notes and files already on this Mac. I know nothing about you yet, so the fastest way to get useful is to tell me what you are building."
        }
        if wakeWordOn {
            // THE PHRASE IS THE APP'S NAME, NOT THE ASSISTANT'S, and this line
            // got that wrong. It read `assistantName`, which defaults to "Jax",
            // so it told every user out of the box to say "hey jax" at a
            // listener whose regex only matches "gr" plus vowels. Wrong for
            // everyone, not only for somebody who had renamed anything.
            return "Ask what to work on, nudge me when you drift, or say \"\(WakeWordListener.spokenPhrase)\" from anywhere."
        }
        return "Ask what to work on, or nudge me when you drift."
    }

    private var blurb: String {
        Self.blurb(isFirstRun: isFirstRun, wakeWordOn: wakeWordOn)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: GruxSpacing.s) {
            Text(eyebrow)
                .font(GruxTheme.Font.microCaps)
                .kerning(3.5)
                .foregroundStyle(GruxTheme.iridescent)
            Text(headline)
                .font(GruxTheme.Font.display)
                .foregroundStyle(GruxTheme.textPrimary)
            Text(blurb)
                .font(.callout)
                .foregroundStyle(GruxTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            // Reuses the module's existing Layout-based flow, so chips wrap
            // instead of running past the pane at the 840pt window floor. The
            // old row was a plain HStack of three, and the third was
            // unreachable there.
            FlowChips(items: Self.suggestions(isFirstRun: isFirstRun, hasTasks: hasTasks)) { text in
                Button { onPick(text) } label: {
                    Text(text)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(GruxTheme.textPrimary)
                        .padding(.horizontal, GruxSpacing.m)
                        .padding(.vertical, GruxSpacing.xs + 2)
                        .background(
                            Capsule().fill(Color.white.opacity(0.05))
                                .overlay(Capsule().strokeBorder(GruxTheme.accentPrimary.opacity(0.35),
                                                                lineWidth: 0.8))
                        )
                }
                .buttonStyle(.plain)
                .accessibilityHint("Sends this as your message")
            }
            .padding(.top, GruxSpacing.xs)
        }
        .padding(.vertical, GruxSpacing.m)
    }
}
