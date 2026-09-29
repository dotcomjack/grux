import Foundation

/// What kind of moment in a meeting one of its listed items is.
enum MeetingMoment: String, Codable, CaseIterable {
    case decision
    case commitment
    case actionItem = "action_item"
    case notSaid = "not_said"

    var label: String {
        switch self {
        case .decision: return "Decision"
        case .commitment: return "You committed"
        case .actionItem: return "Action item"
        case .notSaid: return "Not in transcript"
        }
    }
}

/// P-R-6, `meeting.moment`: which of a meeting's listed items are decisions,
/// the person's own commitments, or someone else's action items, and which the
/// transcript does not support at all.
///
/// HOW THE PIPELINE MARKS THEM TODAY, AND STILL DOES. `MeetingSummarizer` asks
/// a text model for a TL;DR and up to eight `action_items`, and that list is
/// the floor: every item it returns is kept and shown exactly as before. Jev
/// has no extraction type, so it does not find moments; it LABELS the items the
/// summarizer extracted, reading them against the transcript, which is the
/// "regex extracts, Jev scores the extraction" split from the decision record.
/// A `not_said` label is a flag for the person to check, never a deletion.
///
/// ONE call per summary: one choice question per item, the transcript as the
/// state. Stored on the record by item text, so a render never pays for it and
/// a re-summary is judged afresh. Without a key nothing is asked and nothing is
/// stored.
///
/// Calibrated 2026-09-21 against jev-latest (grux-ecosystem key), three
/// invented meetings, 15 items. The first wording ("someone else in the meeting
/// took it on or was asked to do it") labelled 14 of 15, missing a request the
/// person accepted (action_item at 0.54, below threshold, so it would have
/// shown nothing). This wording labelled 15 of 15 at 0.88 to 1.00, 341 to 415
/// ms, and a 33,000 character transcript was accepted (10,333 input tokens,
/// 560 ms) with the same six answers.
enum MeetingMomentJudgment {
    static let surface = "meeting.moment"
    static let criteria: [String: String] = [
        MeetingMoment.decision.rawValue: "the people in the meeting settled on a choice",
        MeetingMoment.commitment.rawValue: "Me, the person this transcript belongs to, said they would do it, "
            + "including when someone asked them to",
        MeetingMoment.actionItem.rawValue: "someone other than Me took it on or was given it",
        MeetingMoment.notSaid.rawValue: "nothing in the transcript says this",
    ]
    /// The summarizer lists at most eight.
    static let maxItems = 8
    /// Past this the middle of the transcript is left out, and an item judged
    /// `not_said` may simply be in the part that was left out, so that label is
    /// dropped for a clipped transcript.
    static let maxTranscriptCharacters = 40_000

    static func instructions(item: String) -> String {
        "An assistant listed this as something that came out of the meeting: \"\(item)\". "
            + "What kind of moment in the transcript is it?"
    }

    static func state(transcript: String) -> (state: String, clipped: Bool) {
        guard transcript.count > maxTranscriptCharacters else { return ("Meeting transcript:\n" + transcript, false) }
        let half = maxTranscriptCharacters / 2
        let head = String(transcript.prefix(half)), tail = String(transcript.suffix(half))
        return ("Meeting transcript:\n" + head + "\n[... the middle of the meeting is left out ...]\n" + tail, true)
    }

    /// The label for each item the provider could place at or above the
    /// threshold, keyed by the item's text. Nil when nothing was labelled.
    @MainActor
    static func judge(items: [String], transcript: String, engine: DecisionEngine,
                      threshold: Double) async -> [String: MeetingMoment]? {
        let listed = Array(items.prefix(maxItems))
        guard engine.hasRemoteKey, !listed.isEmpty,
              !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let (state, clipped) = state(transcript: transcript)
        var questions: [String: DecisionQuestion] = [:]
        for (i, item) in listed.enumerated() {
            questions["item_\(i)"] = .choice(instructions: instructions(item: item), criteria: criteria)
        }
        let result = await engine.decide(surface: surface, state: state, questions: questions)
        return moments(items: listed, answers: result.answers, provider: result.provider,
                       threshold: threshold, clipped: clipped)
    }

    static func moments(items: [String], answers: [String: DecisionAnswer], provider: DecisionProviderKind,
                        threshold: Double, clipped: Bool) -> [String: MeetingMoment]? {
        // On device a choice is keyword overlap against these descriptions,
        // which says nothing about a meeting. It labels nothing.
        guard provider != .local else { return nil }
        var out: [String: MeetingMoment] = [:]
        for (i, item) in items.enumerated() {
            guard case .choice(let pick, let confidence, _)? = answers["item_\(i)"], confidence >= threshold,
                  let moment = MeetingMoment(rawValue: pick), !(clipped && moment == .notSaid) else { continue }
            out[item] = moment
        }
        return out.isEmpty ? nil : out
    }
}
