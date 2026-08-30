import Foundation
import GruxMCPCore

// JSON-RPC 2.0 frame types for the Model Context Protocol (spec revision
// 2025-03-26, stdio transport: one compact JSON object per line over the
// server's stdin/stdout). Grux acts as the MCP CLIENT: it spawns a server
// subprocess, runs the initialize handshake, lists tools, and calls them on
// behalf of Claude tool_use blocks. Only the tools surface is implemented;
// resources, prompts, and sampling are deliberately out of scope for v1.
//
// Everything in this file is pure value-type codec logic with zero I/O so
// MCPFramingTests can cover it exhaustively without spawning processes.

// MARK: - JSONValue (MCP additions)

// Grux already ships a public JSONValue enum (CommandsV2/CommandV2Models.swift)
// for Any-Codable JSON. MCP reuses it as the wire type and adds the bridging
// the protocol layer needs: object/array accessors, key subscripting, a
// faithful Any bridge for ClaudeTool's [String: Any] world, and a
// JSONSerialization-safe lift that keeps NSNumber bools from collapsing into
// 1/0 (the existing init(any:) checks `as? Bool` first, which also matches
// NSNumber 0/1; MCP servers with strict schemas care about the difference).
extension JSONValue {
    var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    // Strict string accessor: the shared stringValue is lossy (stringifies
    // ints, doubles, bools). MCP parsing wants string-typed fields only.
    var strictStringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var strictBoolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    var strictIntValue: Int? {
        if case .int(let i) = self { return i }
        return nil
    }

    subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    // Bridge TO `Any` (for ClaudeTool.inputSchema and tool dispatch results).
    var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .int(let i): return i
        case .double(let d): return d
        case .string(let s): return s
        case .array(let a): return a.map { $0.anyValue }
        case .object(let o): return o.mapValues { $0.anyValue }
        }
    }

    // Bridge FROM the loosely-typed JSONSerialization world. CFBoolean check
    // first so `true` stays a bool and `1` stays an int.
    static func bridged(fromAny any: Any) -> JSONValue {
        switch any {
        case is NSNull:
            return .null
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return .bool(n.boolValue)
            }
            let objCType = String(cString: n.objCType)
            if objCType == "d" || objCType == "f" {
                return .double(n.doubleValue)
            }
            return .int(n.intValue)
        case let s as String:
            return .string(s)
        case let a as [Any]:
            return .array(a.map { bridged(fromAny: $0) })
        case let o as [String: Any]:
            var out: [String: JSONValue] = [:]
            out.reserveCapacity(o.count)
            for (k, v) in o { out[k] = bridged(fromAny: v) }
            return .object(out)
        default:
            // Mirror the shared init(any:) fallback so behavior is predictable.
            return .string(String(describing: any))
        }
    }
}

// MARK: - JSON-RPC frames

// Outgoing request or notification. A nil id means notification (synthesized
// Encodable uses encodeIfPresent for optionals, so the key is omitted, which
// is exactly what JSON-RPC 2.0 requires for notifications).
struct MCPRequest: Encodable {
    let jsonrpc: String
    let id: Int?
    let method: String
    let params: JSONValue?

    init(id: Int?, method: String, params: JSONValue? = nil) {
        self.jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = params
    }
}

struct MCPErrorObject: Codable, Equatable, Sendable {
    let code: Int
    let message: String
    let data: JSONValue?
}

// One incoming line, before we know whether it is a response, a
// server-initiated request (servers may ping the client), or a notification.
struct MCPIncoming: Decodable {
    let jsonrpc: String?
    let id: JSONValue?
    let method: String?
    let params: JSONValue?
    let result: JSONValue?
    let error: MCPErrorObject?

    var isResponse: Bool { method == nil && (result != nil || error != nil) }
    var isServerRequest: Bool { method != nil && id != nil }
    var isNotification: Bool { method != nil && id == nil }

