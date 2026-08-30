import SwiftUI
import AppKit

// Hosts the Support Drafts list in a standalone window. Singleton NSWindow
// controller so it can be opened from engine code (the smoke test, the hourly
// sweep) without SwiftUI Scene plumbing, matching ColdEmailConfirmController.
@MainActor
final class SupportDraftsController {
    static let shared = SupportDraftsController()
    private init() {}
    private var window: NSWindow?

    func present() {
        if let window {
            window.makeKeyAndOrderFront(nil)
        } else {
            let hosting = NSHostingController(rootView: SupportDraftsView())
            let w = NSWindow(contentViewController: hosting)
            w.title = "Support Drafts"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 700, height: 560))
            w.center()
            window = w
            w.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

// The Grux inbox surface for staged support replies. Lists every draft the
// triage engine produced; each row shows the incoming message, the editable
// brand-voice reply, and a one-tap Send (which is the ONLY thing that calls
// Resend). Tight styling per the global button/input rules.
struct SupportDraftsView: View {
    @ObservedObject private var store = SupportDraftStore.shared
    @State private var showDone = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if store.activeDrafts.isEmpty && store.doneDrafts.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if store.activeDrafts.isEmpty {
                            Text("Queue clear. Nothing waiting.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 20)
                                .frame(maxWidth: .infinity)
                        }
                        ForEach(store.activeDrafts) { draft in
                            DraftRow(draft: draft)
                        }
                        if !store.doneDrafts.isEmpty {
                            doneSection
                        }
                    }
                    .padding(14)
                }
            }
        }
        .frame(minWidth: 640, minHeight: 520)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Support Drafts")
                .font(.system(size: 15, weight: .bold))
            Text("\(store.stagedCount) waiting")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var doneSection: some View {
        DisclosureGroup(isExpanded: $showDone) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(store.doneDrafts.prefix(30)) { d in
                    DoneRow(draft: d)
                }
            }
            .padding(.top, 6)
        } label: {
            Text("Done (\(store.doneDrafts.count))")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.top, 6)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
            Text("No staged drafts.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text("The hourly sweep reads your open Outlook tab. Touch ~/.grux/fire-support-triage-test to run one now.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

// A single handled (sent/dismissed) draft, shown in the collapsed Done list.
private struct DoneRow: View {
    let draft: SupportDraft
    private var sent: Bool { draft.status == .sent }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: sent ? "checkmark.circle.fill" : "xmark.circle")
                .font(.system(size: 11))
                .foregroundStyle(sent ? Color.green : Color.secondary)
            Text(sent ? "Sent" : "Dismissed")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Re: \(draft.subject)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Text(draft.fromEmail)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }
}

// One staged draft. Owns its own edit state, regenerate spinner, and the 5s
// undo-send countdown. On a completed send the draft's status flips to .sent
// in the store, so it drops out of activeDrafts and this row disappears from
// the queue (moving into the Done section).
private struct DraftRow: View {
    let draft: SupportDraft

    @State private var bodyText: String = ""
    @State private var subjectText: String = ""
    @State private var didLoad = false
    @State private var regenerating = false
    @State private var countdown = 0          // >0 while the undo window is live
    @State private var sendTask: Task<Void, Never>?
    @State private var status: String?

