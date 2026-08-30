import Foundation

// MARK: - Exit codes

/// What the shell gets back, and the third one is the one a naive design leaves out.
///
/// An agent that can only tell success from failure has to decide whether a setup that
/// succeeded and is waiting on a person counts as one or the other, and both answers are
/// wrong. `2` says "nothing failed, it is your turn". `3` says "something is broken and grux
/// doctor can probably fix it", which is a different next action again.
///
/// ## Why it lives here rather than beside `leave`
///
/// These four are the contract `docs/cli-grammar.md` publishes and an agent reads. Anything
/// that DECIDES one is product logic and has to be testable; only the part that ends the
/// process belongs to the binary. It moved out of GruxCLI the day a decision worth testing
/// appeared, which was `grux add` reporting 0 for a row it had just drawn as needed.
public enum Exit: Int32, Equatable, Sendable {
    case done = 0
    case failed = 1
    case waitingOnYou = 2
    case selfRepairAvailable = 3

    /// The code a set of "what this command touched" rows actually justifies.
    ///
    /// `grux add` ended in an unconditional done, two lines after drawing these same rows
    /// with the needed glyph and printing a note saying the thing would not work. Measured:
    /// every first-time `grux add mailbox` printed a needed Password row, said only the Grux
    /// Mailbox window could take it, said the account "will not sync" until then, and exited
    /// 0, which this surface defines as everything asked for being satisfied.
    ///
    /// FAILED AND NEEDS-A-PERSON ARE DIFFERENT CODES, which is why the app labels them
    /// rather than the caller guessing. A password only a person can paste is `2`: no
    /// invocation of the command can ever supply it. A file that would not write is `1`: the
    /// same call succeeds once the disk does. Collapsing them makes `2` useless for the one
    /// decision it exists to inform, which is whether to wake somebody up.
    ///
    /// A row missing either flag reads as fine. An absent key is not a failure, and treating
    /// it as one would break every reply written before the flags existed.
    /// How a `grux repair` run ends.
    ///
    /// REPAIRING EVERYTHING REPAIRABLE DOES NOT MAKE THE REST GO AWAY. Both run paths ended
    /// at 0 whenever nothing they touched got stuck, on a Mac where doctor had already found
    /// something only a person can fix, and neither said a word about it. An agent reads 0
    /// as "report done", so the thing nobody can automate was never surfaced.
    ///
    /// That got worse when the listing learned to exit 3, because the help then points at
    /// `--all` as the answer to a 3, and `--all` reported everything done.
    ///
    /// - Parameter stuck: repairs that ran and did not take.
    /// - Parameter unfixable: things on this Mac no repair can touch at all.
    public static func forRepair(stuck: Int, unfixable: Int) -> Exit {
        (stuck > 0 || unfixable > 0) ? .waitingOnYou : .done
    }

    public static func forWriteRows(_ rows: [[String: Any]]) -> Exit {
        if rows.contains(where: { ($0["needsPerson"] as? Bool) == true }) { return .waitingOnYou }
        if rows.contains(where: { ($0["failed"] as? Bool) == true }) { return .failed }
        return .done
    }
}
