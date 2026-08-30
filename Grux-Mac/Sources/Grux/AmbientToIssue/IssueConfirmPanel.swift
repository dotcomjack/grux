import AppKit
import SwiftUI

// Floating confirmation panel for the issue-from-voice feature. Surfaces a
// drafted GitHub issue (title, body, repo, labels) with every field editable,
// and files only when the user taps File. Reuses InteractiveHUDPanel (defined in
// AmbientPanelController.swift) so SwiftUI controls receive clicks without
// activating the whole app, and GruxGlassCard / GruxChip for house styling.
@MainActor
final class IssueConfirmController {
    static let shared = IssueConfirmController()

    private var panel: NSPanel?
    private var hostingController: NSHostingController<AnyView>?

    private init() {}

    func present(draft: DraftedIssue, onFile: @escaping (DraftedIssue) -> Void, onDismiss: @escaping () -> Void) {
        // Replace any panel already on screen.
        dismissPanel()

        let size = NSSize(width: 480, height: 560)
        let frame = centeredFrame(size: size)

        let panel = InteractiveHUDPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false

        let root = AnyView(
            IssueConfirmView(
                draft: draft,
                onFile: { [weak self] edited in
                    self?.dismissPanel()
                    onFile(edited)
                },
                onDismiss: { [weak self] in
                    self?.dismissPanel()
                    onDismiss()
                }
            )
            .padding(8)
        )
        let hc = NSHostingController(rootView: root)
        hc.view.frame = CGRect(origin: .zero, size: frame.size)
        hc.view.autoresizingMask = [.width, .height]
        hc.view.wantsLayer = true
        hc.view.layer?.backgroundColor = CGColor.clear
        panel.contentView = hc.view

        self.panel = panel
        self.hostingController = hc
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    private func dismissPanel() {
        panel?.orderOut(nil)
        panel = nil
        hostingController = nil
    }

    private func centeredFrame(size: NSSize) -> NSRect {
        guard let screen = NSScreen.main else {
            return NSRect(origin: .zero, size: size)
        }
        let vf = screen.visibleFrame
        let x = vf.midX - size.width / 2
        let y = vf.midY - size.height / 2
        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }
}

// SwiftUI body of the confirmation panel.
struct IssueConfirmView: View {
    let initialDraft: DraftedIssue
    let onFile: (DraftedIssue) -> Void
    let onDismiss: () -> Void

    @State private var title: String
    @State private var body_: String
    @State private var repo: String
    @State private var labelsText: String
    @State private var filing = false

    init(draft: DraftedIssue, onFile: @escaping (DraftedIssue) -> Void, onDismiss: @escaping () -> Void) {
        self.initialDraft = draft
        self.onFile = onFile
        self.onDismiss = onDismiss
        _title = State(initialValue: draft.title)
        _body_ = State(initialValue: draft.body)
        _repo = State(initialValue: draft.repo)
        _labelsText = State(initialValue: draft.labels.joined(separator: ", "))
    }

    var body: some View {
        GruxGlassCard(tone: .normal) {
            VStack(alignment: .leading, spacing: 12) {
                header

                field(label: "TITLE") {
                    TextField("Issue title", text: $title)
                        .textFieldStyle(.plain)
                        .font(GruxTheme.Font.body)
                        .foregroundStyle(GruxTheme.textPrimary)
                        .padding(8)
                        .background(inputBackground)
                }

                field(label: "BODY") {
                    TextEditor(text: $body_)
                        .font(GruxTheme.Font.body)
                        .foregroundStyle(GruxTheme.textPrimary)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 150, maxHeight: 220)
                        .padding(6)
                        .background(inputBackground)
                }

                HStack(spacing: 10) {
                    field(label: "REPO") {
                        TextField("owner/name", text: $repo)
                            .textFieldStyle(.plain)
                            .font(GruxTheme.Font.mono)
                            .foregroundStyle(GruxTheme.textPrimary)
                            .padding(8)
                            .background(inputBackground)
                    }
                    field(label: "LABELS") {
                        TextField("bug, ui", text: $labelsText)
                            .textFieldStyle(.plain)
                            .font(GruxTheme.Font.mono)
                            .foregroundStyle(GruxTheme.textPrimary)
                            .padding(8)
                            .background(inputBackground)
                    }
                }

                Spacer(minLength: 2)
                footer
            }
            .padding(18)
        }
        .frame(width: 464, height: 544)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.bubble.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(GruxTheme.accentPrimaryLight)
            VStack(alignment: .leading, spacing: 1) {
                Text("FILE A GITHUB ISSUE?")
                    .font(GruxTheme.Font.caption)
                    .kerning(1.4)
                    .foregroundStyle(GruxTheme.textSecondary)
                Text("Heard you flag something. Drafted this.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(GruxTheme.textTertiary)
            }
            Spacer()
            Text(String(format: "%.0f%%", initialDraft.confidence * 100))
                .font(GruxTheme.Font.microCaps)
                .kerning(1.0)
                .foregroundStyle(GruxTheme.accentCo)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(Color.white.opacity(0.06)))
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            GruxChip(title: "Dismiss", systemImage: "xmark", style: .secondary) {
                onDismiss()
            }
            Spacer()
            GruxChip(title: filing ? "Filing..." : "File issue", systemImage: "arrow.up.forward.square", style: .primary) {
                guard !filing else { return }
                filing = true
                onFile(editedDraft())
            }
        }
    }

    private func editedDraft() -> DraftedIssue {
        let labels = labelsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        return DraftedIssue(
            title: IssueExtractor.scrubDashes(title.trimmingCharacters(in: .whitespacesAndNewlines)),
            body: IssueExtractor.scrubDashes(body_),
            repo: repo.trimmingCharacters(in: .whitespacesAndNewlines),
            labels: Array(labels.prefix(5)),
            confidence: initialDraft.confidence
        )
    }

    @ViewBuilder
    private func field<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(GruxTheme.Font.microCaps)
                .kerning(1.4)
                .foregroundStyle(GruxTheme.textTertiary)
            content()
        }
    }

    private var inputBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.white.opacity(0.05))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: 0.8)
            )
    }
}
