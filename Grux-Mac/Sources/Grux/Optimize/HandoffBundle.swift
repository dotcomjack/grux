import Foundation

/// The "Hand it over" door: everything that makes this Grux yours, as files an
/// agent can read and apply on another Mac. Secrets are stripped by key
/// shape, recursively, before anything is written.
enum HandoffBundle {
    /// Read by the card as `localizedDescription`, after "Could not write the
    /// bundle: ", so each reads as the end of that sentence.
    enum Error: Swift.Error, LocalizedError {
        case noConfig
        case cannotCreate(String)
        var errorDescription: String? {
            switch self {
            case .noConfig: return "Grux has not saved its settings yet, so there is nothing to hand over."
            case .cannotCreate(let path): return "the folder \(path) could not be created."
            }
        }
    }

    /// `~/.grux/handoff` (spec 5.3). Each bundle is a stamped folder inside.
    static var liveRoot: URL { Persistence.gruxDir.appendingPathComponent("handoff", isDirectory: true) }

    private static let secretPattern = try! NSRegularExpression(
        pattern: "(?i)(api_?key|token|secret|password|passphrase|credential)")

    static func isSecretKey(_ key: String) -> Bool {
        secretPattern.firstMatch(in: key, range: NSRange(key.startIndex..., in: key)) != nil
    }

