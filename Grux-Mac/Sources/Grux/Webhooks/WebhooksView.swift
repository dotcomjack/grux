import SwiftUI

// Webhooks management surface. Lives alongside the Slack / Notion sections
// in the Integrations tab (see integration snippet in the roadmap notes) or
// standalone. List of registered endpoints, add/edit sheet, per-endpoint
// test-fire with inline result, and the recent-deliveries audit trail.
struct WebhooksView: View {
    @ObservedObject private var store = WebhookStore.shared

    @State private var editingConfig: WebhookConfig? = nil
    @State private var showAddSheet = false
    @State private var testResults: [UUID: WebhookDelivery] = [:]
    @State private var testingIds: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if store.configs.isEmpty {
                Text("No webhooks yet. Add one to get a signed POST whenever an agent job finishes, a workflow crosses a phase, or a reminder fires.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(store.configs) { config in
                        webhookRow(config)
                    }
                }
            }

            Button {
                showAddSheet = true
            } label: {
                Label("Add webhook", systemImage: "plus")
            }
            .controlSize(.small)

            if !store.orderedDeliveries.isEmpty {
                Divider()
                recentDeliveries
            }
        }
        .sheet(isPresented: $showAddSheet) {
            WebhookEditSheet(existing: nil) { config, secret in
                if !secret.isEmpty {
                    WebhookSecretStore.set(account: config.secretAccount, secret: secret)
                }
                store.upsert(config)
            }
        }
        .sheet(item: $editingConfig) { config in
            WebhookEditSheet(existing: config) { updated, secret in
                if !secret.isEmpty {
                    WebhookSecretStore.set(account: updated.secretAccount, secret: secret)
                }
                store.upsert(updated)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Webhooks").font(.system(size: 16, weight: .bold))
            Text("Outbound only. Grux POSTs a JSON envelope signed with HMAC-SHA256 (X-Grux-Signature header) to each URL. Secrets are stored in your macOS Keychain. Inbound triggers are deferred until the tunnel-exposure design pass.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func webhookRow(_ config: WebhookConfig) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Toggle("", isOn: Binding(
                    get: { config.enabled },
                    set: { store.setEnabled(id: config.id, $0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()

                VStack(alignment: .leading, spacing: 2) {
                    Text(config.name).font(.system(size: 13, weight: .semibold))
                    Text(config.url)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                if testingIds.contains(config.id) {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Test fire") { testFire(config) }
                        .controlSize(.small)
                }

                Button {
                    editingConfig = config
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help("Edit webhook")

                Button {
                    store.delete(id: config.id)
                    testResults[config.id] = nil
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Delete webhook")
            }

            HStack(spacing: 4) {
                ForEach(Array(config.events).sorted(by: { $0.rawValue < $1.rawValue })) { event in
                    Text(event.displayName)
                        .font(.system(size: 10))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                }
            }

            if !WebhookSecretStore.exists(account: config.secretAccount) {
                Label("No signing secret set. Deliveries will be refused until one is added.", systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            if let result = testResults[config.id] {
                deliveryBadge(result)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    private func deliveryBadge(_ delivery: WebhookDelivery) -> some View {
        HStack(spacing: 6) {
            Image(systemName: delivery.outcome == .delivered ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(delivery.outcome == .delivered ? .green : .red)
            Text(deliverySummary(delivery))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func deliverySummary(_ d: WebhookDelivery) -> String {
        switch d.outcome {
        case .delivered:
            return "Delivered (HTTP \(d.statusCode ?? 0), \(d.attempts) attempt\(d.attempts == 1 ? "" : "s"))"
        case .failed:
            let detail = d.errorMessage ?? d.statusCode.map { "HTTP \($0)" } ?? "unknown error"
            return "Failed after \(d.attempts) attempt\(d.attempts == 1 ? "" : "s"): \(detail)"
        case .skippedCircuitOpen:
            return "Skipped: circuit open (endpoint failing repeatedly)"
        }
    }

    private var recentDeliveries: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent deliveries").font(.system(size: 13, weight: .semibold))
            ForEach(store.orderedDeliveries.prefix(15)) { d in
                HStack(spacing: 8) {
                    Image(systemName: d.outcome == .delivered ? "checkmark.circle.fill" : (d.outcome == .skippedCircuitOpen ? "pause.circle.fill" : "xmark.circle.fill"))
                        .foregroundStyle(d.outcome == .delivered ? .green : (d.outcome == .skippedCircuitOpen ? .orange : .red))
                        .font(.caption)
                    Text(d.event)
                        .font(.system(size: 11, design: .monospaced))
                    Text(d.webhookName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let code = d.statusCode {
                        Text("HTTP \(code)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Text(d.timestamp, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func testFire(_ config: WebhookConfig) {
        testingIds.insert(config.id)
        Task {
            let result = await WebhookManager.shared.testFire(config: config)
            await MainActor.run {
                testResults[config.id] = result
                testingIds.remove(config.id)
            }
        }
    }
}

// MARK: - Add / edit sheet

private struct WebhookEditSheet: View {
    @Environment(\.dismiss) private var dismiss

    let existing: WebhookConfig?
    let onSave: (WebhookConfig, String) -> Void

    @State private var name: String
    @State private var url: String
    @State private var secret: String = ""
    @State private var events: Set<WebhookEvent>
    @State private var validationError: String? = nil

    init(existing: WebhookConfig?, onSave: @escaping (WebhookConfig, String) -> Void) {
        self.existing = existing
        self.onSave = onSave
        _name = State(initialValue: existing?.name ?? "")
        _url = State(initialValue: existing?.url ?? "")
        _events = State(initialValue: existing?.events ?? [.agentJobCompleted, .agentJobFailed])
    }

    private var hasStoredSecret: Bool {
        guard let existing else { return false }
        return WebhookSecretStore.exists(account: existing.secretAccount)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(existing == nil ? "Add webhook" : "Edit webhook")
                .font(.system(size: 15, weight: .bold))

            VStack(alignment: .leading, spacing: 4) {
                Text("Name").font(.caption).foregroundStyle(.secondary)
                TextField("CI notifier", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("URL").font(.caption).foregroundStyle(.secondary)
                TextField("https://example.com/hooks/grux", text: $url)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(hasStoredSecret ? "Signing secret (stored in Keychain, leave blank to keep)" : "Signing secret")
                    .font(.caption).foregroundStyle(.secondary)
                SecureField(hasStoredSecret ? "Unchanged" : "whsec_…", text: $secret)
                    .textFieldStyle(.roundedBorder)
                Text("Receivers verify with HMAC-SHA256(secret, raw body) against the X-Grux-Signature header.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Events").font(.caption).foregroundStyle(.secondary)
                ForEach(WebhookEvent.subscribable) { event in
                    Toggle(event.displayName, isOn: Binding(
                        get: { events.contains(event) },
                        set: { on in
                            if on { events.insert(event) } else { events.remove(event) }
                        }
                    ))
                    .font(.system(size: 12))
                    .controlSize(.small)
                }
            }

            if let validationError {
                Text(validationError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .controlSize(.small)
                Button(existing == nil ? "Add" : "Save") { save() }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        // Ideal, not fixed. A sheet is bounded by the window it hangs off, and
        // the main window's content floor is 840 wide, so a hard
        // `.frame(width:)` has nothing to give back if it ever exceeds that:
        // SwiftUI centres an oversized child, so it would clip off BOTH edges
        // at once rather than simply overflowing right. The sheet still opens
        // at 420 because that is the ideal a fitting-size sheet is sized from.
        // No maxHeight on purpose: this VStack has no scroll of its own, so a
        // height cap would squeeze the Cancel/Save row off the bottom instead
        // of letting the sheet grow. Six event toggles keep it near 430pt,
        // inside the 480pt ceiling; add a ScrollView before adding rows.
        .frame(minWidth: GruxLayout.sheetMin, idealWidth: 420, maxWidth: GruxLayout.sheetMax)
    }

    private func save() {
        let trimmedURL = url.trimmingCharacters(in: .whitespaces)
        guard let parsed = URL(string: trimmedURL),
              let scheme = parsed.scheme,
              scheme == "https" || scheme == "http",
              parsed.host != nil else {
            validationError = "Enter a valid http(s) URL."
            return
        }
        guard !events.isEmpty else {
            validationError = "Pick at least one event."
            return
        }
        guard existing != nil || !secret.trimmingCharacters(in: .whitespaces).isEmpty else {
            validationError = "A signing secret is required. Unsigned webhooks are refused at send time."
            return
        }

        var config: WebhookConfig
        if var updated = existing {
            updated.name = name.trimmingCharacters(in: .whitespaces)
            updated.url = trimmedURL
            updated.events = events
            config = updated
        } else {
            config = WebhookConfig(
                name: name.trimmingCharacters(in: .whitespaces),
                url: trimmedURL,
                events: events
            )
        }
        onSave(config, secret.trimmingCharacters(in: .whitespaces))
        dismiss()
    }
}
