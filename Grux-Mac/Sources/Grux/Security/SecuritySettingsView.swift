import SwiftUI

// Settings pane for the Security module (items 30 + 31).
// Registered as a tab in SettingsView's TabView:
//   securityTab.tabItem { Label("Security", systemImage: "lock.shield") }
//
// Sections:
//   - Prompt screening: master toggle for PromptSecurity scanning
//   - URL guard: master toggle + user allowlist/denylist editors
//   - Touch ID gates: per-category toggles (SensitiveActionCategory)
//   - Recent flags: last audit entries (tags + hosts only, never content)

struct SecuritySettingsView: View {
    @State private var policy = SecurityPolicyStore.shared.policy
    @State private var newAllowHost = ""
    @State private var newDenyHost = ""
    @State private var recentFlags: [SecurityAuditEntry] = []

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d HH:mm"
        return f
    }()

    var body: some View {
        Form {
            promptSection
            urlGuardSection
            touchIDSection
            recentFlagsSection
        }
        .formStyle(.grouped)
        .onAppear { refreshFlags() }
    }

    // MARK: - Prompt screening

    private var promptSection: some View {
        Section("Prompt screening") {
            Toggle("Scan tool results and fetched pages for injection", isOn: binding(\.promptScanEnabled))
            Text("Checks untrusted content re-entering the model loop for instruction-override phrasing, role-spoof markers, and base64 or zero-width smuggling. Borderline hits are annotated, not removed; code content is never blocked.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - URL guard

    private var urlGuardSection: some View {
        Section("URL guard") {
            Toggle("Check URLs before opening or fetching", isOn: binding(\.urlGuardEnabled))
            Text("Denies private-IP ranges, localhost, .local hosts, and credential-bearing URLs. No host is exempt out of the box: add your own LAN services below to keep them reachable.")
                .font(.caption)
                .foregroundStyle(.secondary)

            hostListEditor(
                title: "Always allow",
                hosts: policy.urlAllowlist,
                newHost: $newAllowHost,
                add: { host in update { $0.urlAllowlist.append(host) } },
                remove: { host in update { $0.urlAllowlist.removeAll { $0 == host } } }
            )
            hostListEditor(
                title: "Always deny",
                hosts: policy.urlDenylist,
                newHost: $newDenyHost,
                add: { host in update { $0.urlDenylist.append(host) } },
                remove: { host in update { $0.urlDenylist.removeAll { $0 == host } } }
            )
        }
    }

    private func hostListEditor(
        title: String,
        hosts: [String],
        newHost: Binding<String>,
        add: @escaping (String) -> Void,
        remove: @escaping (String) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            ForEach(hosts, id: \.self) { host in
                HStack {
                    Text(host).font(.system(.body, design: .monospaced))
                    Spacer()
                    Button {
                        remove(host)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            HStack {
                TextField("host, e.g. example.com", text: newHost)
                    .textFieldStyle(.roundedBorder)
                Button("Add") {
                    let host = newHost.wrappedValue
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                    guard !host.isEmpty, !hosts.contains(host) else { return }
                    add(host)
                    newHost.wrappedValue = ""
                }
                .disabled(newHost.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Touch ID gates

    private var touchIDSection: some View {
        Section("Touch ID gates") {
            // Only categories with a real enforcement call site get a toggle;
            // showing one for an unwired category would be a false sense of
            // security (see SensitiveActionCategory.isEnforced).
            ForEach(SensitiveActionCategory.allCases.filter(\.isEnforced)) { category in
                Toggle(category.label, isOn: gateBinding(category))
            }
            Text("Gated actions ask for Touch ID (password fallback) before running. A success is reused for 5 minutes.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Recent flags

    private var recentFlagsSection: some View {
        Section {
            if recentFlags.isEmpty {
                Text("No security events this session.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(recentFlags) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(Self.timeFormatter.string(from: entry.ts))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(entry.verdict.uppercased())
                            .font(.caption.weight(.bold))
                            .foregroundStyle(entry.verdict == "allow" || entry.verdict == "granted" ? .green : .orange)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(entry.kind) · \(entry.source)")
                                .font(.caption)
                            if !entry.tags.isEmpty {
                                Text(entry.tags.joined(separator: ", "))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                }
            }
        } header: {
            HStack {
                Text("Recent flags")
                Spacer()
                Button {
                    refreshFlags()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
            }
        } footer: {
            Text("Full trail: ~/Library/Application Support/Grux/security-audit.log (tags and hosts only, never content).")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Bindings + persistence

    private func binding(_ keyPath: WritableKeyPath<SecurityPolicy, Bool>) -> Binding<Bool> {
        Binding(
            get: { policy[keyPath: keyPath] },
            set: { newValue in update { $0[keyPath: keyPath] = newValue } }
        )
    }

    private func gateBinding(_ category: SensitiveActionCategory) -> Binding<Bool> {
        Binding(
            get: { policy.policy(for: category) == .require },
            set: { on in
                update { $0.gatePolicies[category.rawValue] = on ? .require : .off }
                Task { await SensitiveActionGate.shared.resetCache() }
            }
        )
    }

    private func update(_ mutate: (inout SecurityPolicy) -> Void) {
        mutate(&policy)
        SecurityPolicyStore.shared.replace(policy)
    }

    private func refreshFlags() {
        Task {
            let entries = await SecurityAuditLog.shared.recent(limit: 30)
            await MainActor.run { recentFlags = entries }
        }
    }
}