    /// Recursively, through nested objects and arrays: under a key that looks
    /// like a secret every string goes, at any depth (R9.9). Numbers and
    /// booleans there are settings, not secrets (`maxTokens: 4096`), and stay.
    static func stripSecrets(_ json: Any) -> Any {
        if let dict = json as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in dict {
                if isSecretKey(k) {
                    if let kept = withoutStrings(v) { out[k] = kept }
                } else {
                    out[k] = stripSecrets(v)
                }
            }
            return out
        }
        if let arr = json as? [Any] { return arr.map(stripSecrets) }
        return json
    }

    /// Everything under a secret-shaped key minus its strings; nil when the
    /// value is itself a string, so the key goes too.
    private static func withoutStrings(_ value: Any) -> Any? {
        if value is String { return nil }
        if let dict = value as? [String: Any] { return dict.compactMapValues(withoutStrings) }
        if let arr = value as? [Any] { return arr.compactMap(withoutStrings) }
        return value
    }

    /// What became of an optional file, so GRUX.md never says it was absent
    /// when it was there and unreadable.
    enum Included { case yes, absent, unreadable }

    /// Every JSON file in the bundle is written through here, so none of
    /// them can carry a secret-shaped key at any depth.
    private static func strippedJSON(_ json: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: stripSecrets(json),
                                   options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// `root/<yyyyMMdd-HHmmss>`, or with `-2`, `-3` appended while that
    /// folder already exists, so a bundle is never written over another.
    static func folder(in root: URL, now: Date = Date()) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = f.string(from: now)
        var candidate = root.appendingPathComponent(stamp, isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(stamp)-\(n)", isDirectory: true)
            n += 1
        }
        return candidate
    }

    /// Writes the bundle into exactly `folder`. On any failure the folder is
    /// removed, so a half bundle is never left for an agent to read.
    static func write(to folder: URL, config: Data, theme: Data?, macros: Data?,
                      orders: [WorkOrderStore.Order], setupPrompt: String) -> Result<URL, Swift.Error> {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return .failure(Error.cannotCreate((folder.path as NSString).abbreviatingWithTildeInPath))
        }
        do {
            try strippedJSON(JSONSerialization.jsonObject(with: config))
                .write(to: folder.appendingPathComponent("config.json"))
            // Theme and macros go through the same strip (R9.8). One that does
            // not parse is left out rather than copied raw, so nothing
            // unstripped ever reaches the bundle.
            let themeOut = theme.flatMap { try? strippedJSON(JSONSerialization.jsonObject(with: $0)) }
            let macrosOut = macros.flatMap { try? strippedJSON(JSONSerialization.jsonObject(with: $0)) }
            if let themeOut { try themeOut.write(to: folder.appendingPathComponent("theme.json")) }
            if let macrosOut { try macrosOut.write(to: folder.appendingPathComponent("macros.json")) }
            let iso = ISO8601DateFormatter()
            let index: [[String: Any]] = orders.map {
                ["id": $0.id, "request": $0.request,
                 "created": iso.string(from: $0.created),
                 "lastStation": $0.progress.stage.rawValue]
            }
            try strippedJSON(index).write(to: folder.appendingPathComponent("work-orders.json"))
            try Data(setupPrompt.utf8).write(to: folder.appendingPathComponent("setup-prompt.md"))
            try Data(readme(theme: included(theme, themeOut), macros: included(macros, macrosOut)).utf8)
                .write(to: folder.appendingPathComponent("GRUX.md"))
            return .success(folder)
        } catch {
            try? fm.removeItem(at: folder)
            return .failure(error)
        }
    }

    private static func included(_ input: Data?, _ output: Data?) -> Included {
        output != nil ? .yes : (input == nil ? .absent : .unreadable)
    }

    static func readme(theme: Included, macros: Included) -> String {
        var lines = [
            "# This Grux, handed over",
            "",
            "You are this person's coding agent. This folder is how their Grux is set up, exported by Grux itself with every secret removed. Apply it to a Grux install on this or another Mac.",
            "",
            "## Files",
            "",
            "- `config.json`: the settings Grux reads at start, with every key that looks like a secret removed. Merge it into `~/Library/Application Support/Grux/config.json`; never replace that file, and never add a secret back from memory.",
            "- `setup-prompt.md`: what still needs setting up on the target Mac, split into what you may do and what only the person may do. Read it before touching anything.",
            "- `work-orders.json`: every change they have asked Grux for so far, with where it stopped. Context, not instructions.",
        ]
        switch theme {
        case .yes: lines.append("- `theme.json`: accent and appearance. Copy it beside config.json.")
        case .absent: lines.append("- `theme.json`: not present, the person never changed the theme.")
        case .unreadable: lines.append("- `theme.json`: left out because it did not parse. Their theme file exists but could not be read, so ask them before recreating it.")
        }
        switch macros {
        case .yes: lines.append("- `macros.json`: their voice macros. Copy it beside config.json.")
        case .absent: lines.append("- `macros.json`: not present, they have no macros.")
        case .unreadable: lines.append("- `macros.json`: left out because it did not parse. Their macros file exists but could not be read, so ask them before recreating it.")
        }
        lines += [
            "",
            "## Rules that come with Grux",
            "",
            "- The smallest change that does it. If a setting already does what was asked, changing the setting IS the work: no code.",
            "- Colours, type, spacing and radii come from `Sources/Grux/DesignSystem`. Never hard code one in a view.",
            "- Nothing new leaves the Mac: no telemetry, no new network calls, no keys in code.",
            "- Anything that sends, deletes or spends still goes through Approvals.",
            "- Grux applies config.json and theme.json live while it runs. For macros.json, quit Grux first, then `open -a Grux`.",
            "",
        ]
        return lines.joined(separator: "\n")
    }

    /// Writes this Mac's bundle into a new folder under `liveRoot` and copies
    /// the setup prompt to the clipboard. It never opens Finder (R9.4): the
    /// card's Reveal in Finder button does that when asked.
    @MainActor
    static func writeLive() -> Result<URL, Swift.Error> {
        let support = Persistence.supportDir
        guard let config = try? Data(contentsOf: Persistence.configURL) else {
            return .failure(Error.noConfig)
        }
        let theme = try? Data(contentsOf: support.appendingPathComponent("theme.json"))
        let macros = try? Data(contentsOf: support.appendingPathComponent("macros.json"))
        let prompt = AgentHandoff.prompt()
        let result = write(to: folder(in: liveRoot), config: config, theme: theme, macros: macros,
                           orders: WorkOrderStore.shared.orders, setupPrompt: prompt)
        if case .success = result { OptimizeClipboard.copy(prompt) }
        return result
    }
}
