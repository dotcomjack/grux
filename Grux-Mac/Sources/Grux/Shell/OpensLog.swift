import Foundation

/// The reskin's only usage counter: which surface opened, and through which
/// door. One JSON object per line in `opens.jsonl` under the support folder.
/// Local, never sent anywhere, and nothing in 3.0 reads it; it exists so the
/// next version can rank Recent on real use instead of on recency alone.
///
/// `PanelModel.open(_:via:)` is the only caller of `record`. A caller that
/// opens through `AppState.requestedTab`, which carries only a key, sets
/// `nextVia` right before it, and the panel consumes it.
final class OpensLog {
    enum Via: String { case now, recent, palette, trigger, cli, input, hub }

    static let shared = OpensLog(fileURL: Persistence.supportDir.appendingPathComponent("opens.jsonl"))

    let fileURL: URL
    /// The door the next `requestedTab` open came through, if the caller knows it.
    var nextVia: Via?

    private let queue = DispatchQueue(label: "com.gruxai.grux.opens-log")
    private var warnedOnce = false

    init(fileURL: URL) { self.fileURL = fileURL }

    func record(key: String, via: Via) {
        let entry = ["ts": ISO8601DateFormatter().string(from: Date()), "key": key, "via": via.rawValue]
        queue.async { [self] in
            do {
                var line = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
                line.append(0x0A)
                if !FileManager.default.fileExists(atPath: fileURL.path) {
                    try Data().write(to: fileURL)
                }
                let h = try FileHandle(forWritingTo: fileURL)
                defer { try? h.close() }
                try h.seekToEnd()
                try h.write(contentsOf: line)
            } catch {
                if !warnedOnce {
                    warnedOnce = true
                    NSLog("OpensLog: cannot write \(fileURL.lastPathComponent): \(error)")
                }
            }
        }
    }

    /// Waits for every `record` made so far to reach the file.
    func flush() { queue.sync {} }
}
