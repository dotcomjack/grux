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
/// on it. Pulling it out with its inputs passed in makes both possible.
///
/// ## The chips come from this Mac, not from a list
///
/// The hardcoded chips are gone, first run and returning alike. "What can you
/// actually do?" and "Plan today" were the same three strings on every Mac, and
/// a stock ask is a shrug in advance. `ChatStarterChips.build` is the pure
/// function that turns this Mac's real state (an undoable command, a refusal,
/// the next meeting, the window in front, today's log, whether a local model is
/// set up) into at most three asks, and `ChatView` gathers that state while the
/// empty state is on screen and hands the result in as `chips`.
struct ChatEmptyState: View {

    /// No tasks and no prior conversation. Not "has never launched": somebody
    /// who cleared their history is, for the purposes of what Grux can usefully
    /// offer, in the same position as somebody who just installed it.
    let isFirstRun: Bool
    /// Whether the wake word listener is actually running.
    ///
    /// This copy used to tell every returning user to say "hey grux" from
    /// anywhere. `config.wakeWordEnabled` ships FALSE, and measured 2026-08-22
    /// the wake word is named ZERO times in the whole onboarding flow, so the
    /// app was instructing people to use a feature that was off and that nobody
    /// had ever told them existed. Saying it only when it is on is the whole fix.
    let wakeWordOn: Bool
    /// `ChatStarterChips.build(...).chips`, at most three. Each `ask` is sent
    /// VERBATIM as the user's first message, so these are not labels, they are
    /// utterances. Empty until the first gather lands, and then no row at all
    /// rather than a stock guess.
    let chips: [ChatStarterChips.Chip]
    let onPick: (String) -> Void

    private var headline: String {
        isFirstRun ? "Tell me what you are working on." : "Ready."
    }

    private var eyebrow: String { isFirstRun ? "FIRST RUN" : "READY" }

    /// Static and pure for the same reason `suggestions` is: the interesting
    /// half of this view is which sentence it picks, and that should be
    /// assertable without standing up SwiftUI.
    static func blurb(isFirstRun: Bool, wakeWordOn: Bool) -> String {
        if isFirstRun {
            // Leads with what Grux does on this Mac that a chat window does
            // not: a local model (Ollama and Grux Local), a snapshot before any
            // command that looks destructive (`ShellSession`, hybrid undo), and
            // the plain text log every shell command and file read lands in
            // (`fs-audit.log`, `grux history`). It used to open with the mail,
            // calendar, notes and files it could reach, which every assistant
            // claims. Then it says plainly that it knows nothing yet: an
            // assistant that implies familiarity it does not have spends trust
            // it has not earned.
            return "I can run on a local model on this Mac, snapshot a folder before a command that could wreck it so it can be undone, and keep a plain log of every command I run. I know nothing about you yet, so the fastest way to get useful is to tell me what you are building."
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
            FlowChips(items: chips.map(\.ask)) { text in
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
                .help(chips.first { $0.ask == text }?.because ?? "")
                .accessibilityHint("Sends this as your message")
            }
            .padding(.top, GruxSpacing.xs)
        }
        .padding(.vertical, GruxSpacing.m)
    }
}
