import AppKit
import Foundation

// Voice/chat-driven Mac application launching.
//
// Catalog is built once at startup by scanning /Applications, ~/Applications,
// /System/Applications (+ /System/Applications/Utilities). Cached in memory;
// rescan() is cheap and called if a fuzzy match misses (e.g., the user just
// installed something this session).
//
// Scope: launch + bring-to-front only. Quitting apps risks losing unsaved
// work - out of scope; add later as a separate tool if the user asks.

struct AppCatalogEntry {
    let name: String          // "Logic Pro"
    let bundleId: String      // "com.apple.logic10"
    let url: URL              // /Applications/Logic Pro.app
}

@MainActor
final class AppCatalog {
    static let shared = AppCatalog()

    private(set) var entries: [AppCatalogEntry] = []
    private var built = false

    private let roots: [URL] = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            URL(fileURLWithPath: "/Applications"),
            home.appendingPathComponent("Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities")
        ]
    }()

    // Apps outside normal roots that a user will reasonably want to launch by
    // name. Finder is the big one - it lives in /System/Library/CoreServices
    // and we don't want to scan that directory broadly (it's full of
    // background daemons like loginwindow, Dock, SystemUIServer).
    private let extraPaths: [URL] = [
        URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
    ]

    func buildIfNeeded() {
        guard !built else { return }
        rescan()
    }

    func rescan() {
        var found: [AppCatalogEntry] = []
        var seenBundles = Set<String>()
        for root in roots {
            collect(from: root, into: &found, seenBundles: &seenBundles, depth: 0)
        }
        for appURL in extraPaths {
            if let bundle = Bundle(url: appURL), let bid = bundle.bundleIdentifier, !seenBundles.contains(bid) {
                seenBundles.insert(bid)
                let name = bundle.infoDictionary?["CFBundleName"] as? String
                    ?? bundle.infoDictionary?["CFBundleDisplayName"] as? String
                    ?? appURL.deletingPathExtension().lastPathComponent
                found.append(AppCatalogEntry(name: name, bundleId: bid, url: appURL))
            }
        }
        // Sort for deterministic fuzzy-match tie-breaks (alphabetical).
        found.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        entries = found
        built = true
        WakeLog.shared.log("app-catalog: \(entries.count) apps indexed")
    }

    private func collect(from root: URL, into out: inout [AppCatalogEntry], seenBundles: inout Set<String>, depth: Int) {
        guard depth <= 2 else { return }
        guard let items = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return }
        for url in items {
            if url.pathExtension == "app" {
                guard let bundle = Bundle(url: url), let bid = bundle.bundleIdentifier else { continue }
                if seenBundles.contains(bid) { continue }
                seenBundles.insert(bid)
                let name = bundle.infoDictionary?["CFBundleName"] as? String
                    ?? bundle.infoDictionary?["CFBundleDisplayName"] as? String
                    ?? url.deletingPathExtension().lastPathComponent
                out.append(AppCatalogEntry(name: name, bundleId: bid, url: url))
            } else {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                    collect(from: url, into: &out, seenBundles: &seenBundles, depth: depth + 1)
                }
            }
        }
    }

    // Fuzzy-match priority: (1) exact case-insensitive name, (2) case-insensitive
    // prefix, (3) substring on either side, (4) token overlap. Returns the
    // single best candidate, or nil.
    func match(_ query: String) -> AppCatalogEntry? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return nil }

        if let hit = entries.first(where: { $0.name.lowercased() == q }) { return hit }
        if let hit = entries.first(where: { $0.name.lowercased().hasPrefix(q) }) { return hit }
        if let hit = entries.first(where: { $0.name.lowercased().contains(q) || q.contains($0.name.lowercased()) }) { return hit }

        // Token overlap (handles "logic" → "Logic Pro", "activity monitor" → "Activity Monitor"
        // even when the user omits one word, and "visual studio code" variations).
        let qTokens = q.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count >= 2 }
        guard !qTokens.isEmpty else { return nil }

        var best: (entry: AppCatalogEntry, score: Double)?
        for entry in entries {
            let nameLower = entry.name.lowercased()
            let nameTokens = nameLower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            guard !nameTokens.isEmpty else { continue }
            let hits = qTokens.filter { qt in nameTokens.contains(where: { $0.hasPrefix(qt) || qt.hasPrefix($0) }) }.count
            guard hits > 0 else { continue }
            let score = Double(hits) / Double(max(qTokens.count, nameTokens.count))
            if score >= 0.5 {
                if best == nil || score > best!.score {
                    best = (entry, score)
                }
            }
        }
        return best?.entry
    }
}

@MainActor
enum AppLauncherTool {
    // Returns a short human-readable status string (tool_result payload).
    static func open(name rawName: String) async -> String {
        let query = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return "error: empty app name" }

        AppCatalog.shared.buildIfNeeded()
        var hit = AppCatalog.shared.match(query)

        // Miss? Rebuild once and try again - the user may have installed the app
        // mid-session.
        if hit == nil {
            AppCatalog.shared.rescan()
            hit = AppCatalog.shared.match(query)
        }
        guard let entry = hit else {
            return "error: no app matched '\(query)' in /Applications, ~/Applications, or /System/Applications"
        }

        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        return await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            NSWorkspace.shared.openApplication(at: entry.url, configuration: config) { runningApp, error in
                if let error {
                    cont.resume(returning: "error: couldn't launch \(entry.name) - \(error.localizedDescription)")
                    return
                }
                let wasRunning = (runningApp?.launchDate ?? Date()) < Date().addingTimeInterval(-1.5)
                let verb = wasRunning ? "switched to" : "launched"
                cont.resume(returning: "ok: \(verb) \(entry.name) (\(entry.bundleId))")
            }
        }
    }
}
