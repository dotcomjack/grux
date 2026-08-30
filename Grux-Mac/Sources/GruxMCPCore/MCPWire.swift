import Foundation

// The MCP wire format, shared by both servers in this repo.
//
// WHAT IS SHARED AND WHAT IS NOT, because the line matters.
//
// Grux now speaks MCP over two transports. `GruxMCPServer` is a separate, read-only,
// Foundation-only process that talks newline-delimited JSON-RPC over stdio. The app hosts a
// second server over a Unix domain socket, which is the one the CLI drives and the only one
// that can change anything.
//
// Their DISPATCH is genuinely different: one is a synchronous file-handle loop in a
// short-lived process, the other is main-actor work in a long-lived app, and forcing them
// through one abstraction would mean a `DispatchQueue.main.sync` from a socket queue, which
// is a deadlock waiting for a quiet afternoon.
//
// Their FRAMING and their ENVELOPES are identical, and are exactly the parts that are easy
// to get subtly wrong: buffering a partial line across reads, stripping a CR that a client
// may or may not send, capping a frame so a malformed peer cannot exhaust memory, and
// omitting `id` on a notification rather than sending null. Those live here once.

// MARK: - Framing

/// Splits a byte stream into newline-delimited frames.
///
/// Holds a partial line across reads, which is the whole reason it exists: a socket read
/// boundary falls wherever the kernel puts it, not where the JSON ends.
public final class MCPLineSplitter {

    /// A malformed or hostile peer that never sends a newline would otherwise grow this
    /// buffer without limit. At the cap the buffer is dropped rather than trimmed, because
    /// half a frame is not recoverable and pretending otherwise would feed garbage to the
    /// parser.
    public static let maxFrameBytes = 16 * 1024 * 1024

    private var buffer = Data()

    public init() {}

    public func feed(_ chunk: Data) -> [Data] {
        buffer.append(chunk)
        var lines: [Data] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            var line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            if line.last == 0x0D { line.removeLast() }
            if !line.isEmpty { lines.append(line) }
        }
        if buffer.count > Self.maxFrameBytes {
            buffer.removeAll(keepingCapacity: false)
        }
        return lines
    }
}

// MARK: - Envelopes

public enum MCPWire {

    /// The protocol revision both servers announce. One constant, so the two cannot drift
    /// into advertising different versions of the same protocol from the same product.
    public static let protocolVersion = "2025-03-26"

    public static func ok(id: Any?, result: [String: Any]) -> [String: Any] {
        var out: [String: Any] = ["jsonrpc": "2.0", "result": result]
        // OMITTED, not null. A response to a notification has no id, and JSON-RPC treats a
        // null id as an id.
        if let id { out["id"] = id }
        return out
    }

    public static func error(id: Any?, code: Int, message: String) -> [String: Any] {
        var out: [String: Any] = ["jsonrpc": "2.0",
                                  "error": ["code": code, "message": message]]
        if let id { out["id"] = id }
        return out
    }

    public static func textResult(_ text: String) -> [String: Any] {
        ["isError": false, "content": [["type": "text", "text": text]]]
    }

    /// An error the CALLER should see as a tool result rather than a protocol failure.
    ///
    /// The distinction is not cosmetic. A JSON-RPC error means "your request was wrong"; a
    /// tool result with `isError` means "your request was fine and the answer is that this
    /// did not work". An agent reading the first will retry the call shape, which will never
    /// help, and an agent reading the second will read the message and act on it.
    public static func textFailure(_ text: String) -> [String: Any] {
        ["isError": true, "content": [["type": "text", "text": text]]]
    }

    /// One frame, newline terminated. Sorted keys so a response is byte-stable, which is
    /// what makes a transcript diffable and a test assertable.
    public static func encode(_ object: [String: Any]) -> Data? {
        guard var data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.sortedKeys]) else { return nil }
        data.append(0x0A)
        return data
    }
}
