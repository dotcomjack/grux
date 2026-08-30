import AppKit
import SwiftUI

// Confirmation UX for voice-first PIM actions (Foundry batch 2, blueprint
// section 03). When PIMIntents parses a confident plan out of an utterance,
// PIMConfirmationController:
//
//   1. speaks the acknowledgment ("Locked in: lunch with Sarah, Friday 1 PM")
//      through SpeechEngine, honoring the speak-replies + mute settings,
//   2. publishes a ShellStateBus moment so the orb / glow / HUD pill tell the
//      same story,
//   3. mounts PIMConfirmationCard in a small Stage-style non-activating panel
//      (bottom-center of the screen under the mouse, same mounting recipe as
//      StageController, scaled down from hero to card),
//   4. holds a 5s undo window (mutating plans only), then executes the plan
//      through ChatService.dispatchTool / ChatService.send. ONE
//      implementation of each action: CalendarTool, NotesTool, EmailTool,
//      DocumentTools do the real work.
//
// The tool result is appended to the chat log as an assistant turn, which is
// also how the action lands on the phone: PhoneChatBridge / SurfaceSync
// already mirror chat + reminders snapshots, so no new sync plumbing.

// MARK: - Model

@MainActor
final class PIMConfirmationModel: ObservableObject {
    enum Phase: Equatable {
        case pending      // undo window running
        case executing
        case done(String) // tool result line
        case cancelled
        case failed(String)
    }

    let plan: PIMPlan
    @Published var phase: Phase = .pending
    /// 0 → 1 over the undo window; drives the draining progress bar.
    @Published var progress: Double = 0

    var onUndo: (() -> Void)?

    init(plan: PIMPlan) {
        self.plan = plan
    }
}

// MARK: - Controller

@MainActor
final class PIMConfirmationController {
    static let shared = PIMConfirmationController()

    private var window: NSPanel?
    private var hostingController: NSHostingController<AnyView>?
    private var runTask: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?
    private var model: PIMConfirmationModel?

    private init() {}

    var isShowing: Bool { window?.isVisible == true }

    /// Entry point. Called from ChatService.send's PIM fast path.
    func present(plan: PIMPlan) {
        // A second utterance inside the undo window must not silently drop
        // the first plan: the user confirmed it by moving on, so commit it
        // now, then present the new card.
        if let prior = model, prior.phase == .pending {
            runTask?.cancel()
            runTask = nil
            let priorPlan = prior.plan
            WakeLog.shared.log("pim: committing pending \(priorPlan.kind.rawValue) early, new utterance arrived")
            Task { @MainActor in await Self.executeDetached(plan: priorPlan) }
        }
        dismiss(animated: false)

        let model = PIMConfirmationModel(plan: plan)
        model.onUndo = { [weak self] in self?.undo() }
        self.model = model

        // Spoken acknowledgment, same gating as ChatService's reply speech.
        let state = AppState.shared
        if state.config.speakRepliesAloud && !state.voiceMuted {
            SpeechEngine.shared.speak(plan.spokenAck)
        }

        // One canonical shell story: the bus moment defends its slot for the
        // undo window so a low-priority idle tick cannot stomp the card beat.
        ShellStateBus.shared.publish(
            mode: .thinking,
            headline: plan.kind.cardKindLabel.capitalized,
            detail: plan.cardTitle,
            source: "pim",
            hold: plan.requiresUndoWindow ? PIMIntents.undoWindowSeconds + 1 : 2
        )

        mountCard(model: model)
        WakeLog.shared.log("pim: presented \(plan.kind.rawValue): \(plan.cardTitle.prefix(80))")

        runTask = Task { @MainActor [weak self] in
            if plan.requiresUndoWindow {
                // 5s undo window, ticked at 50ms for a smooth drain.
                let window = PIMIntents.undoWindowSeconds
                let stepNs: UInt64 = 50_000_000
                let steps = Int(window / 0.05)
                for i in 0...steps {
                    guard !Task.isCancelled else { return }
                    self?.model?.progress = Double(i) / Double(steps)
                    try? await Task.sleep(nanoseconds: stepNs)
                }
            }
            guard !Task.isCancelled else { return }
            await self?.execute(plan: plan)
        }
    }

    /// Undo affordance: cancels the pending plan inside the window. Nothing
    /// has executed yet, so undo is a pure cancel, no compensating delete.
    func undo() {
        guard let model, model.phase == .pending else { return }
        runTask?.cancel()
        runTask = nil
        model.phase = .cancelled
        let state = AppState.shared
        if state.config.speakRepliesAloud && !state.voiceMuted {
            SpeechEngine.shared.speak("Cancelled.")
        }
        ShellStateBus.shared.publish(mode: .idle, headline: "Cancelled", detail: model.plan.cardTitle, source: "pim")
        WakeLog.shared.log("pim: undo, cancelled \(model.plan.kind.rawValue)")
        scheduleDismiss(after: 1.0)
    }

