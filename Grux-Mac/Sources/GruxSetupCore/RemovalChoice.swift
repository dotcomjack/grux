import Foundation

/// Which of the rows `grux_remove` listed answer to what somebody typed.
///
/// Rows are the app's `items`: `id`, `label`, `alias` (a schedule's uuid) and `tracked`
/// (false for a remembered removal). Here rather than in the CLI because GruxCLI is an
/// executable module a test cannot import, and this decision went wrong once.
public enum RemovalChoice {

    public static func candidates(for typed: String,
                                  in rows: [[String: Any]]) -> [[String: Any]] {
        let t = typed.lowercased()
        let hits = rows.filter { row in
            ["id", "label", "alias"].contains { key in
                guard let v = row[key] as? String, !v.isEmpty else { return false }
                return v.lowercased() == t
            }
        }
        // A THING ALREADY GONE CANNOT MAKE A LIVE ONE AMBIGUOUS, the rule the app's remover
        // keeps. Re-adding a schedule under a title once removed made `grux remove schedule
        // <title>` refuse forever. Remembered rows only answer when nothing live does, so a
        // rerun of a removal still finds what it removed, and two removed things sharing
        // a title are one answer: both are already gone, so there is nothing to choose.
        let live = hits.filter { ($0["tracked"] as? Bool) ?? true }
        return live.isEmpty ? Array(hits.prefix(1)) : live
    }
}