    // Our outgoing ids are always Int, so correlation only needs the int form.
    var intID: Int? { id?.strictIntValue }
}

// MARK: - Framing

enum MCPFrameCodec {
    // One compact JSON object, newline terminated. JSONEncoder default output
    // contains no interior newlines, which the stdio transport requires.
    static func encodeLine<T: Encodable>(_ value: T) throws -> Data {
        var data = try JSONEncoder().encode(value)
        data.append(0x0A)
        return data
    }

    static func decodeIncoming(_ line: Data) -> MCPIncoming? {
        try? JSONDecoder().decode(MCPIncoming.self, from: line)
    }
}

// The line splitter moved to GruxMCPCore on 2026-08-28, and the move found something.
//
// This algorithm existed FIVE times in this repository: here for the MCP client, in
// GruxMCPServer for the read-only stdio server, in GruxAgentCore/ACP/ACPConnection, in
// DesignStudio/Export/MCPServerLogic, and once more in the control socket added that day.
// All five buffer a partial frame across reads, strip an optional CR, and drop the buffer
// past a 16 MB cap. Five places to get an off-by-one wrong, and five places a fix would have
// to be remembered.
//
// Two are consolidated: this one and the stdio server both use GruxMCPCore.MCPLineSplitter.
// The remaining two are recorded rather than quietly left, because ACP is a different
// protocol that happens to share a framing, and the DesignStudio copy is inside an export
// path with its own lifetime. Neither is in the way today.

// MARK: - Typed payloads

enum MCPProtocol {
    static let version = "2025-03-26"

    static func initializeParams(clientName: String, clientVersion: String) -> JSONValue {
        .object([
            "protocolVersion": .string(version),
            "capabilities": .object([:]),
            "clientInfo": .object([
                "name": .string(clientName),
                "version": .string(clientVersion)
            ])
        ])
    }
}

// A tool advertised by a server via tools/list.
struct MCPToolDescriptor: Equatable, Sendable {
    let name: String
    let description: String
    let inputSchema: JSONValue

    static func parse(_ value: JSONValue) -> MCPToolDescriptor? {
        guard let name = value["name"]?.strictStringValue, !name.isEmpty else { return nil }
        let desc = value["description"]?.strictStringValue ?? ""
        let schema = value["inputSchema"] ?? .object(["type": .string("object"), "properties": .object([:])])
        return MCPToolDescriptor(name: name, description: desc, inputSchema: schema)
    }

    // Parses a full tools/list result: { tools: [...], nextCursor? }.
    static func parseList(_ result: JSONValue) -> (tools: [MCPToolDescriptor], nextCursor: String?) {
        let tools = (result["tools"]?.arrayValue ?? []).compactMap { parse($0) }
        return (tools, result["nextCursor"]?.strictStringValue)
    }
}

// A tools/call result: content blocks plus the isError flag.
struct MCPCallToolResult: Equatable, Sendable {
    let isError: Bool
    let blocks: [JSONValue]

    static func parse(_ result: JSONValue) -> MCPCallToolResult {
        MCPCallToolResult(
            isError: result["isError"]?.strictBoolValue ?? false,
            blocks: result["content"]?.arrayValue ?? []
        )
    }

    // Flattens content blocks into the single string ChatService.dispatchTool
    // feeds back to Claude as a tool_result. Text blocks pass through, images
    // and embedded resources are summarized rather than inlined.
    var flattenedText: String {
        var parts: [String] = []
        for block in blocks {
            switch block["type"]?.strictStringValue {
            case "text":
                if let t = block["text"]?.strictStringValue, !t.isEmpty { parts.append(t) }
            case "image":
                let mime = block["mimeType"]?.strictStringValue ?? "image"
                let bytes = block["data"]?.strictStringValue?.count ?? 0
                parts.append("[\(mime) image, \(bytes) base64 chars]")
            case "resource":
                if let uri = block["resource"]?["uri"]?.strictStringValue {
                    parts.append("[resource: \(uri)]")
                } else if let t = block["resource"]?["text"]?.strictStringValue {
                    parts.append(t)
                }
            default:
                break
            }
        }
        return parts.joined(separator: "\n")
    }
}

