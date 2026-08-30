import Foundation

// Registry of user-configured MCP servers. STATIC list, v1 policy: the user
// explicitly adds each server (name, launch command, args, env var names),
// nothing is auto-discovered, so there is no permission sprawl. JSON on disk
// at Application Support/Grux/mcp-servers.json with the standard debounced
// scheduleSave (CookbookStore / CustomEndpointStore pattern).
//
// SECRETS: the JSON file stores only env var NAMES. The VALUES live in the
// Keychain (service com.gruxai.grux, account mcp.<serverID>.env.<NAME>) via the
// raw-account helpers CustomEndpointStore already ships. Same story for
// OAuth tokens (see MCPOAuth).

struct MCPServerConfig: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    // Bare binary name or absolute path; resolved through /usr/bin/env with
    // an augmented PATH, so "npx", "uvx", "node" all work.
    var command: String
    var args: [String]
    // Env var NAMES this server needs (e.g. GITHUB_TOKEN). Values are read
    // from the Keychain at spawn time and injected into the child process.
    var envKeys: [String]
    var enabled: Bool

    init(id: UUID = UUID(), name: String, command: String, args: [String] = [], envKeys: [String] = [], enabled: Bool = false) {
        self.id = id
        self.name = name
        self.command = command
        self.args = args
        self.envKeys = envKeys
        self.enabled = enabled
    }

    // decodeIfPresent everywhere (GruxConfig migration style) so a partial or
    // older mcp-servers.json never throws and never resets the user's servers.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Unnamed server"
        command = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
        args = try c.decodeIfPresent([String].self, forKey: .args) ?? []
        envKeys = try c.decodeIfPresent([String].self, forKey: .envKeys) ?? []
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
    }

    var slug: String { MCPToolNaming.slug(forServerName: name) }

    func keychainAccount(forEnv key: String) -> String {
        "mcp.\(id.uuidString).env.\(key)"
    }
}

@MainActor
final class MCPRegistryStore: ObservableObject {
    static let shared = MCPRegistryStore()

    @Published private(set) var servers: [MCPServerConfig] = []

    private let fileURL: URL
    private var saveToken: DispatchWorkItem?

    // fileURL is injectable so tests can run against a temp file instead of
    // the real Application Support store.
    init(fileURL: URL = Persistence.supportDir.appendingPathComponent("mcp-servers.json")) {
        self.fileURL = fileURL
        self.servers = Persistence.load([MCPServerConfig].self, from: fileURL, fallback: [])
    }

    // MARK: - CRUD

    // Adds a server. env maps NAME to VALUE; values go straight to the
    // Keychain and only the names land in the JSON record. Returns nil when
    // the command is empty.
    @discardableResult
    func add(name: String, command: String, args: [String], env: [String: String]) -> MCPServerConfig? {
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return nil }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = trimmedName.isEmpty ? cmd : trimmedName
        let config = MCPServerConfig(name: displayName, command: cmd, args: args, envKeys: Array(env.keys).sorted())
        for (key, value) in env where !value.isEmpty {
            _ = CustomEndpointStore.keychainSet(account: config.keychainAccount(forEnv: key), value: value)
        }
        servers.append(config)
        scheduleSave()
        return config
    }

    func update(_ config: MCPServerConfig) {
        guard let idx = servers.firstIndex(where: { $0.id == config.id }) else { return }
        servers[idx] = config
        scheduleSave()
    }

    // Removes a server and scrubs every Keychain entry it owned (env values
    // plus any OAuth token).
    func remove(id: UUID) {
        guard let idx = servers.firstIndex(where: { $0.id == id }) else { return }
        let config = servers[idx]
        for key in config.envKeys {
            CustomEndpointStore.keychainDelete(account: config.keychainAccount(forEnv: key))
        }
        CustomEndpointStore.keychainDelete(account: MCPOAuth.tokenAccount(serverID: id))
        servers.remove(at: idx)
        scheduleSave()
    }

    func setEnabled(_ id: UUID, _ on: Bool) {
        guard let idx = servers.firstIndex(where: { $0.id == id }) else { return }
        guard servers[idx].enabled != on else { return }
        servers[idx].enabled = on
        scheduleSave()
    }

    func server(id: UUID) -> MCPServerConfig? {
        servers.first(where: { $0.id == id })
    }

    // MARK: - Env values (Keychain backed)

    func setEnvValue(serverID: UUID, key: String, value: String) {
        guard let idx = servers.firstIndex(where: { $0.id == serverID }) else { return }
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return }
        if !servers[idx].envKeys.contains(trimmedKey) {
            servers[idx].envKeys.append(trimmedKey)
            servers[idx].envKeys.sort()
            scheduleSave()
        }
        _ = CustomEndpointStore.keychainSet(account: servers[idx].keychainAccount(forEnv: trimmedKey), value: value)
    }

    func envValue(serverID: UUID, key: String) -> String {
        guard let config = server(id: serverID) else { return "" }
        return CustomEndpointStore.keychainGet(account: config.keychainAccount(forEnv: key))
    }

    // Resolves the full env map for spawn time. Missing values resolve to ""
    // so a misconfigured server fails with the server's own error message
    // instead of a silent skip.
    func envValues(for config: MCPServerConfig) -> [String: String] {
        var out: [String: String] = [:]
        for key in config.envKeys {
            out[key] = CustomEndpointStore.keychainGet(account: config.keychainAccount(forEnv: key))
        }
        return out
    }

    // MARK: - Persistence

    private func scheduleSave() {
        saveToken?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { @MainActor in self.saveNow() }
        }
        saveToken = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    // Internal (not private) so tests can flush the debounce synchronously.
    func saveNow() {
        Persistence.save(servers, to: fileURL)
    }
}
