import SwiftUI

// Manage learned skills: the procedures Claude saved via save_skill.
// The user can review, hand-edit, add, and delete them here. Tight scale,
// GruxTheme tokens throughout.
//
// It renders inside the Chat composer now (Phase C fold), where `onUse` puts a
// skill in front of the message being written.
struct SkillsView: View {
    @ObservedObject var store: SkillStore
    /// What USE does. Nil hides the button, for a host with no draft to use it in.
    let onUse: ((Skill) -> Void)?
    @State private var editorState: SkillEditorState? = nil
    @State private var expanded: Set<UUID> = []

    /// A nil store means the shared one. It is resolved in here rather than as
    /// a default argument, because a default argument is evaluated outside the
    /// main actor that owns the shared store.
    @MainActor
    init(store: SkillStore? = nil, onUse: ((Skill) -> Void)? = nil) {
        self.store = store ?? .shared
        self.onUse = onUse
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.25)
            if store.skills.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: GruxSpacing.s) {
                        ForEach(store.skills) { skill in
                            skillRow(skill)
                        }
                    }
                    .padding(GruxSpacing.m)
                }
            }
        }
        .sheet(item: $editorState) { state in
            SkillEditorSheet(state: state) { name, trigger, procedure in
                store.upsert(name: name, trigger: trigger, procedure: procedure)
            }
        }
    }

    /// The empty state's copy, static so it can be asserted on, and following
    /// the configured assistant name for the same reason the task stack does:
    /// the sentence describes what the ASSISTANT does with a saved procedure,
    /// and a hardcoded name describes somebody else's assistant the moment a
    /// user renames theirs.
    ///
    /// It names BOTH ways in. The chat route is the interesting one and was the
    /// only one stated, so a reader with no idea what to say in chat had nothing
    /// left to try, while the button that writes one by hand was on screen the
    /// whole time.
    static func emptyCopy(assistantName: String) -> (line: String, detail: String) {
        ("No skills yet",
         "Teach \(assistantName) a workflow in chat (\"next time, do it like this\") and the procedure is saved here. "
         + "Or write one yourself with NEW SKILL above.")
    }

    private var header: some View {
        GruxToolbar("Skills",
                    subtitle: "\(store.skills.count) learned procedure\(store.skills.count == 1 ? "" : "s") \(UserIdentity.assistantName) applies when their trigger matches") {
            Spacer()
            GruxChip(title: "NEW SKILL", systemImage: "plus", style: .primary) {
                editorState = SkillEditorState()
            }
        }
    }

    private var emptyState: some View {
        let copy = Self.emptyCopy(assistantName: UserIdentity.assistantName)
        return GruxEmptyState(
            icon: "graduationcap.fill",
            line: copy.line,
            detail: copy.detail,
            // The WAKE PHRASE, which is the app's name and never the
            // assistant's. Spoken input reaches the listener before anything
            // knows what the assistant is called.
            voiceHint: "Grux, next time do it like this..."
        )
    }

    private func skillTitle(_ skill: Skill, isExpanded: Bool) -> some View {
        HStack(spacing: GruxSpacing.s) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(GruxTheme.textTertiary)
            Text(skill.name)
                .font(GruxType.body)
                .foregroundStyle(GruxTheme.textPrimary)
            Text("\(skill.usageCount)x")
                .font(GruxType.microCaps)
                .foregroundStyle(GruxTheme.textTertiary)
                .padding(.horizontal, GruxSpacing.xs + 2).padding(.vertical, 2)
                .background(Capsule().fill(Color.white.opacity(0.06)))
        }
    }

    private func skillActions(_ skill: Skill) -> some View {
        HStack(spacing: GruxSpacing.s) {
            if let onUse {
                GruxChip(title: "USE", style: .primary) { onUse(skill) }
                    .help("Put this skill in front of your message")
            }
            GruxChip(title: "EDIT", style: .secondary) {
                editorState = SkillEditorState(skill: skill)
            }
            GruxChip(title: "DELETE", style: .destructive) {
                store.remove(skill.id)
            }
        }
    }

    private func skillRow(_ skill: Skill) -> some View {
        let isExpanded = expanded.contains(skill.id)
        return VStack(alignment: .leading, spacing: GruxSpacing.xs + 2) {
            // Measured in the Chat composer at the 840pt window floor, where
            // the conversation column is about 390pt: one line wrapped the
            // name onto three lines and cut DELETE to "DELE...". When the row
            // does not fit on one line, the buttons drop under the name.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: GruxSpacing.s) {
                    skillTitle(skill, isExpanded: isExpanded)
                    Spacer()
                    skillActions(skill)
                }
                VStack(alignment: .leading, spacing: GruxSpacing.xs + 2) {
                    skillTitle(skill, isExpanded: isExpanded)
                    skillActions(skill)
                        .padding(.leading, 17)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if isExpanded { expanded.remove(skill.id) } else { expanded.insert(skill.id) }
            }

            Text(skill.trigger)
                .font(GruxType.caption)
                .foregroundStyle(GruxTheme.textSecondary)
                .padding(.leading, 17)

            if isExpanded {
                Text(skill.procedure)
                    .font(GruxType.mono)
                    .foregroundStyle(GruxTheme.textSecondary)
                    .textSelection(.enabled)
                    .padding(GruxSpacing.s)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: GruxTheme.Radius.chip, style: .continuous)
                            .fill(Color.black.opacity(0.25))
                    )
                    .padding(.leading, 17)
            }
        }
        .padding(GruxSpacing.m)
        .background(
            RoundedRectangle(cornerRadius: GruxTheme.Radius.card, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: GruxTheme.Radius.card, style: .continuous)
                .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
        )
    }
}