// MARK: - Tool namespacing

// MCP tools surface to Claude as `mcp_<serverSlug>_<tool>`. Server slugs are
// restricted to [a-z0-9-] (no underscores), so the FIRST underscore after the
// prefix unambiguously separates slug from tool name even when the tool name
// itself contains underscores.
enum MCPToolNaming {
    static let prefix = "mcp_"

    // Anthropic tool-name limit. Names beyond this are truncated; the routing
    // table in MCPManager keys on the final (possibly truncated) name so
    // dispatch still resolves.
    static let maxNameLength = 64

    static func slug(forServerName name: String) -> String {
        var out = ""
        var lastWasDash = true  // suppress leading dash
        for ch in name.lowercased() {
            if (ch.isLetter && ch.isASCII) || (ch.isNumber && ch.isASCII) {
                out.append(ch)
                lastWasDash = false
            } else if !lastWasDash {
                out.append("-")
                lastWasDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        if out.isEmpty { out = "server" }
        if out.count > 20 { out = String(out.prefix(20)) }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }

    // Distinct server names can truncate to the same 20-char slug (e.g.
    // "GitHub Enterprise Server Production" and "...Staging" both -> the same
    // prefix). When that happens, two servers' tools collide on identical
    // namespaced names and the second silently drops out of routing. Build a
    // collision-free slug map: the first server keeps the plain slug, any
    // later server sharing it gets a short stable discriminator derived from
    // its UUID so its tools stay reachable. Deterministic given an ordered
    // list of (id, name) so prompt caching stays warm across turns.
    static func disambiguatedSlugs(for servers: [(id: UUID, name: String)]) -> [UUID: String] {
        var used: Set<String> = []
        var result: [UUID: String] = [:]
        for (id, name) in servers {
            let base = slug(forServerName: name)
            var candidate = base
            if used.contains(candidate) {
                // Stable 4-char suffix from the UUID; trim the base so the
                // combined slug still fits comfortably under the name cap.
                let disc = String(id.uuidString.lowercased().filter { $0.isLetter || $0.isNumber }.prefix(4))
                let trimmed = base.count > 15 ? String(base.prefix(15)) : base
                candidate = trimmed + "-" + disc
                // Extremely defensive: if even that collides, append more.
                var extra = 0
                while used.contains(candidate) {
                    extra += 1
                    candidate = trimmed + "-" + disc + String(extra)
                }
            }
            used.insert(candidate)
            result[id] = candidate
        }
        return result
    }

    static func namespaced(serverSlug: String, tool: String) -> String {
        // Tool names from servers should already match [A-Za-z0-9_-]; scrub
        // anything else defensively so the Anthropic API never rejects.
        let cleanTool = String(tool.map { ch in
            (ch.isASCII && (ch.isLetter || ch.isNumber)) || ch == "_" || ch == "-" ? ch : "-"
        })
        let full = prefix + serverSlug + "_" + cleanTool
        return full.count <= maxNameLength ? full : String(full.prefix(maxNameLength))
    }

    // Splits a namespaced name back into (serverSlug, tool). Returns nil when
    // the name is not MCP-shaped.
    static func parse(_ name: String) -> (serverSlug: String, tool: String)? {
        guard name.hasPrefix(prefix) else { return nil }
        let rest = name.dropFirst(prefix.count)
        guard let underscore = rest.firstIndex(of: "_") else { return nil }
        let slug = String(rest[rest.startIndex..<underscore])
        let tool = String(rest[rest.index(after: underscore)...])
        guard !slug.isEmpty, !tool.isEmpty else { return nil }
        return (slug, tool)
    }

    static func isMCPToolName(_ name: String) -> Bool {
        parse(name) != nil
    }
}
