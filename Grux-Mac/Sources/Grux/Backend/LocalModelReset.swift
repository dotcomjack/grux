import Foundation

/// Keeps the local model's memory bounded without giving up its speed.
///
/// Ollama's MLX runner keeps up to 8 GiB of saved prompt readings and offers
/// no setting for it. Measured 2026-10-24 on a 16 GB Mac mini: grux-local:4b
/// reported 4.44 GB fresh and 13.06 GB (/api/ps) after 265 turns, 12 GB by
/// `footprint`. Unloading frees it, but the next two turns then read every
/// tool again: 18.39 s and 15.73 s there, against about 1.4 s warm.
///
/// So once nobody has used the model for `idleSeconds` and Ollama reports more
/// than `ceilingBytes` for a model Grux asked to keep, Grux unloads it and
/// reads the stable prefix again in the background
/// (ChatService.warmLocalPrefix). That costs two cold reads, about 27 s on that
/// Mac mini, while nobody is waiting, and the model is back at its fresh size
/// with the next turn warm: 2.85 s there after the warm-up.
@MainActor
final class LocalModelReset {
    static let shared = LocalModelReset()

    /// How long the model must sit unused before a reset may run.
    static let idleSeconds: TimeInterval = 180

    /// The most a kept model may report: its smallest size seen since Grux
    /// started (the size of a fresh load, whatever the runner allocates up
    /// front), or before any is seen its size on disk and a twentieth more,
    /// plus a tenth of this Mac's memory (1.6 GB on 16 GB, 0.8 GB on 8 GB).
    static func ceilingBytes(modelBytes: Int64, smallestSeen: Int64?, physicalBytes: Int64) -> Int64 {
        (smallestSeen ?? (modelBytes + modelBytes / 20)) + physicalBytes / 10
    }

    static func shouldReset(reportedBytes: Int64, modelBytes: Int64, smallestSeen: Int64? = nil,
                            physicalBytes: Int64) -> Bool {
        modelBytes > 0 && reportedBytes > ceilingBytes(modelBytes: modelBytes, smallestSeen: smallestSeen,
                                                       physicalBytes: physicalBytes)
    }

    /// Ollama reports a model by its full tag; Grux may call it without one.
    static func sameModel(_ reported: String, _ called: String) -> Bool {
        reported == called || reported == called + ":latest" || called == reported + ":latest"
    }

    private var timer: Timer?
    private var checkedThrough: Date = .distantPast
    private var running = false
    private var smallest: [String: Int64] = [:]

    /// Starts the once-a-minute check. Idempotent; sends nothing until Grux has
    /// itself kept a model on this Mac.
    func startIfNeeded() {
        guard timer == nil, !LocalModelUnload.isUnderTest else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in await LocalModelReset.shared.tick() }
        }
    }

    func tick(now: Date = Date()) async {
        guard !running, !AppState.shared.isThinking, let last = LocalModelUnload.lastUse(),
              last > checkedThrough, now.timeIntervalSince(last) >= Self.idleSeconds else { return }
        checkedThrough = last
        running = true
        defer { running = false }
        let physical = Int64(ProcessInfo.processInfo.physicalMemory)
        var resetModels: [(key: String, baseURL: String, model: String, before: Int64)] = []
        for kept in LocalModelUnload.kept() {
            let key = kept.baseURL + " " + kept.model
            guard let reported = await Self.reportedBytes(baseURL: kept.baseURL, model: kept.model),
                  let onDisk = await Self.modelBytes(baseURL: kept.baseURL, model: kept.model) else { continue }
            let seen = smallest[key]
            smallest[key] = min(seen ?? reported, reported)
            guard Self.shouldReset(reportedBytes: reported, modelBytes: onDisk, smallestSeen: seen,
                                   physicalBytes: physical),
                  // Nobody started a turn while Ollama was being asked.
                  !AppState.shared.isThinking, LocalModelUnload.lastUse() == last,
                  let req = LocalModelUnload.request(baseURL: kept.baseURL, model: kept.model) else { continue }
            _ = try? await URLSession.shared.data(for: req)
            resetModels.append((key, kept.baseURL, kept.model, reported))
        }
        // The warm-up's own calls are not use, but a real turn during it is.
        checkedThrough = LocalModelUnload.lastUse() ?? checkedThrough
        if !resetModels.isEmpty, !AppState.shared.isThinking { await ChatService.shared.warmLocalPrefix() }
        // The size right after a reset is the fresh baseline, but only if it is
        // smaller than before: a read taken while Ollama is still unloading or
        // reloading would otherwise lock in the grown size and end every later
        // reset. A baseline never rises.
        for m in resetModels {
            let fresh = await Self.reportedBytes(baseURL: m.baseURL, model: m.model)
            if let fresh, fresh < m.before {
                smallest[m.key] = min(smallest[m.key] ?? fresh, fresh)
            } else {
                smallest[m.key] = nil
            }
        }
    }

    /// What Ollama reports for `model` right now (/api/ps `size`), or nil when it is not loaded.
    static func reportedBytes(baseURL: String, model: String) async -> Int64? {
        guard let obj = await json(baseURL: baseURL, path: "/api/ps"),
              let models = obj["models"] as? [[String: Any]],
              let m = models.first(where: { sameModel(($0["name"] as? String) ?? "", model)
                                            || sameModel(($0["model"] as? String) ?? "", model) })
        else { return nil }
        return (m["size"] as? NSNumber)?.int64Value
    }

    /// The model's size on disk (/api/tags `size`).
    static func modelBytes(baseURL: String, model: String) async -> Int64? {
        guard let obj = await json(baseURL: baseURL, path: "/api/tags"),
              let models = obj["models"] as? [[String: Any]],
              let m = models.first(where: { sameModel(($0["name"] as? String) ?? "", model)
                                            || sameModel(($0["model"] as? String) ?? "", model) })
        else { return nil }
        return (m["size"] as? NSNumber)?.int64Value
    }

    private static func json(baseURL: String, path: String) async -> [String: Any]? {
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard LocalTurn.isLoopback(baseURL: base), let url = URL(string: base + path) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 3
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
