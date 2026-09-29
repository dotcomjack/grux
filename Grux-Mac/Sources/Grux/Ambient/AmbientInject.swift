import Foundation

/// The text seam into the listener: `~/.grux/fire-ambient-inject` in,
/// `~/.grux/ambient-inject-result.json` out. The file holds plain text, or JSON
/// `{"text": "...", "dryRun": "none" | "outsideGrux" | "everything"}`.
///
/// Injected words default to `outsideGrux`: they are for driving and checking
/// Grux, so a typed "close everything" is decided and recorded but never hides
/// the apps somebody is using. Running it for real takes an explicit "none".
enum AmbientInject {
    struct Request: Equatable {
        let text: String
        let dryRun: VoiceCommandRouter.DryRun
    }

    static var resultURL: URL { Persistence.gruxDir.appendingPathComponent("ambient-inject-result.json") }

    static func parse(_ raw: String) -> Request {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"),
           let data = trimmed.data(using: .utf8),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let text = obj["text"] as? String {
            let mode = (obj["dryRun"] as? String).flatMap(VoiceCommandRouter.DryRun.init(rawValue:)) ?? .outsideGrux
            return Request(text: text.trimmingCharacters(in: .whitespacesAndNewlines), dryRun: mode)
        }
        return Request(text: trimmed, dryRun: .outsideGrux)
    }

    /// One result per inject, whatever became of it. A chunk the listener
    /// dropped still gets a file, with the reason, and null decision fields.
    static func result(for request: Request, route: AmbientListener.ChunkRoute,
                       wallMs: Int, at: Date = Date()) -> [String: Any] {
        let e = route.event
        return [
            "at": ISO8601DateFormatter().string(from: at),
            "text": request.text,
            "heard": route.heard,
            "stage": route.stage,
            "dryRunMode": request.dryRun.rawValue,
            "decisionId": e?.commandId ?? NSNull(),
            "outcome": e.map { "\($0.outcome)" } ?? NSNull(),
            "confidence": e?.confidence ?? NSNull(),
            "provider": e?.provider.rawValue ?? NSNull(),
            "latencyMs": e?.latencyMs ?? NSNull(),
            "action": e?.action ?? NSNull(),
            "dryRun": e?.dryRun ?? route.dryRun ?? NSNull(),
            "wallMs": wallMs,
        ]
    }

    static func write(_ result: [String: Any], to url: URL = resultURL) {
        guard let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
