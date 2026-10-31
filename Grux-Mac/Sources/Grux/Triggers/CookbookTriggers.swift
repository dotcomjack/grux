import Foundation

/// The Cookbook's PULL without a click (operator rule 0r.4).
///
/// `fire-cookbook-pull` (contents: a catalog model id, for example
/// `gruxai.com/grux/grux-local:2b`) runs exactly what that row's PULL chip
/// runs, `OllamaManager.pull`, waits for the download to end, and writes
/// `cookbook-pull.json`: the model, Ollama's last status, whether it failed,
/// whether the tag is now installed, and when. An id outside the catalog is
/// refused, so this can only fetch what the Cookbook offers.
@MainActor
enum CookbookTriggers {
    static let pull = "fire-cookbook-pull"
    static let pullFile = "cookbook-pull.json"

    static func register(in dir: URL, on watcher: TriggerWatcher = .shared) {
        let file = dir.appendingPathComponent(pull)
        watcher.register(file) {
            guard FileManager.default.fileExists(atPath: file.path) else { return }
            let id = (try? String(contentsOf: file, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            try? FileManager.default.removeItem(at: file)
            Task { @MainActor in await fire(id: id, dir: dir) }
        }
    }

    static func fire(id: String, dir: URL) async {
        let out = dir.appendingPathComponent(pullFile)
        guard Cookbook.catalog.contains(where: { $0.id == id }) else {
            WakeLog.shared.log("\(pull): refused, not a catalog model")
            write(["model": id, "refused": "notInCatalog"], to: out)
            return
        }
        WakeLog.shared.log("\(pull): \(id)")
        let ollama = OllamaManager.shared
        let ended = await ollama.pullToEnd(id)
        await ollama.refreshInstalled()
        write(["model": id, "status": ended?.status ?? "", "failed": ended?.failed ?? true,
               "installed": ollama.isInstalled(id)], to: out)
    }

    private static func write(_ object: [String: Any], to url: URL) {
        var object = object
        object["writtenAt"] = ISO8601DateFormatter().string(from: Date())
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? data.write(to: url, options: .atomic)
    }
}
