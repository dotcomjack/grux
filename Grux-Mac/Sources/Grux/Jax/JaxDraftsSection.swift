import SwiftUI
import WebKit

// JaxDraftsSection: the approved IA (decision 1A) brings the support-reply review
// queue INTO Jax HQ, retiring the floating window. Brand-filtered (decision 3),
// with the enhanced review card (decision 2): collapsible thread, per-card
// confidence, and an inline branded email preview. All actions reuse the
// existing EmailTriageEngine; nothing auto-sends.
struct JaxDraftsSection: View {
    @ObservedObject private var store = SupportDraftStore.shared
    @ObservedObject private var brand = BrandFilter.shared
    @State private var showRules = false

    private var staged: [SupportDraft] { store.drafts.filter { $0.status == .staged } }
    private var shown: [SupportDraft] { staged.filter { brand.scope.matches(voice: $0.brandVoice) } }
    // The brand the Reply Rules sheet edits: the current filter selection, or
    // the first configured brand when the filter is on "All" (there is no "edit
    // every brand at once" rule set, so "All" has to resolve to one of them).
    // Empty when no brands are configured, which is why the button that opens
    // the sheet disappears in that state: reply rules for a brand that does not
    // exist are not editable, they are just a form writing to a dead key.
    private var rulesBrand: String {
        guard brand.scope == .all else { return brand.scope.rawValue }
        return BrandScope.configured.first?.rawValue ?? ""
    }

    private var rulesButton: AnyView? {
        guard !rulesBrand.isEmpty else { return nil }
        return AnyView(
            Button { showRules = true } label: {
                Image(systemName: "slider.horizontal.3").font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(GruxTheme.textSecondary)
            .help("Reply rules")
        )
    }

    var body: some View {
        JaxSection(
            title: "Drafts", icon: "tray.full.fill", tint: GruxTheme.accentPrimary, count: staged.count,
            trailing: rulesButton
        ) {
            BrandFilterBar(trailing: brand.scope == .all ? nil : "\(shown.count) of \(staged.count)")
                .padding(.bottom, 6)
            if shown.isEmpty {
                Text(staged.isEmpty
                     ? "No drafts waiting. \(UserIdentity.assistantName) stages support replies here as mail arrives, for your one-tap send."
                     : "No \(brand.scope.label) drafts right now. Switch the brand filter to see others.")
                    .font(.system(size: 13)).foregroundStyle(GruxTheme.textSecondary).italic()
                    .padding(.vertical, 6)
            } else {
                ForEach(shown) { JaxDraftCard(draft: $0) }
            }
        }
        .sheet(isPresented: $showRules) { ReplyRulesSheet(brand: rulesBrand) }
    }
}

private struct JaxDraftCard: View {
    let draft: SupportDraft
    @State private var reply = ""
    @State private var showThread = false
    @State private var showPreview = false
    @State private var busy = false

    private let gold = Color(red: 0x8a/255, green: 0x64/255, blue: 0x20/255)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if draft.urgency == .high { pill("Urgent", GruxTheme.destructiveRose) }
                pill(draft.category.label, GruxTheme.accentCo)
                // The roster's own display text for this brand, not the raw
                // persisted token. A draft tagged with a brand since removed
                // still renders, as its token, rather than blanking out.
                pill(BrandRoster.label(forId: draft.brandVoice), gold)
                if draft.needsReview { pill("Review", GruxTheme.warnAmber) }
                Spacer()
                if let c = draft.confidence {
                    Text("conf \(String(format: "%.2f", c))")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(GruxTheme.textTertiary)
                }
            }
            Text("\(draft.fromName) <\(draft.fromEmail)>")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(GruxTheme.textPrimary)
            Text("Re: \(draft.subject)").font(.system(size: 12)).foregroundStyle(GruxTheme.textSecondary)

