import Foundation

/// D193: one "Run a deep research report on the history of espresso machines."
/// on grux-local:2b called `deep_research` with the same question on five hops
/// in a row. Each call came back "pending: ... waiting for your OK in
/// Approvals", the model asked again, and Approvals held five identical cards
/// for one ask (Home read "7 approvals waiting").
///
/// Within one turn, a later hop that repeats a call (same tool, same input)
/// which an earlier hop already sent to Approvals is not dispatched again: the
/// model is told it is already waiting. Two identical calls in the SAME hop are
/// left alone, because the model asked for both at once and two identical
/// messages may be meant twice (D46). A hop made only of such repeats ends the
/// turn, since nothing new can come of it.
///
/// D209: "Can you remember that I prefer short answers?" on grux-local:2b saved
/// the same fact and the same slang term on five hops in a row (ten seconds)
/// because every "ok: saved" made it save again. A later hop's repeat of a write
/// that already succeeded this turn is folded the same way: it is not done
/// twice, and the model is told it is done.
struct RepeatedPendingCalls {
    /// What the model reads in place of a second card.
    static let repeatResult = "pending: this is already waiting for your OK in Approvals from earlier in this turn, so no second request was made. Do not call it again; tell the person it is waiting."
    /// What the model reads in place of doing a finished write a second time.
    static let doneResult = "ok: this was already done earlier in this turn, so it was not done again. Do not call it again; tell the person it is done."

    private var waitingFromEarlierHops: Set<String> = []
    private var waitingThisHop: Set<String> = []
    private var doneFromEarlierHops: Set<String> = []
    private var doneThisHop: Set<String> = []
    private var callsThisHop = 0
    private var repeatsThisHop = 0

    /// The same call, written the same way whatever order its keys came in.
    /// Nil for an input that is not plain JSON: such a call is never folded.
    static func key(tool: String, input: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(input),
              let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]) else { return nil }
        return tool + "\u{1F}" + String(decoding: data, as: UTF8.self)
    }

    /// True when this call repeats one an earlier hop of this turn sent to
    /// Approvals or already did; the caller then answers with `foldedResult`
    /// and dispatches nothing.
    mutating func isRepeat(tool: String, input: [String: Any]) -> Bool {
        callsThisHop += 1
        guard let key = Self.key(tool: tool, input: input),
              waitingFromEarlierHops.contains(key) || doneFromEarlierHops.contains(key) else { return false }
        repeatsThisHop += 1
        return true
    }

    /// What the model reads for a call `isRepeat` folded.
    func foldedResult(tool: String, input: [String: Any]) -> String {
        guard let key = Self.key(tool: tool, input: input), !waitingFromEarlierHops.contains(key),
              doneFromEarlierHops.contains(key) else { return Self.repeatResult }
        return Self.doneResult
    }

    /// Notes a dispatched call's result. Only a write counts, one that waits or
    /// one that was done, by the same tests `ToolReplyCopy` and `ActionClaimGuard`
    /// use: a read whose text starts "pending:" is the person's own text, and a
    /// refused or failed write runs again when asked again.
    mutating func record(tool: String, input: [String: Any], result: String) {
        guard !ActionClaimGuard.readOnlyTools.contains(tool), let key = Self.key(tool: tool, input: input) else { return }
        if result.lowercased().hasPrefix("pending:") {
            waitingThisHop.insert(key)
        } else if ActionClaimGuard.completed(result) {
            doneThisHop.insert(key)
        }
    }

    /// Closes a hop. True when every call in it was a repeat, so the turn ends.
    mutating func closeHop() -> Bool {
        let onlyRepeats = callsThisHop > 0 && repeatsThisHop == callsThisHop
        waitingFromEarlierHops.formUnion(waitingThisHop)
        waitingThisHop = []
        doneFromEarlierHops.formUnion(doneThisHop)
        doneThisHop = []
        callsThisHop = 0
        repeatsThisHop = 0
        return onlyRepeats
    }
}
