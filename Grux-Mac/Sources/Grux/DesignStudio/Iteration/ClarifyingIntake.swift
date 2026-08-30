import SwiftUI

// ClarifyingIntake: the turn-1 clarifying form. A vague brief ("make me a landing
// page") produces a vague design, and a full regeneration to fix it is expensive.
// So when the brief is genuinely underspecified, Grux asks a FEW pointed questions
// BEFORE spending a run, and prefills the answers it can already infer from the
// brand's design system so the user answers two things, not eight.
//
// The trigger is ConfidenceGate.assessGroundedHeuristic (nonisolated, free, no
// model): the exact same "never guess on true confusion" heuristic the chat path
// uses. When it reports the brief is already clear, the intake is skipped entirely
// and generation proceeds. Otherwise up to four questions are surfaced, with
// audience and voice prefilled from the design system's brand and voice sections.
//
// House style: pure/nonisolated question builder for tests, a compact SwiftUI form
// (GruxFormSection styling) for the UI, zero em/en dashes, dollars as $N.

// MARK: - IntakeQuestion

struct IntakeQuestion: Identifiable, Hashable, Sendable {
    let id: String
    let question: String
    var prefill: String
}

// MARK: - ClarifyingIntake

enum ClarifyingIntake {

    // Build the intake questions for a brief. Returns [] when the heuristic says
    // the brief is already clear (skip the intake, generate now). At most four
    // questions; audience and voice are prefilled from the design system so the
    // form is short.
    nonisolated static func questions(brief: String,
                                      brandSlug: String?,
                                      designSystemMarkdown: String?) -> [IntakeQuestion] {
        let ctx = ConfidenceContext(brand: brandSlug)
        let verdict = ConfidenceGate.assessGroundedHeuristic(prompt: brief, context: ctx)

        // Clear enough to act on: skip the intake entirely.
        if !verdict.isTrulyConfused && verdict.confidence >= ConfidenceGate.clearCeiling {
            return []
        }

        let audience = extractSection(keys: ["audience", "who it is for", "who it's for", "target user", "target"], from: designSystemMarkdown)
        let voice = extractSection(keys: ["voice", "tone"], from: designSystemMarkdown)

        let all: [IntakeQuestion] = [
            IntakeQuestion(id: "audience", question: "Who is the primary audience?", prefill: audience),
            IntakeQuestion(id: "action", question: "What single action or outcome should this drive?", prefill: ""),
            IntakeQuestion(id: "voice", question: "What tone or voice should it carry?", prefill: voice),
            IntakeQuestion(id: "must", question: "Anything that must appear (headline, product, proof)?", prefill: "")
        ]
        return Array(all.prefix(4))
    }

    // Merge the brief with the answered questions into an enriched brief. Empty
    // answers are dropped so a skipped question does not add noise. Pure + testable.
    nonisolated static func enrichedBrief(brief: String,
                                          answers: [(question: String, answer: String)]) -> String {
        let filled = answers.filter { !$0.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !filled.isEmpty else { return brief }
        var s = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        s += "\n\nAdditional context:\n"
        s += filled.map { "- \($0.question) \($0.answer.trimmingCharacters(in: .whitespacesAndNewlines))" }
            .joined(separator: "\n")
        return s
    }

    // Pull the text following a heading or "Label: value" line whose label matches
    // one of the keys. Returns the value, or the next non-empty line, capped for a
    // prefill. Empty when nothing matches, so the question shows unprefilled.
    nonisolated static func extractSection(keys: [String], from md: String?) -> String {
        guard let md, !md.isEmpty else { return "" }
        let lines = md.components(separatedBy: .newlines)
        for (idx, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let lower = line.lowercased()
            guard keys.contains(where: { lower.contains($0) }) else { continue }
            // "Label: value" on the same line.
            if let colon = line.firstIndex(of: ":") {
                let after = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                let cleaned = stripHeadingMarks(after)
                if !cleaned.isEmpty { return cap(cleaned) }
            }
            // Otherwise the next non-empty line (a heading followed by its body).
            var j = idx + 1
            while j < lines.count {
                let next = stripHeadingMarks(lines[j].trimmingCharacters(in: .whitespaces))
                if !next.isEmpty { return cap(next) }
                j += 1
            }
        }
        return ""
    }

    // Strip leading markdown heading hashes, list bullets, and bold markers.
    nonisolated private static func stripHeadingMarks(_ s: String) -> String {
        var out = s
        while let first = out.first, first == "#" || first == "-" || first == "*" || first == ">" || first == " " {
            out.removeFirst()
        }
        out = out.replacingOccurrences(of: "**", with: "")
        return out.trimmingCharacters(in: .whitespaces)
    }

    nonisolated private static func cap(_ s: String, _ n: Int = 140) -> String {
        s.count <= n ? s : String(s.prefix(n)).trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - DesignIntakeFormView

// The compact turn-1 form. Renders each question in a GruxFormSection, prefilled,
// and hands the caller an enriched brief on submit. Skips rendering when there are
// no questions (the caller should already have skipped it, but this is defensive).
struct DesignIntakeFormView: View {
    let brief: String
    let questions: [IntakeQuestion]
    var onSubmit: (String) -> Void

    @State private var answers: [String: String]

    init(brief: String, questions: [IntakeQuestion], onSubmit: @escaping (String) -> Void) {
        self.brief = brief
        self.questions = questions
        self.onSubmit = onSubmit
        _answers = State(initialValue: Dictionary(uniqueKeysWithValues: questions.map { ($0.id, $0.prefill) }))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: GruxSpacing.l) {
            VStack(alignment: .leading, spacing: GruxSpacing.xs) {
                Text("A couple of quick questions")
                    .font(GruxType.title)
                    .foregroundStyle(GruxTheme.textPrimary)
                Text("Prefilled from the brand where I could. Tweak or accept, then continue.")
                    .font(GruxType.caption)
                    .foregroundStyle(GruxTheme.textTertiary)
            }

            ForEach(questions) { q in
                GruxFormSection(q.question) {
                    TextField("", text: binding(for: q.id), axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(GruxType.body)
                        .foregroundStyle(GruxTheme.textPrimary)
                        .lineLimit(1...3)
                        .padding(.vertical, GruxSpacing.xs)
                        .padding(.horizontal, GruxSpacing.s)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.white.opacity(0.05))
                        )
                }
            }

            HStack {
                Spacer()
                Button {
                    let pairs = questions.map { q in (question: q.question, answer: answers[q.id] ?? "") }
                    onSubmit(ClarifyingIntake.enrichedBrief(brief: brief, answers: pairs))
                } label: {
                    Text("Continue")
                        .font(GruxType.body)
                        .padding(.horizontal, GruxSpacing.s)
                }
                .buttonStyle(.borderedProminent)
                .tint(GruxTheme.accentPrimary)
            }
        }
        .padding(GruxSpacing.l)
        .frame(maxWidth: 520, alignment: .leading)
    }

    private func binding(for id: String) -> Binding<String> {
        Binding(get: { answers[id] ?? "" }, set: { answers[id] = $0 })
    }
}
