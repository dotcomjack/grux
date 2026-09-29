import SwiftUI
import AppKit

/// Whether the Optimize Grux panel is open, shared so the command palette can
/// open it as well as the button.
@MainActor
final class OptimizeState: ObservableObject {
    static let shared = OptimizeState()
    @Published var isOpen = false
}

/// The copy the panel and the first-run flow share, so they cannot drift.
enum OptimizeCopy {
    static let title = "Optimize Grux"
    static let subtitle = "Say what you want Grux to do differently. Grux writes a work order, your coding agent builds it, and you approve it at three points."
    static let placeholder = "Make the accent red. Add a timer to Today. Hide Meetings."
    static let pasteHint = "Paste it into Claude Code, Codex, Cursor or any coding agent."
    static func copied(_ id: String) -> String { "Copied \(id). Paste it into your coding agent." }
    /// The Change it box takes screenshots by drop or paste.
    static let removeScreenshot = "Remove screenshot"
    static func screenshot(_ n: Int) -> String { "Screenshot \(n)" }
    /// An order with no new line for `WorkOrderStore.quietAfter`.
    static let waitingTitle = "Waiting for your agent"
    static let waitingLine = "No word for 30 minutes. Paste it again, or remove it."
}

/// Under the GRUX OS wordmark: not a rail row, so the row count does not move.
struct OptimizeGruxButton: View {
    @ObservedObject private var store = WorkOrderStore.shared
    @ObservedObject private var state = OptimizeState.shared

    var body: some View {
        Button { state.isOpen.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 10, weight: .semibold))
                Text(OptimizeCopy.title)
                    .font(.caption.weight(.semibold))
                if store.waitingOnYou > 0 {
                    Circle().fill(GruxTheme.warnAmber).frame(width: 6, height: 6)
                        .accessibilityLabel("\(store.waitingOnYou) waiting on your review")
                }
            }
            .foregroundStyle(GruxTheme.accentPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(GruxTheme.accentPrimary.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .help(OptimizeCopy.subtitle)
        .popover(isPresented: $state.isOpen, arrowEdge: .trailing) {
            OptimizeGruxPanel(store: store, state: state)
        }
        // Keeps the dot honest while an agent is working, without a timer
        // anywhere else: this view is on screen whenever the sidebar is.
        .task { await store.pollWhileActive() }
    }
}

struct OptimizeGruxPanel: View {
    @ObservedObject var store: WorkOrderStore
    @ObservedObject var state: OptimizeState
    @State private var request = ""
    @State private var confirmation = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(OptimizeCopy.title)
                .font(.title3.weight(.bold))
                .foregroundStyle(GruxTheme.textPrimary)
            Text(OptimizeCopy.subtitle)
                .font(.caption)
                .foregroundStyle(GruxTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            ZStack(alignment: .topLeading) {
                TextEditor(text: $request)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(height: 78)
                    .background(RoundedRectangle(cornerRadius: 10).fill(GruxTheme.textTertiary.opacity(0.10)))
                    .accessibilityLabel("What should Grux do differently")
                if request.isEmpty {
                    Text(OptimizeCopy.placeholder)
                        .font(.body)
                        .foregroundStyle(GruxTheme.textTertiary)
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .allowsHitTesting(false)
                }
            }

            HStack(spacing: 10) {
                Button("Copy work order") { copyNew() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(WorkOrderPrompt.clean(request) == nil)
                Text(confirmation.isEmpty ? OptimizeCopy.pasteHint : confirmation)
                    .font(.caption)
                    .foregroundStyle(confirmation.isEmpty ? GruxTheme.textTertiary : GruxTheme.successMint)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !store.orders.isEmpty {
                Divider()
                Text("WORK ORDERS")
                    .font(GruxTheme.Font.microCaps)
                    .foregroundStyle(GruxTheme.textTertiary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(store.orders) { order in
                            WorkOrderRow(order: order, store: store) { confirmation = OptimizeCopy.copied(order.id) }
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
        }
        .padding(18)
        .frame(width: 440)
        .tint(GruxTheme.accentPrimary)
        // No poll here: the store watches every order's files and publishes
        // each line the moment the agent writes it.
        .onAppear { store.reload() }
    }

    private func copyNew() {
        guard let order = store.createAndCopy(request) else { return }
        confirmation = OptimizeCopy.copied(order.id)
        request = ""
    }
}

enum OptimizeClipboard {
    static func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}

struct WorkOrderRow: View {
    let order: WorkOrderStore.Order
    let store: WorkOrderStore
    let onCopy: () -> Void

    var body: some View {
        // The station moves the moment the agent writes, through the store's
        // watcher. The clock only moves the quiet state, so once a minute is
        // plenty.
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            content(waiting: order.isWaiting(now: timeline.date))
        }
    }

    private func content(waiting: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(order.request)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(GruxTheme.textPrimary)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Text(order.updated, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(GruxTheme.textTertiary)
            }
            WorkOrderLine(stage: order.progress.stage)
            if waiting {
                Text(OptimizeCopy.waitingTitle)
                    .font(GruxType.body)
                    .foregroundStyle(GruxTheme.warnAmber)
                Text(OptimizeCopy.waitingLine)
                    .font(GruxType.caption)
                    .foregroundStyle(GruxTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(order.progress.stage.isReview ? GruxTheme.warnAmber : GruxTheme.textSecondary)
                    .lineLimit(2)
            }
            HStack(spacing: 14) {
                Button("Copy again") {
                    if let text = store.workOrderText(order) {
                        OptimizeClipboard.copy(text)
                        store.copiedAgain(order.id)
                        onCopy()
                    }
                }
                if !waiting {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([order.workOrderFile]) }
                }
                DestructiveButton("Remove",
                                  question: "Remove this work order?",
                                  detail: "Deletes its folder under ~/.grux/work-orders, including your agent's progress notes. Anything the agent already changed in Grux stays changed.",
                                  confirmLabel: "Remove") { store.remove(order.id) }
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
    }

    private var statusLine: String {
        let stage = order.progress.stage
        let note = order.progress.note
        if stage.isReview { return "\(stage.title). Answer your agent. \(note)".trimmingCharacters(in: .whitespaces) }
        return note.isEmpty ? stage.title : "\(stage.title): \(note)"
    }
}

/// The twelve stations and three reviews, fifteen stops, as one line of
/// marks filled up to where the agent last reported. Reviews are diamonds,
/// because they are the person's.
struct WorkOrderLine: View {
    let stage: WorkOrderStage

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(WorkOrderStage.line.enumerated()), id: \.offset) { index, station in
                mark(station, reached: index < stage.position,
                     current: !stage.isFinished && index == stage.position - 1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(stage.title), \(stage.position) of \(WorkOrderStage.line.count)")
    }

    @ViewBuilder
    private func mark(_ station: WorkOrderStage, reached: Bool, current: Bool) -> some View {
        let color: Color = stage == .stopped ? GruxTheme.textTertiary
            : current && station.isReview ? GruxTheme.warnAmber
            : reached ? GruxTheme.accentPrimary : GruxTheme.textTertiary.opacity(0.35)
        if station.isReview {
            Rectangle().fill(color).frame(width: 7, height: 7).rotationEffect(.degrees(45))
        } else {
            Circle().fill(color).frame(width: current ? 8 : 6, height: current ? 8 : 6)
        }
    }
}