    /// Side-effects-only commit for a plan whose card was superseded by a
    /// newer utterance: runs the tool / chat handoff and lands the result in
    /// the chat log, but never touches the controller's current model or
    /// window (the new card owns the UI).
    @MainActor
    static func executeDetached(plan: PIMPlan) async {
        switch plan.execution {
        case .tool(let name, let input):
            let result = await ChatService.dispatchTool(name: name, input: input)
            AppState.shared.appendChat(ChatMessage(role: .assistant, content: result))
            if AppState.shared.config.memoryEnabled {
                SemanticMemory.shared.store(kind: .chatAssistant, text: result)
            }
            WakeLog.shared.log("pim: early-committed \(plan.kind.rawValue) → \(result.prefix(120))")
        case .chat(let prompt):
            WakeLog.shared.log("pim: early-committed \(plan.kind.rawValue) to chat")
            Task { await ChatService.shared.send(userText: prompt) }
        }
    }

    private func execute(plan: PIMPlan) async {
        model?.phase = .executing
        switch plan.execution {
        case .tool(let name, let input):
            let result = await ChatService.dispatchTool(name: name, input: input)
            let failed = result.hasPrefix("error")
            model?.phase = failed ? .failed(result) : .done(result)
            // Land the result in the chat log; the phone picks it up through
            // the existing chat bridge / surface sync snapshots.
            AppState.shared.appendChat(ChatMessage(role: .assistant, content: result))
            if AppState.shared.config.memoryEnabled {
                SemanticMemory.shared.store(kind: .chatAssistant, text: result)
            }
            ShellStateBus.shared.publish(
                mode: failed ? .alert : .idle,
                headline: failed ? "PIM failed" : "Done",
                detail: plan.cardTitle,
                source: "pim",
                hold: failed ? 4 : 0
            )
            let state = AppState.shared
            if state.config.speakRepliesAloud && !state.voiceMuted {
                if failed {
                    SpeechEngine.shared.speak("That did not land. Check the chat log.")
                } else if plan.kind == .findDocument {
                    SpeechEngine.shared.speak(Self.spokenDocSummary(result: result))
                }
            }
            WakeLog.shared.log("pim: executed \(plan.kind.rawValue) → \(result.prefix(120))")
            scheduleDismiss(after: failed ? 4.0 : 2.5)

        case .chat(let prompt):
            // Email drafting: hand off to the normal Claude tool path, which
            // resolves the contact and reads the draft back before any send.
            model?.phase = .done("Handed to Grux to draft. It will read the draft back before sending.")
            ShellStateBus.shared.publish(mode: .idle, headline: "Drafting", detail: plan.cardTitle, source: "pim")
            WakeLog.shared.log("pim: delegated \(plan.kind.rawValue) to chat")
            scheduleDismiss(after: 2.0)
            Task { await ChatService.shared.send(userText: prompt) }
        }
    }

    /// "found 3 documents" out of a documents_list result block.
    nonisolated static func spokenDocSummary(result: String) -> String {
        if result.hasPrefix("(no documents") { return "No documents matched." }
        let rows = result.split(separator: "\n").filter { $0.hasPrefix("- ") }.count
        if rows == 0 { return "Search finished. Check the chat log." }
        return rows == 1 ? "Found 1 document. It is in the chat log."
                         : "Found \(rows) documents. They are in the chat log."
    }

    // MARK: - Mounting (StageController recipe, card-sized)

    private func mountCard(model: PIMConfirmationModel) {
        guard let screen = screenUnderMouse() ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = CGSize(width: 420, height: 96)
        let origin = CGPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + 56
        )

        let panel = PIMCardPanel(
            contentRect: CGRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false // the undo button must be clickable
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false

        let root = AnyView(
            ThemeRevisionHost {
                PIMConfirmationCard(model: model)
            }
        )
        let hc = NSHostingController(rootView: root)
        hc.view.frame = CGRect(origin: .zero, size: size)
        hc.view.autoresizingMask = [.width, .height]
        hc.view.wantsLayer = true
        hc.view.layer?.backgroundColor = CGColor.clear
        panel.contentView = hc.view

        self.window = panel
        self.hostingController = hc
        panel.orderFrontRegardless()
    }