// Identifiable wrapper so .sheet(item:) drives both "new" and "edit".
private struct SkillEditorState: Identifiable {
    let id = UUID()
    var name: String = ""
    var trigger: String = ""
    var procedure: String = ""

    init() {}
    init(skill: Skill) {
        self.name = skill.name
        self.trigger = skill.trigger
        self.procedure = skill.procedure
    }
}

private struct SkillEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var state: SkillEditorState
    let onSave: (String, String, String) -> Void

    private var canSave: Bool {
        !state.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !state.trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !state.procedure.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: GruxSpacing.m) {
            Text(state.name.isEmpty ? "New skill" : "Edit skill")
                .font(GruxType.title)
                .foregroundStyle(GruxTheme.textPrimary)

            field("NAME") {
                TextField("kebab-case handle, e.g. ship-release-notes", text: $state.name)
                    .textFieldStyle(.plain)
            }
            field("TRIGGER") {
                TextField("when should Grux apply this?", text: $state.trigger)
                    .textFieldStyle(.plain)
            }

            GruxSectionLabel("PROCEDURE")
            TextEditor(text: $state.procedure)
                .font(GruxType.mono)
                .scrollContentBackground(.hidden)
                .padding(GruxSpacing.s)
                .frame(minHeight: 140)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.black.opacity(0.25))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                )

            HStack {
                Spacer()
                GruxChip(title: "CANCEL", style: .secondary) { dismiss() }
                GruxChip(title: "SAVE", systemImage: "checkmark", style: .primary) {
                    guard canSave else { return }
                    onSave(state.name, state.trigger, state.procedure)
                    dismiss()
                }
                .opacity(canSave ? 1 : 0.4)
            }
        }
        .padding(GruxSpacing.l)
        // A sheet is bounded by the window it hangs off, so a hard 460 is a
        // demand the small window cannot meet: SwiftUI centres a child that is
        // too big, so it bleeds off the LEFT and the right at once. 460 stays
        // the ideal and only the bounds are new, so the sheet renders exactly
        // as it does today and shrinks toward sheetMin instead of clipping.
        .frame(minWidth: GruxLayout.sheetMin,
               idealWidth: 460,
               maxWidth: GruxLayout.sheetMax)
        // Height ceiling because the PROCEDURE editor grows with the text in
        // it and SAVE is the row underneath. Past the window's edge that
        // button is unreachable, not just ugly, since the sheet has no scroll
        // of its own. Capped, the editor gives way first (down to its own
        // 140pt floor, scrolling its content the way a TextEditor already
        // does) and SAVE stays on screen.
        .frame(maxHeight: GruxLayout.sheetMaxHeight)
        .background(GruxTheme.base)
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: GruxSpacing.xs) {
            GruxSectionLabel(label)
            content()
                .font(GruxType.body)
                .foregroundStyle(GruxTheme.textPrimary)
                .padding(.horizontal, GruxSpacing.m).padding(.vertical, GruxSpacing.s)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.black.opacity(0.25))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                )
        }
    }
}
