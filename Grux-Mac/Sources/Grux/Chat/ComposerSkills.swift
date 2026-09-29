import Foundation

/// The skills picker in the Chat composer.
///
/// Phase C fold: Skills lost its rail row and became a picker beside the model
/// chip. A learned procedure is something you reach for while you write a
/// message, so it lives where the message is written. The whole surface came
/// with it: the picker opens the same list, with new, edit and delete, plus a
/// USE button that puts a skill in front of the draft.
enum ComposerSkills {
    /// The words a picked skill puts in front of the draft. It names the skill
    /// exactly as the LEARNED_SKILLS block in the system prompt does, so the
    /// model can match the name without a lookup. Past the twelve skills that
    /// block carries, it can still fetch the full procedure with list_skills.
    static func invocation(for skillName: String) -> String {
        "Use my \(skillName) skill: "
    }

    /// The draft after a skill is picked. The skill goes in front, and
    /// whatever the person already typed stays after it. Picking the same
    /// skill twice changes nothing.
    static func apply(_ skillName: String, to draft: String) -> String {
        let prefix = invocation(for: skillName)
        if draft.hasPrefix(prefix) { return draft }
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? prefix : prefix + typed
    }

    /// The chip's label, with the count so a person can see there is
    /// something behind it before opening it.
    static func chipLabel(count: Int) -> String {
        count == 0 ? "SKILLS" : "SKILLS \(count)"
    }
}