    private func scheduleDismiss(after seconds: TimeInterval) {
        dismissTask?.cancel()
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    func dismiss(animated: Bool = true) {
        runTask?.cancel(); runTask = nil
        dismissTask?.cancel(); dismissTask = nil
        guard let w = window else { model = nil; return }
        if animated && !GruxTheme.reduceMotion {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = MotionTokens.slow
                w.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.window?.orderOut(nil)
                    self?.window = nil
                    self?.hostingController = nil
                    self?.model = nil
                }
            })
        } else {
            w.orderOut(nil)
            window = nil
            hostingController = nil
            model = nil
        }
    }

    private func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(mouse) })
    }
}

// NSPanel subclass that can become key so the undo button receives the click
// without activating the whole app (same trick as StagePanel).
private final class PIMCardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Card view

// Tight compact scale: small paddings, caption-sized type, pill undo button.
struct PIMConfirmationCard: View {
    @ObservedObject var model: PIMConfirmationModel
    @State private var hasAppeared = false

    var body: some View {
        HStack(spacing: GruxSpacing.m) {
            iconBadge

            VStack(alignment: .leading, spacing: 3) {
                Text(model.plan.kind.cardKindLabel)
                    .font(GruxTheme.Font.microCaps)
                    .kerning(1.4)
                    .foregroundStyle(accent.opacity(0.9))
                Text(model.plan.cardTitle)
                    .font(GruxTheme.Font.body)
                    .foregroundStyle(GruxTheme.textPrimary)
                    .lineLimit(1)
                Text(detailLine)
                    .font(GruxTheme.Font.caption)
                    .foregroundStyle(GruxTheme.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailing
        }
        .padding(.horizontal, GruxSpacing.l)
        .padding(.vertical, GruxSpacing.m)
        .background(cardBackground)
        .overlay(alignment: .bottom) {
            if model.phase == .pending && model.plan.requiresUndoWindow {
                drainBar
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: GruxTheme.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: GruxTheme.Radius.card, style: .continuous)
                .strokeBorder(GruxTheme.iridescentRim, lineWidth: 1)
        )
        .shadow(color: accent.opacity(0.25), radius: 18, y: 6)
        .scaleEffect(hasAppeared ? 1.0 : 0.96)
        .opacity(hasAppeared ? 1.0 : 0.0)
        .onAppear {
            if GruxTheme.reduceMotion {
                hasAppeared = true
            } else {
                withAnimation(MotionTokens.spring) { hasAppeared = true }
            }
        }
        .frame(maxWidth: 420)
    }

    private var accent: Color {
        switch model.phase {
        case .pending, .executing: return GruxTheme.accentPrimary
        case .done:                return GruxTheme.successMint
        case .cancelled, .failed:  return GruxTheme.destructiveRose
        }
    }

    private var detailLine: String {
        switch model.phase {
        case .pending:            return model.plan.cardDetail
        case .executing:          return "running..."
        case .done(let result):   return PIMConfirmationCard.resultLine(result)
        case .cancelled:          return "cancelled, nothing happened"
        case .failed(let result): return PIMConfirmationCard.resultLine(result)
        }
    }

    static func resultLine(_ result: String) -> String {
        let line = result.split(separator: "\n").first.map(String.init) ?? result
        return line
            .replacingOccurrences(of: "ok: ", with: "")
            .replacingOccurrences(of: "error: ", with: "")
    }

    private var iconBadge: some View {
        ZStack {
            Circle()
                .fill(accent.opacity(0.16))
            Image(systemName: badgeSymbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(accent)
        }
        .frame(width: 32, height: 32)
    }

    private var badgeSymbol: String {
        switch model.phase {
        case .done:      return "checkmark"
        case .cancelled: return "arrow.uturn.backward"
        case .failed:    return "exclamationmark.triangle"
        default:         return model.plan.kind.symbolName
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch model.phase {
        case .pending where model.plan.requiresUndoWindow:
            Button(action: { model.onUndo?() }) {
                Text("Undo")
                    .font(GruxTheme.Font.caption)
                    .foregroundStyle(GruxTheme.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule().fill(GruxTheme.destructiveRose.opacity(0.18))
                    )
                    .overlay(
                        Capsule().strokeBorder(GruxTheme.destructiveRose.opacity(0.5), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        case .executing:
            ProgressView()
                .controlSize(.small)
        default:
            EmptyView()
        }
    }

    private var drainBar: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(accent.opacity(0.55))
                .frame(width: geo.size.width * max(0, 1 - model.progress), height: 2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 2)
        .allowsHitTesting(false)
    }

    private var cardBackground: some View {
        ZStack {
            GruxTheme.base.opacity(0.92)
            LinearGradient(
                colors: [accent.opacity(0.10), .clear],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        }
    }
}
