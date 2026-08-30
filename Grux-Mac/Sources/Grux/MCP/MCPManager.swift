import Foundation

// Runtime owner of live MCP connections. Holds one MCPConnection per enabled
// server from MCPRegistryStore, aggregates their advertised tools into
// ClaudeTool schemas namespaced mcp_<serverSlug>_<tool>, and dispatches
// Claude tool_use calls back to the right server.
//
// Integration seam (see ChatService):
//   - allTools(): tools.append(contentsOf: MCPManager.shared.claudeTools())
//   - dispatchTool(): case _ where MCPManager.shared.canHandle(name):
//                         return await MCPManager.shared.dispatch(...)
//   - GruxApp launch: MCPManager.shared.bootstrap()

@MainActor
final class MCPManager: ObservableObject {
    static let shared = MCPManager()

    struct ServerStatus: Equatable {
        enum Phase: Equatable {
            case stopped
            case starting
            case running
            case failed
        }
        var phase: Phase = .stopped
        var toolCount: Int = 0
        var detail: String = ""
    }

    @Published private(set) var statuses: [UUID: ServerStatus] = [:]

    private var connections: [UUID: MCPConnection] = [:]
    private var toolsByServer: [UUID: [MCPToolDescriptor]] = [:]
    // Namespaced Claude tool name to (server, raw MCP tool name). Routing
    // through this table (instead of re-parsing names) keeps dispatch correct
    // even after truncation to the Anthropic name-length cap.
    private var routes: [String: (serverID: UUID, tool: String)] = [:]

    private init() {}

    // MARK: - Lifecycle

    // Called once from applicationDidFinishLaunching. Starts every enabled
    // server in parallel; failures degrade to a per-server failed status.
    func bootstrap() {
        for config in MCPRegistryStore.shared.servers where config.enabled {
            startServer(config)
        }
    }

    func startServer(_ config: MCPServerConfig) {
        stopServer(id: config.id)
        statuses[config.id] = ServerStatus(phase: .starting, toolCount: 0, detail: "")
        let envValues = MCPRegistryStore.shared.envValues(for: config)
        let conn = MCPConnection(serverName: config.name, command: config.command, args: config.args, envValues: envValues)
        connections[config.id] = conn
        Task { [weak self] in
            do {
                try await conn.start()
                let tools = try await conn.listTools()
                self?.noteRunning(serverID: config.id, tools: tools)
            } catch {
                self?.noteFailed(serverID: config.id, message: error.localizedDescription)
            }
        }
    }

    func stopServer(id: UUID) {
        if let conn = connections.removeValue(forKey: id) {
            Task { await conn.shutdown() }
        }
        toolsByServer[id] = nil
        statuses[id] = ServerStatus(phase: .stopped, toolCount: 0, detail: "")
        rebuildRoutes()
    }

    func restartServer(id: UUID) {
        guard let config = MCPRegistryStore.shared.server(id: id) else { return }
        startServer(config)
    }

    // Settings toggle path: persist the flag, then start or stop the runtime.
    func setEnabled(_ id: UUID, _ on: Bool) {
        MCPRegistryStore.shared.setEnabled(id, on)
        if on, let config = MCPRegistryStore.shared.server(id: id) {
            startServer(config)
        } else if !on {
            stopServer(id: id)
        }
    }

    private func noteRunning(serverID: UUID, tools: [MCPToolDescriptor]) {
        // The server may have been disabled while starting; drop the result.
        guard connections[serverID] != nil else { return }
        toolsByServer[serverID] = tools
        statuses[serverID] = ServerStatus(phase: .running, toolCount: tools.count, detail: "")
        rebuildRoutes()
    }

    private func noteFailed(serverID: UUID, message: String) {
        guard connections[serverID] != nil else { return }
        statuses[serverID] = ServerStatus(phase: .failed, toolCount: 0, detail: message)
        toolsByServer[serverID] = nil
        rebuildRoutes()
        NSLog("[MCPManager] server %@ failed: %@", serverID.uuidString, message)
    }

    // Collision-free per-server slug map for the current registry. Two
    // distinctly-named servers whose names truncate to the same slug get
    // disambiguated here so neither one's tools silently drop from routing.
    private func currentSlugs() -> [UUID: String] {
        let servers = MCPRegistryStore.shared.servers
        return MCPToolNaming.disambiguatedSlugs(for: servers.map { ($0.id, $0.name) })
    }

    private func rebuildRoutes() {
        routes.removeAll()
        let slugs = currentSlugs()
        for config in MCPRegistryStore.shared.servers {
            guard let tools = toolsByServer[config.id] else { continue }
            let serverSlug = slugs[config.id] ?? config.slug
            for tool in tools {
                let name = MCPToolNaming.namespaced(serverSlug: serverSlug, tool: tool.name)
                if routes[name] == nil {
                    routes[name] = (config.id, tool.name)
                } else {
                    NSLog("[MCPManager] tool name collision on %@, keeping first registration", name)
                }
            }
        }
    }

    // MARK: - Claude integration

    // Aggregated tools for ChatService.allTools(). Deterministic order
    // (registry order, then server tool order) so prompt caching stays warm
    // across turns.
    func claudeTools() -> [ClaudeTool] {
        var out: [ClaudeTool] = []
        let slugs = currentSlugs()
        for config in MCPRegistryStore.shared.servers {
            guard let tools = toolsByServer[config.id] else { continue }
            let serverSlug = slugs[config.id] ?? config.slug
            for tool in tools {
                let name = MCPToolNaming.namespaced(serverSlug: serverSlug, tool: tool.name)
                guard let route = routes[name], route.serverID == config.id, route.tool == tool.name else { continue }
                let schema = tool.inputSchema.anyValue as? [String: Any]
                    ?? ["type": "object", "properties": [:]]
                let desc = tool.description.isEmpty ? "MCP tool '\(tool.name)'." : tool.description
                out.append(ClaudeTool(
                    name: name,
                    description: "[MCP: \(config.name)] \(desc)",
                    inputSchema: schema
                ))
            }
        }
        return out
    }

    func canHandle(_ name: String) -> Bool {
        routes[name] != nil
    }

    // Executes a namespaced MCP tool call and flattens the result into the
    // ok/error string contract ChatService.dispatchTool feeds back to Claude.
    func dispatch(name: String, input: [String: Any]) async -> String {
        guard let route = routes[name], let conn = connections[route.serverID] else {
            return "error: unknown MCP tool '\(name)' (server disabled or not running)"
        }
        let arguments = JSONValue.bridged(fromAny: input)
        do {
            let result = try await conn.callTool(name: route.tool, arguments: arguments)
            let text = result.flattenedText
            if result.isError {
                return "error: \(text.isEmpty ? "MCP tool reported an error with no message" : text)"
            }
            return text.isEmpty ? "ok (tool returned no content)" : text
        } catch {
            // Connection-level failure: surface it and refresh the status dot
            // so Settings reflects reality without a manual restart.
            if let serverConn = connections[route.serverID] {
                Task { [weak self] in
                    let alive = await serverConn.isReady
                    if !alive { self?.noteFailed(serverID: route.serverID, message: error.localizedDescription) }
                }
            }
            return "error: MCP call failed: \(error.localizedDescription)"
        }
    }
}