            // A send that was blocked by the output gate or failed at Resend keeps
            // the draft staged with the reason here, so it is visible and retryable
            // instead of silently stranded.
            if let err = draft.lastError, !err.isEmpty {
                Text(err)
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(GruxTheme.destructiveRose)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !draft.incomingPreview.isEmpty {
                Button { withAnimation(.easeInOut(duration: 0.15)) { showThread.toggle() } } label: {
                    Text("\(showThread ? "\u{25BE}" : "\u{25B8}") Thread").font(.system(size: 11, weight: .semibold))
                }.buttonStyle(.plain).foregroundStyle(GruxTheme.accentPrimary)
                if showThread {
                    Text(draft.incomingPreview)
                        .font(.system(size: 11.5)).foregroundStyle(GruxTheme.textTertiary)
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.black.opacity(0.25))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }

            TextEditor(text: $reply)
                .font(.system(size: 12.5)).foregroundStyle(GruxTheme.textPrimary)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 64, maxHeight: 140)
                .padding(8)
                .background(Color.black.opacity(0.30))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(GruxTheme.accentPrimary.opacity(0.35), lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onChange(of: reply) { _, new in
                    SupportDraftStore.shared.update(draft.id) { $0.draftReply = new }
                }

            if showPreview {
                BrandedEmailWebView(html: BrandEmailTemplate.html(voice: draft.brandVoice, replyText: reply))
                    .frame(height: 320)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(GruxTheme.textTertiary.opacity(0.2), lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            HStack(spacing: 8) {
                Button("Dismiss") { EmailTriageEngine.shared.dismiss(draft.id) }
                    .foregroundStyle(GruxTheme.destructiveRose)
                Menu("Hide sender") {
                    Button("Hide this address (\(draft.fromEmail))") {
                        EmailTriageEngine.shared.hideSenderEmail(draft.fromEmail)
                    }
                    if let dom = SenderSuppressionStore.domain(of: draft.fromEmail) {
                        Button("Hide @\(dom)") {
                            EmailTriageEngine.shared.hideSenderDomain(dom)
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .foregroundStyle(GruxTheme.textSecondary)
                Button(busy ? "..." : "Regenerate") {
                    busy = true
                    Task { _ = await EmailTriageEngine.shared.regenerate(draft.id); busy = false }
                }.disabled(busy).foregroundStyle(GruxTheme.textSecondary)
                Button(showPreview ? "Hide preview" : "Preview email") {
                    withAnimation(.easeInOut(duration: 0.15)) { showPreview.toggle() }
                }.foregroundStyle(Color(red: 0xe7/255, green: 0xc8/255, blue: 0x78/255))
                Button("Why this draft?") {
                    // Deep-link to the decision node behind this draft (decision 4):
                    // the cognition trace correlationId is the draft id.
                    AppState.shared.cognitionFocus = draft.id
                    AppState.shared.requestedTab = "cognitionMap"
                }.foregroundStyle(GruxTheme.accentPrimaryLight)
                Spacer()
                Button(busy ? "Sending..." : "Send") {
                    busy = true
                    SupportDraftStore.shared.update(draft.id) { $0.draftReply = reply }
                    Task { _ = await EmailTriageEngine.shared.sendDraft(draft.id); busy = false }
                }
                .disabled(busy)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(GruxTheme.accentPrimary)
            }
            .font(.system(size: 12, weight: .semibold)).padding(.top, 2)
            // Six controls plus a Spacer share this row, so at the 599pt pane
            // floor they were truncating into "Regener...", "Preview..." and
            // "Why this d...", which is unreadable on the one row where the
            // labels are the whole affordance. Scaling down keeps them legible
            // and, unlike fixedSize, does not raise this view's minimum width,
            // so it cannot squeeze the nav rail the way an earlier fix did.
            .lineLimit(1)
            .minimumScaleFactor(0.75)
        }
        .padding(14)
        .background(Color(red: 0x16/255, green: 0x13/255, blue: 0x0d/255))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(GruxTheme.textTertiary.opacity(0.15), lineWidth: 1))
        .overlay(Rectangle().fill(draft.needsReview ? GruxTheme.warnAmber : GruxTheme.accentPrimary)
            .frame(width: 3).clipShape(RoundedRectangle(cornerRadius: 2)), alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onAppear { if reply.isEmpty { reply = draft.draftReply } }
        .onChange(of: draft.draftReply) { _, new in reply = new }   // reflect regenerate
    }

    private func pill(_ text: String, _ color: Color) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9.5, weight: .bold)).tracking(0.4)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(color.opacity(0.16)).foregroundStyle(color).clipShape(Capsule())
    }
}

// Renders the branded HTML reply inline so the user sees exactly what the customer
// receives before tapping Send (approved decision 2).
private struct BrandedEmailWebView: NSViewRepresentable {
    let html: String
    func makeNSView(context: Context) -> WKWebView {
        let w = WKWebView()
        w.setValue(false, forKey: "drawsBackground")   // transparent so the dark card shows through margins
        return w
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        view.loadHTMLString(html, baseURL: nil)
    }
}
