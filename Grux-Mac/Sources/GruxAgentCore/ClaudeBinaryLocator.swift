import Foundation

// ONE ANSWER TO "WHERE IS claude". AccountSwitcher (is it installed, sign in),
// SwarmWorker (spawn) and ClaudeCodeAdapter (detection) each kept their own copy
// of the same five paths, and all five miss an install made with npm under a node
// version manager. A GUI launch gets launchd's bare PATH, so the Agents pane said
// "not found at any location Grux checks" on a Mac where `claude` ran fine in
// Terminal.
public enum ClaudeBinaryLocator {

    // Fixed locations first, in the order the three callers always used, then the
    // folders `npm install -g` writes to under nvm (newest node first), Volta, and an
    // npm prefix of ~/.npm-global.
    public static func candidatePaths(home: String) -> [String] {
        [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "/usr/bin/claude"
        ]
        + nvmNodeFolders(home: home).map { "\($0)/bin/claude" }
        + [
            "\(home)/.volta/bin/claude",
            "\(home)/.npm-global/bin/claude"
        ]
    }

    // ~/.nvm/versions/node/v<major>.<minor>.<patch>, newest first by number, so v22
    // sorts above v9 the way a person means it.
    static func nvmNodeFolders(home: String) -> [String] {
        let root = "\(home)/.nvm/versions/node"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        func version(_ name: String) -> [Int] {
            name.drop { $0 == "v" }.split(separator: ".").map { Int($0) ?? 0 }
        }
        return names
            .filter { $0.hasPrefix("v") }
            .sorted { version($1).lexicographicallyPrecedes(version($0)) }
            .map { "\(root)/\($0)" }
    }

    // $CLAUDE_BIN when it points at a real binary, then the candidates. nil means
    // there is genuinely none.
    public static func locate(
        home: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        let fm = FileManager.default
        if let env = environment["CLAUDE_BIN"], !env.isEmpty, fm.isExecutableFile(atPath: env) {
            return env
        }
        return candidatePaths(home: home).first { fm.isExecutableFile(atPath: $0) }
    }

    // PATH for spawning `binary`: its own folder first when that is not already on
    // it. A JS build of the CLI runs through `#!/usr/bin/env node`, and under a
    // version manager that node sits beside it, not on launchd's PATH.
    public static func spawnPATH(for binary: String, base: String) -> String {
        guard binary.contains("/") else { return base }
        let dir = (binary as NSString).deletingLastPathComponent
        if base.split(separator: ":").contains(Substring(dir)) { return base }
        return base.isEmpty ? dir : "\(dir):\(base)"
    }
}
