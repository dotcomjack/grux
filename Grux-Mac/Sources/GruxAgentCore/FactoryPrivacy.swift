import Foundation

/// What this guards: text that LEAVES the Mac. DaytonaFactory.score and
/// FactoryWave run it on a job's payload (the diff, the score command, the
/// env values) before a remote Linux sandbox clones the public repo and
/// applies the diff. Its one job is that no personal path, personal data or
/// key shape appears in that text, and scanning the text is the right layer
/// for that.
///
/// Out of scope: a path the payload assembles at runtime
/// (`p=.; cat ~/.grux/factory/$p$p/mail`). It resolves inside the sandbox,
/// which holds no personal files, so it reads nothing personal. The quoting,
/// continuation and traversal rules deliberately over-refuse rather than
/// model the shell.
///
/// Not a sandbox: a future caller that executes a payload LOCALLY must not
/// rely on this check for filesystem confinement.
public enum FactoryPrivacy {
    public enum Verdict: Equatable, Sendable {
        case allow
        case refuse(String)
    }

    /// Refuse a diff, a score command, or an env value that names a personal
    /// path or a key shape. The reason is `banned-path`, `grux-path-traversal`
    /// or `key-shape`.
    /// The matched text is never returned.
    public static func check(diff: String, scoreCommand: String, env: [String: String]) -> Verdict {
        let blobs = [diff, scoreCommand] + Array(env.values)
        for blob in blobs {
            if let verdict = scan(withoutShellQuoting(blob)) {
                return verdict
            }
        }
        return .allow
    }

    private static let keyNeedles = ["sk-", "dtn_", "rsk_"]
    private static let pathNeedles = [
        "~/Library/Mail",
        "~/Library/Calendars",
        "~/Library/Messages",
        // The private worktree, matched by its tail so the source names no home
        // path. Every spelling of the full path contains it.
        ".worktrees/grux-rc41",
    ]

    /// The text as the shell joins it: a backslash newline (LF or CRLF) goes
    /// with nothing in its place, then the quoting comes out: `'`, `"`, `\`,
    /// and the `$` that opens a `$'...'` or `$"..."` quote. Quoting changes
    /// how the shell reads a word, not the path it names, so `'/Users/a'/.grux`
    /// and `"$HOME"'/.grux'` are judged as the path. No needle holds one of
    /// these characters, so anything the raw text matched, this text matches too.
    static func withoutShellQuoting(_ text: String) -> String {
        // The join is context-free (it joins inside single quotes too), which
        // can only over-refuse.
        text.replacingOccurrences(of: "\\\r\n", with: "")
            .replacingOccurrences(of: "\\\n", with: "")
            .replacingOccurrences(of: "$'", with: "'")
            .replacingOccurrences(of: "$\"", with: "\"")
            .filter { $0 != "'" && $0 != "\"" && $0 != "\\" }
    }

    private static func scan(_ text: String) -> Verdict? {
        for needle in keyNeedles where text.contains(needle) {
            return .refuse("key-shape")
        }
        for needle in pathNeedles where text.contains(needle) {
            return .refuse("banned-path")
        }
        // Fail closed: a job that names the support tree and holds `..`
        // anywhere is refused, however the path is spelled, split or spread
        // over statements. A factory diff has no reason to do both.
        if text.contains(".grux"), text.contains("..") {
            return .refuse("grux-path-traversal")
        }
        if namesPrivateGruxPath(text) {
            return .refuse("banned-path")
        }
        return nil
    }

    /// Each occurrence is judged on its own, so one factory path cannot clear
    /// a private one beside it. Only the factory folder is allowed, and a `..`
    /// cannot climb out of it.
    private static func namesPrivateGruxPath(_ text: String) -> Bool {
        // Every spelling of the Grux support tree, on unquoted text: `~` or
        // `~name` where the shell expands it (a word start: the start of the
        // text, after whitespace, `=`, `:`, a shell operator or brace, or a
        // diff line's `+` or `-`), `$HOME` or `${HOME}`, or a home folder
        // (a space in it was quoted), then `.grux`, then the rest of that path
        // up to the next word break. Accepted, in the safe direction: the home
        // folder alternative can span prose ("outside /Users/Shared, keep it
        // out of ~/.grux/mail" is refused), and `!` is not a word start.
        let gruxPath = try! NSRegularExpression(
            pattern: #"(?:(?<![^\s=:()<>;|&{},`+-])~[A-Za-z0-9_.-]*|\$HOME|\$\{HOME\}|/[U]sers/[^/\n]+)/\.grux(?=$|[/\s;|&<>(){},`])([^\s;|&<>(){},`]*)"#)
        let all = NSRange(text.startIndex..., in: text)
        for match in gruxPath.matches(in: text, range: all) {
            guard let tail = Range(match.range(at: 1), in: text) else { return true }
            let parts = text[tail].split(separator: "/")
            if parts.first != "factory" || parts.contains("..") {
                return true
            }
        }
        return false
    }
}
