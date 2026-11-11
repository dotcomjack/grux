import Foundation

/// Silent mode for the shell doors.
///
/// WHY. `~/.grux/SILENT` silences every sound Grux plays itself (`AudioOutput`), but a
/// command a model or a macro runs through a shell reached the speaker on its own:
/// `say hello`, `afplay chime.aiff`, `osascript -e 'tell application "Music" to play'`.
/// Every Grux shell door (ShellSession, ShellRunner) asks `refusal(for:)` before it runs a
/// command, and in silent mode a command that would make sound is refused, not run.
public enum ShellSilence {
    /// Asked before each command. Grux points it at `AudioOutput.isSilent` at launch; the
    /// default reads the sentinel itself, so a door used before (or without) that wiring
    /// is still silent.
    nonisolated(unsafe) public static var isSilent: () -> Bool = {
        sentinelNames.contains { FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.grux/" + $0) }
    }

    /// The files under `~/.grux` that each silence Grux on their own: SILENT, and
    /// HEADLESS, because a run nobody watches is a run nobody may hear (operator note 15).
    public static let sentinelNames = ["SILENT", "HEADLESS"]

    /// Which of `sentinelNames` silence Grux right now. Grux points it at its own `.grux`
    /// at launch; the default reads the person's home, as `isSilent` does.
    nonisolated(unsafe) public static var silencedBy: () -> [String] = {
        sentinelNames.filter { FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.grux/" + $0) }
    }

    /// The files that silenced Grux, as a refusal names them: " (~/.grux/HEADLESS)", or
    /// nothing when no file did (a test run). A HEADLESS-only run once read "(~/.grux/SILENT)",
    /// a file that was not there (D109).
    public static func note(_ names: [String]) -> String {
        names.isEmpty ? "" : " (\(paths(names)))"
    }

    /// What lifts silent mode, in one sentence, for the person reading a refusal.
    public static func remedy(_ names: [String]) -> String {
        guard !names.isEmpty else { return "Silent mode is off now, so the same command may run." }
        let headless = names.contains("HEADLESS") ? "; that also ends headless mode." : "."
        return "Remove \(paths(names)) to let Grux make sound again" + headless
    }

    private static func paths(_ names: [String]) -> String {
        names.map { "~/.grux/" + $0 }.joined(separator: " and ")
    }

    /// Told about each refused command (program, full command). Grux records it in
    /// `silenced.jsonl` with every other suppressed sound.
    nonisolated(unsafe) public static var onRefused: (String, String) -> Void = { _, _ in }

    /// Every refusal starts with this, so a reader can tell it from the other gates.
    public static let refusalPrefix = "refused: silent mode is on"

    /// The reason to refuse `command`, or nil when it may run.
    public static func refusal(for command: String, silent: Bool? = nil) -> String? {
        guard let program = SoundingCommand.program(in: command), silent ?? isSilent() else { return nil }
        onRefused(program, command)
        return "\(refusalPrefix)\(note(silencedBy())) and `\(program)` would make sound"
    }

    /// The same question for AppleScript source run in-process (a macro's AppleScript step).
    public static func refusal(forAppleScript source: String, silent: Bool? = nil) -> String? {
        guard SoundingCommand.appleScriptSounds(source), silent ?? isSilent() else { return nil }
        onRefused("applescript", source)
        return "\(refusalPrefix)\(note(silencedBy())) and this AppleScript would make sound"
    }
}

/// Recognizes shell commands that play sound or drive a player.
///
/// Deliberately broad: it only ever acts in silent mode, where refusing a command that
/// would have been quiet costs a retry, and running one that was not costs the silence.
public enum SoundingCommand {
    /// Programs that make sound whenever they run.
    static let players: Set<String> = [
        "afplay", "ffplay", "mpv", "mplayer", "play", "vlc", "cvlc", "mpg123", "mpg321",
        "beep", "SwitchAudioSource", "spotify",
    ]
    /// AppleScript's audio commands and the players it drives, matched as whole
    /// words. As substrings `play` and `say` refused `display dialog` and
    /// `display notification`, which make no sound (review RV9). A banner WITH
    /// a sound is `sound name`, which `sound` still matches.
    static let scriptWords = #"\b(music|spotify|itunes|volume|beep|say|play|playpause|sound)\b"#
    /// Things `open` hands to a player that starts on its own: audio and video
    /// files, the players, and the sites whose pages play on load.
    static let openTargets = [
        "-a music", "-a spotify", "-a itunes", "-a quicktime", "-a tv", "-a podcasts", "-a vlc", "-a iina",
        "music.app", "spotify.app", "quicktime player.app", "tv.app", "podcasts.app", "vlc.app", "iina.app",
        "music://", "spotify:", "itmss://", "podcasts://",
        ".mp3", ".m4a", ".wav", ".aiff", ".aif", ".aac", ".flac", ".caf", ".ogg", ".opus", ".mid",
        ".mp4", ".m4v", ".mov", ".avi", ".mkv", ".webm", ".wmv", ".flv", ".mpg", ".mpeg", ".3gp",
        "youtube.com", "youtu.be", "vimeo.com", "twitch.tv", "soundcloud.com", "open.spotify.com",
        "music.apple.com", "podcasts.apple.com", "tv.apple.com", "netflix.com", "pandora.com",
    ]
    /// Words that run the command after them: wrappers, and the shell keywords that put a
    /// command after them (`for f in *; do open "$f"; done`).
    static let wrappers: Set<String> = [
        "sudo", "env", "nohup", "exec", "command", "time", "nice", "caffeinate", "xargs", "eval", "arch",
        "do", "then", "else", "elif", "if", "while", "until", "!", "{",
    ]
    /// Shells that run the string after `-c` as a command (review RV6).
    static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "fish"]

    /// True when AppleScript source plays or controls audio.
    public static func appleScriptSounds(_ source: String) -> Bool {
        source.range(of: scriptWords, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The program in `command` that would make sound, or nil.
    public static func program(in command: String) -> String? {
        for simple in simpleCommands(command) {
            if let hit = sounding(simple) { return hit }
        }
        return nil
    }

    /// Splits on the operators that start another command: `;` `&&` `||` `|` `&`,
    /// newlines, and command or process substitution.
    static func simpleCommands(_ command: String) -> [[String]] {
        var text = command
        for sep in ["$(", "`", "<(", ">(", "&&", "||", "|", ";", "&", "\n", "(", ")", "{", "}"] {
            text = text.replacingOccurrences(of: sep, with: "\u{1}")
        }
        return text.split(separator: "\u{1}").map { part in
            part.split(whereSeparator: { $0 == " " || $0 == "\t" })
                .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
                .filter { !$0.isEmpty }
        }
    }

    /// The program a simple command runs and its arguments, past leading assignments
    /// (`VAR=value`), wrappers (`env`, `sudo`, ...) and the wrappers' flags.
    static func head(of words: [String]) -> (program: String, args: [String])? {
        var rest = words[...]
        // Skip leading assignments (`VAR=value`), wrappers and their flags.
        while let first = rest.first {
            if first.contains("=") && !first.hasPrefix("-") && !first.hasPrefix("/") {
                rest = rest.dropFirst()
            } else if first == "-arch" && rest.startIndex != words.startIndex {
                rest = rest.dropFirst(2)  // `arch -arch x86_64 open`: the flag takes a value
            } else if wrappers.contains((first as NSString).lastPathComponent)
                        || (rest.startIndex != words.startIndex && (first.hasPrefix("-") || Int(first) != nil)) {
                rest = rest.dropFirst()
            } else {
                break
            }
        }
        guard let head = rest.first else { return nil }
        return ((head as NSString).lastPathComponent, Array(rest.dropFirst()))
    }

    static func sounding(_ words: [String]) -> String? {
        guard let (program, args) = head(of: words) else { return nil }
        let tail = args.joined(separator: " ").lowercased()
        switch program {
        case _ where shells.contains(program):
            // `bash -c "say hi"`: judge the string the shell runs, however
            // deep. The quotes are already gone, so its words are the rest.
            guard let c = args.firstIndex(where: { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("c") })
            else { return nil }
            return SoundingCommand.program(in: args[(c + 1)...].joined(separator: " "))
        case "say":
            let writesFile = args.contains { $0 == "-o" || $0 == "--output-file" || $0.hasPrefix("--output-file=") }
            return writesFile ? nil : program
        case "osascript":
            return appleScriptSounds(tail) ? program : nil
        case "open":
            return openTargets.contains { tail.contains($0) } ? program : nil
        default:
            return players.contains(program) ? program : nil
        }
    }
}