    private let undoSeconds = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                urgencyChip
                categoryChip
                voiceChip
                if draft.needsReview { reviewChip }
                Spacer()
            }
            if draft.needsReview, let reason = draft.reviewReason, !reason.isEmpty {
                Label(reason, systemImage: "eye.trianglebadge.exclamationmark")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
            Text("\(draft.fromName) <\(draft.fromEmail)>")
                .font(.system(size: 12, weight: .semibold))

            HStack(spacing: 6) {
                Text("Re:").font(.system(size: 12)).foregroundStyle(.secondary)
                TextField("subject", text: $subjectText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            }

            Text(draft.incomingPreview)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.gray.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            TextEditor(text: $bodyText)
                .font(.system(size: 13))
                .frame(minHeight: 90)
                .padding(6)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.3), lineWidth: 1))
                .onChange(of: bodyText) { _, v in
                    EmailTriageEngine.shared.persistEdit(draft.id, subject: subjectText, reply: v)
                }
                .onChange(of: subjectText) { _, v in
                    EmailTriageEngine.shared.persistEdit(draft.id, subject: v, reply: bodyText)
                }
                .disabled(countdown > 0)

            if let status {
                Text(status).font(.system(size: 11)).foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Spacer()
                Button("Dismiss") { EmailTriageEngine.shared.dismiss(draft.id) }
                    .buttonStyle(UtilityButton())
                    .disabled(countdown > 0)
                Button {
                    Task { await regenerate() }
                } label: {
                    HStack(spacing: 6) {
                        if regenerating { ProgressView().controlSize(.small) }
                        Text("Regenerate")
                    }
                }
                .buttonStyle(UtilityButton())
                .disabled(regenerating || countdown > 0)

                if countdown > 0 {
                    Button("Undo (\(countdown))") { cancelSend() }
                        .buttonStyle(PillButton())
                } else {
                    Button("Send") { beginSend() }
                        .buttonStyle(PillButton())
                        .disabled(regenerating)
                }
            }
        }
        .padding(12)
        .background(draft.needsReview ? Color.orange.opacity(0.06) : Color.gray.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onAppear {
            if !didLoad { bodyText = draft.draftReply; subjectText = draft.subject; didLoad = true }
        }
    }

    // MARK: - Send with undo

    private func beginSend() {
        countdown = undoSeconds
        status = nil
        sendTask = Task {
            for remaining in stride(from: undoSeconds - 1, through: 0, by: -1) {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                await MainActor.run { countdown = remaining }
            }
            guard !Task.isCancelled else { return }
            let result = await EmailTriageEngine.shared.sendDraft(draft.id)
            await MainActor.run {
                countdown = 0
                if case .failure(let err) = result {
                    status = "Send failed: \(err.localizedDescription)"
                }
                // On success the store flips status to .sent and this row leaves
                // activeDrafts, so no further UI update is needed here.
            }
        }
    }

    private func cancelSend() {
        sendTask?.cancel()
        sendTask = nil
        countdown = 0
        status = "Send canceled."
    }

    private func regenerate() async {
        regenerating = true
        let ok = await EmailTriageEngine.shared.regenerate(draft.id)
        await MainActor.run {
            regenerating = false
            if ok {
                // Pull the fresh draft text back into the editor.
                if let updated = SupportDraftStore.shared.drafts.first(where: { $0.id == draft.id }) {
                    bodyText = updated.draftReply
                    subjectText = updated.subject
                }
                status = "Regenerated."
            } else {
                status = "Regenerate failed."
            }
        }
    }

    // MARK: - Chips

    private var urgencyChip: some View {
        let color: Color = draft.urgency == .high ? .red : (draft.urgency == .low ? .secondary : .blue)
        return Text(draft.urgency.label)
            .font(.system(size: 10, weight: .bold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.18))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private var categoryChip: some View {
        Text(draft.category.label)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(GruxTheme.accentPrimary.opacity(0.15))
            .clipShape(Capsule())
    }

    private var voiceChip: some View {
        // Roster display text, same as the Jax HQ pills. The raw token is the
        // persisted key, not something to show a person.
        Text(BrandRoster.label(forId: draft.brandVoice).uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Color.gray.opacity(0.12))
            .clipShape(Capsule())
    }

    private var reviewChip: some View {
        Label("Review", systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Color.orange.opacity(0.18))
            .foregroundStyle(.orange)
            .clipShape(Capsule())
    }
}

// Tight pill primary (9px 18px, 13px, radius 999) per the global button rule.
struct PillButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 18).padding(.vertical, 9)
            .background(GruxTheme.accentPrimary.opacity(configuration.isPressed ? 0.8 : 1.0))
            .foregroundStyle(.white)
            .clipShape(Capsule())
    }
}

// Utility/secondary button (radius 10).
struct UtilityButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(Color.gray.opacity(configuration.isPressed ? 0.2 : 0.12))
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
