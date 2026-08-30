import SwiftUI
import AppKit

// Hosts the cold-email confirmation dialog in a standalone window. Mirrors the
// IssueConfirmController singleton pattern: present(draft:) builds an NSWindow
// wrapping the SwiftUI view, brings it to front, and the view drives send via
// ColdEmailEngine. Nothing sends without a tap here.
@MainActor
final class ColdEmailConfirmController {
    static let shared = ColdEmailConfirmController()
    private init() {}

    private var window: NSWindow?

    func present(draft: ColdEmailEngine.OutreachDraft) {
        // Reuse a single dialog window.
        let view = ColdEmailConfirmView(draft: draft) { [weak self] in
            self?.close()
        }
        let hosting = NSHostingController(rootView: view)
        if let window {
            window.contentViewController = hosting
            window.makeKeyAndOrderFront(nil)
        } else {
            let w = NSWindow(contentViewController: hosting)
            w.title = "Confirm Outreach"
            w.styleMask = [.titled, .closable, .resizable]
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 560, height: 540))
            w.center()
            window = w
            w.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.orderOut(nil)
    }
}

struct ColdEmailConfirmView: View {
    let draft: ColdEmailEngine.OutreachDraft
    let onClose: () -> Void

    @State private var person: String
    @State private var company: String
    @State private var toEmail: String
    @State private var subject: String
    @State private var bodyText: String
    @State private var sending = false
    @State private var regenerating = false
    @State private var status: String?
    @State private var acknowledgedCap = false
    @State private var capWarning: String?
    @State private var dedupeWarning: String?
    @State private var provider: String
    @State private var groundingSource: String?

    init(draft: ColdEmailEngine.OutreachDraft, onClose: @escaping () -> Void) {
        self.draft = draft
        self.onClose = onClose
        _person = State(initialValue: draft.intent.person)
        _company = State(initialValue: draft.intent.company)
        _toEmail = State(initialValue: draft.intent.toEmail)
        _subject = State(initialValue: draft.subject)
        _bodyText = State(initialValue: draft.body)
        _capWarning = State(initialValue: draft.capWarning)
        _dedupeWarning = State(initialValue: draft.dedupeWarning)
        _provider = State(initialValue: draft.provider)
        _groundingSource = State(initialValue: draft.groundingSource)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Compose Outreach")
                    .font(.system(size: 14, weight: .bold))
                Spacer()
                Text(provider)
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }

            if let src = groundingSource, !bodyText.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: src.contains("discarded") || src.contains("no ") || src.contains("generic") ? "exclamationmark.circle" : "checkmark.seal")
                        .font(.system(size: 10))
                    Text("Opener grounding: \(src)")
                        .font(.system(size: 10))
                }
                .foregroundStyle(.tertiary)
            }

            if let warning = capWarning { capBanner(warning) }
            if let dedupe = dedupeWarning { dedupeBanner(dedupe) }

            HStack(spacing: 8) {
                field("Person") {
                    TextField("Jane Doe", text: $person)
                        .textFieldStyle(.roundedBorder).font(.system(size: 13))
                }
                field("Company") {
                    TextField("Acme Co", text: $company)
                        .textFieldStyle(.roundedBorder).font(.system(size: 13))
                }
            }
            field("To") {
                TextField("name@company.com", text: $toEmail)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
            }
            field("Subject") {
                TextField("", text: $subject)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
            }
            field("From") {
                // The address itself is owned by the send path
                // (ColdEmailEngine.send), so this row names the account rather
                // than restating a literal that would drift from it.
                Text("Your default outreach account")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }

            HStack {
                Text("Body")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await regenerate() }
                } label: {
                    HStack(spacing: 6) {
                        if regenerating { ProgressView().controlSize(.small) }
                        Text(bodyText.isEmpty ? "Draft" : "Regenerate")
                    }
                }
                .buttonStyle(UtilityButton())
                .disabled(regenerating || person.trimmingCharacters(in: .whitespaces).isEmpty || company.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            TextEditor(text: $bodyText)
                .font(.system(size: 13))
                .frame(minHeight: 200)
                .padding(6)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.3), lineWidth: 1))

            if let status {
                Text(status).font(.system(size: 12)).foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { onClose() }
                    .buttonStyle(UtilityButton())
                Button(action: send) {
                    HStack(spacing: 6) {
                        if sending { ProgressView().controlSize(.small) }
                        Text("Send")
                    }
                }
                .buttonStyle(PillButton())
                .disabled(sending || !canSend)
            }
        }
        .padding(16)
        .frame(minWidth: 540)
    }

    private var canSend: Bool {
        guard toEmail.contains("@") else { return false }
        guard !bodyText.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if capWarning != nil && !acknowledgedCap { return false }
        return true
    }

    private func capBanner(_ warning: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Founding-customer cap", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.orange)
            Text(warning)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Toggle("I mean to override the cap and send anyway", isOn: $acknowledgedCap)
                .font(.system(size: 11))
                .toggleStyle(.checkbox)
        }
        .padding(10)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func dedupeBanner(_ warning: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 12)).foregroundStyle(.yellow)
            Text(warning)
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color.yellow.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func field<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
            content()
        }
    }

    private func regenerate() async {
        regenerating = true
        status = nil
        let intent = ColdEmailEngine.OutreachIntent(
            person: person.trimmingCharacters(in: .whitespaces),
            company: company.trimmingCharacters(in: .whitespaces),
            toEmail: toEmail.trimmingCharacters(in: .whitespaces)
        )
        let result = await ColdEmailEngine.shared.draft(intent: intent)
        await MainActor.run {
            regenerating = false
            if let d = result {
                subject = d.subject
                bodyText = d.body
                provider = d.provider
                capWarning = d.capWarning
                dedupeWarning = d.dedupeWarning
                groundingSource = d.groundingSource
                status = "Drafted."
            } else {
                status = "Draft failed. Check the company name or try again."
            }
        }
    }

    private func send() {
        sending = true
        status = nil
        // Rebuild the draft from the (possibly edited) dialog fields.
        let intent = ColdEmailEngine.OutreachIntent(person: person, company: company, toEmail: toEmail)
        let edited = ColdEmailEngine.OutreachDraft(
            intent: intent,
            subject: subject,
            body: bodyText,
            provider: provider,
            capWarning: capWarning,
            dedupeWarning: dedupeWarning,
            groundingSource: groundingSource
        )
        Task {
            let result = await ColdEmailEngine.shared.send(draft: edited, toEmail: toEmail)
            await MainActor.run {
                sending = false
                switch result {
                case .success(let id):
                    status = "Sent (id \(id.prefix(10)))"
                    onClose()
                case .failure(let err):
                    status = "Failed: \(err.localizedDescription)"
                }
            }
        }
    }
}
