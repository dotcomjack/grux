import SwiftUI

// Settings section for MCP servers. Designed to be dropped INSIDE
// SettingsView's existing Form (one line, after ModelConfigSection()):
//
//     MCPServersSection()
//
// Renders the registered server list (status dot, tool count, enable toggle,
// restart, delete) plus an add form: name, launch command, args, and env
// entries written KEY=value one per line. Env VALUES go to the Keychain via
// MCPRegistryStore; only the names persist to JSON. Servers whose upstream
// needs a browser OAuth grant use MCPOAuth and store the resulting token as
// just another env value (for example LINEAR_TOKEN).
struct MCPServersSection: View {
    @ObservedObject private var store = MCPRegistryStore.shared
    @ObservedObject private var manager = MCPManager.shared

    // Add form state.
    @State private var adding = false
    @State private var newName = ""
    @State private var newCommand = ""
    @State private var newArgs = ""
    @State private var newEnv = ""
    @State private var addError: String? = nil

    var body: some View {
        Section("MCP servers") {
            if store.servers.isEmpty {
                Text("No MCP servers yet. Add one below, for example command npx with args -y @modelcontextprotocol/server-filesystem plus a folder to expose. Enabled servers expose their tools to Grux chat as mcp_<server>_<tool>.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            ForEach(store.servers) { server in
                serverRow(server)
            }

            if adding {
                addForm
            } else {
                Button("Add MCP server") { adding = true }
                    .font(.caption)
            }

            Text("Secrets stay in the Keychain: env values and OAuth tokens never land in mcp-servers.json. For servers that need a browser sign-in, complete the grant once and paste the issued token as an env value.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    // MARK: - Row

    private func serverRow(_ server: MCPServerConfig) -> some View {
        let status = manager.statuses[server.id] ?? .init()
        return HStack(spacing: 8) {
            Circle()
                .fill(dotColor(status.phase))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 1) {
                Text(server.name)
                    .font(.system(size: 12, weight: .semibold))
                Text(statusLine(server: server, status: status))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer()

            if server.enabled && status.phase != .starting {
                Button {
                    manager.restartServer(id: server.id)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Restart server")
            }

            Toggle("", isOn: Binding(
                get: { store.server(id: server.id)?.enabled ?? false },
                set: { on in manager.setEnabled(server.id, on) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)

            Button {
                manager.stopServer(id: server.id)
                store.remove(id: server.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .foregroundStyle(GruxTheme.destructiveRose)
            .help("Remove server and delete its stored secrets")
        }
        .padding(.vertical, 2)
    }

    private func dotColor(_ phase: MCPManager.ServerStatus.Phase) -> Color {
        switch phase {
        case .stopped: return Color.secondary.opacity(0.4)
        case .starting: return GruxTheme.warnAmber
        case .running: return GruxTheme.successMint
        case .failed: return GruxTheme.destructiveRose
        }
    }

    private func statusLine(server: MCPServerConfig, status: MCPManager.ServerStatus) -> String {
        let cmd = ([server.command] + server.args).joined(separator: " ")
        switch status.phase {
        case .running:
            return "\(status.toolCount) tool\(status.toolCount == 1 ? "" : "s") | \(cmd)"
        case .starting:
            return "starting | \(cmd)"
        case .failed:
            return "failed: \(status.detail)"
        case .stopped:
            return server.enabled ? "stopped | \(cmd)" : "disabled | \(cmd)"
        }
    }

    // MARK: - Add form

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Name (e.g. GitHub)", text: $newName)
                .textFieldStyle(.roundedBorder)
            TextField("Command (e.g. npx, uvx, /usr/local/bin/server)", text: $newCommand)
                .textFieldStyle(.roundedBorder)
            TextField("Args (space separated, e.g. -y @modelcontextprotocol/server-github)", text: $newArgs)
                .textFieldStyle(.roundedBorder)
            TextField("Env (KEY=value, comma or newline separated, optional)", text: $newEnv)
                .textFieldStyle(.roundedBorder)

            if let addError {
                Label(addError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }

            HStack(spacing: 8) {
                Button("Save server") { saveNewServer() }
                    .controlSize(.small)
                    .disabled(newCommand.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel") { resetForm() }
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    private func saveNewServer() {
        let args = newArgs.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        var env: [String: String] = [:]
        let separators = CharacterSet(charactersIn: ",\n")
        for entry in newEnv.components(separatedBy: separators) {
            let pair = entry.trimmingCharacters(in: .whitespaces)
            guard !pair.isEmpty else { continue }
            guard let eq = pair.firstIndex(of: "=") else {
                addError = "Env entries must be KEY=value (got '\(pair)')."
                return
            }
            let key = String(pair[pair.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(pair[pair.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else {
                addError = "Env entries must be KEY=value (got '\(pair)')."
                return
            }
            env[key] = value
        }
        guard store.add(name: newName, command: newCommand, args: args, env: env) != nil else {
            addError = "Command is required."
            return
        }
        resetForm()
    }

    private func resetForm() {
        adding = false
        newName = ""
        newCommand = ""
        newArgs = ""
        newEnv = ""
        addError = nil
    }
}
