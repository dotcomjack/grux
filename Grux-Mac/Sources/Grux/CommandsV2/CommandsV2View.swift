import SwiftUI

// Commands V2 ("Workflows") tab. Lists active runs at the top, then the
// catalog of registered definitions. Drill-in shows the full phase
// timeline and persistent state for a run.

struct CommandsV2View: View {
    @ObservedObject private var engine = CommandV2Engine.shared
    /// The run whose steps are open (shared, so fire-workflow-open-run opens
    /// one the way the Drill in button does).
    @ObservedObject private var selection = WorkflowsSelection.shared
    @State private var runStartStatus: String = ""
    /// Runs whose Details (their raw state) the person opened.
    @State private var openDetails: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if !engine.activeRuns.isEmpty {
                        sectionHeader("ACTIVE RUNS", count: engine.activeRuns.count)
                        ForEach(engine.activeRuns) { run in
                            runCard(run)
                        }
                    }
                    if !engine.recentRuns.isEmpty {
                        sectionHeader("RECENT RUNS", count: engine.recentRuns.count)
                        ForEach(engine.recentRuns) { run in
                            runCard(run)
                        }
                    }
                    sectionHeader("DEFINITIONS", count: engine.definitions.count)
                    ForEach(engine.definitions) { def in
                        definitionCard(def)
                    }
                    if !runStartStatus.isEmpty {
                        Text(runStartStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(16)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Workflows").font(GruxType.title).foregroundStyle(GruxTheme.textPrimary)
                    LabsHeaderBadge(feature: "workflows")
                }
                // PLAIN WORDS. This read "Commands V2: phase-gated,
                // resilient, voice-first", which names the implementation and
                // tells the reader nothing about what the surface is for.
                Text("Steps Grux runs in order, on your say-so. A run that fails picks up where it stopped.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(Color.green.opacity(engine.activeRuns.isEmpty ? 0.3 : 1.0)).frame(width: 7, height: 7)
                Text("\(engine.activeRuns.count) running, \(engine.definitions.count) saved")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption.weight(.heavy))
                .kerning(1.5)
                .foregroundStyle(.secondary)
            Text("(\(count))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: Run cards

    private func runCard(_ run: CommandV2Run) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.displayName)
                        .font(.body.weight(.semibold))
                    HStack(spacing: 8) {
                        statusPill(run.status)
                        Text(CommandV2Engine.stepLine(for: run, in: engine.definition(id: run.definitionId)))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if let reason = run.blockingReason, !reason.isEmpty {
                        Text(reason)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                    }
                    if let next = run.nextWakeAt {
                        Text("Next event: \(next.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                HStack(spacing: 6) {
                    if run.status == .waitingForApproval {
                        // The gate's own words, so a gate that branches on
                        // "fix" / "ship" / "hold" gets one of them. A gate
                        // that asks for free text is answered in Chat.
                        if let replies = engine.buttonReplies(for: run) {
                            ForEach(replies, id: \.self) { reply in
                                Button(reply.capitalized) {
                                    Task { await engine.resume(run.id, userReply: reply) }
                                }
                                .controlSize(.small)
                                .buttonStyle(.borderedProminent)
                            }
                        } else {
                            // Puts the question back as Grux's latest line in
                            // Chat, which is when a free-text gate takes the
                            // next message, and opens Chat.
                            Button("Answer in Chat") {
                                engine.askAgainInChat(run.id)
                                WindowOpener.openChat()
                            }
                            .controlSize(.small)
                        }
                    }
                    if run.status.isCancellable {
                        Button("Cancel", role: .destructive) {
                            Task { await engine.cancel(run.id) }
                        }
                        .controlSize(.small)
                    }
                    Button(selection.openRunId == run.id ? "Hide" : "Drill in") {
                        selection.toggle(run.id)
                    }
                    .controlSize(.small)
                }
            }
            if selection.openRunId == run.id {
                drillIn(run)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        )
    }

    private func statusPill(_ status: CommandV2Run.Status) -> some View {
        let (label, color): (String, Color) = {
            switch status {
            case .running: return ("running", .green)
            case .waitingForApproval: return ("approval", .orange)
            case .waitingScheduled: return ("scheduled", .blue)
            case .waitingForActiveUser: return ("waiting active", .purple)
            case .completed: return ("done", .secondary)
            case .failed: return ("failed", .red)
            case .canceled: return ("canceled", .secondary)
            }
        }()
        return Text(label.uppercased())
            .font(.caption2.bold())
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(color.opacity(0.18))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private func drillIn(_ run: CommandV2Run) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            // A person reads this: the step's own name and how it went in
            // words, never its id or the engine's outcome (SWEEP-12).
            let definition = engine.definition(id: run.definitionId)
            Text(PhaseLogCopy.stepsHeader).font(.caption2.bold()).foregroundStyle(.secondary)
            ForEach(Array(run.phaseHistory.enumerated()), id: \.offset) { idx, rec in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text("\(idx + 1).").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                        Text(PhaseLogCopy.stepTitle(rec.phaseId, in: definition)).font(.caption.weight(.semibold))
                        Text(PhaseLogCopy.status(rec.outcome)).font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        if let end = rec.endedAt {
                            Text(durationText(from: rec.startedAt, to: end))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                    if !rec.log.isEmpty {
                        Text(rec.log)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                            .padding(.leading, 18)
                    }
                    // What the tool, command or agent printed, under its own
                    // label: kept for a person working out why a step failed,
                    // never the step's line (SWEEP-12).
                    if let details = rec.details, !details.isEmpty {
                        Text("Details")
                            .font(.caption2.bold())
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 18)
                        Text(details)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(4)
                            .textSelection(.enabled)
                            .padding(.leading, 18)
                    }
                }
            }
            // What the run kept, raw, for debugging: below the steps, and
            // closed until someone opens it.
            if !run.state.isEmpty {
                Divider()
                DisclosureGroup(isExpanded: Binding(
                    get: { openDetails.contains(run.id) },
                    set: { if $0 { openDetails.insert(run.id) } else { openDetails.remove(run.id) } }
                )) {
                    ForEach(run.state.keys.sorted(), id: \.self) { key in
                        HStack(alignment: .top, spacing: 4) {
                            Text(key).font(.caption2.monospaced()).foregroundStyle(.secondary)
                            Text("=").font(.caption2).foregroundStyle(.tertiary)
                            Text(stateValueDescription(run.state[key] ?? .null))
                                .font(.caption2.monospaced())
                                .lineLimit(2)
                        }
                    }
                } label: {
                    Text(PhaseLogCopy.detailsLabel).font(.caption2.bold()).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Definition cards

    private func definitionCard(_ def: CommandV2Definition) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(PhaseLogCopy.cardTitle(def))
                    .font(.body.weight(.semibold))
                Text(PhaseLogCopy.category(def.category))
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Color.purple.opacity(0.15))
                    .foregroundStyle(.purple)
                    .clipShape(Capsule())
                Spacer()
                Button("▶ Run") {
                    Task { await runDefinition(def) }
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
            }
            Text(def.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 4) {
                Image(systemName: "waveform").font(.caption2).foregroundStyle(.tertiary)
                Text(def.voiceTriggers.map { "\u{201C}\($0)\u{201D}" }.joined(separator: "  "))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
            HStack(spacing: 4) {
                Image(systemName: "list.number").font(.caption2).foregroundStyle(.tertiary)
                Text(def.phases.count == 1 ? "1 step" : "\(def.phases.count) steps")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    // MARK: Actions

    private func runDefinition(_ def: CommandV2Definition) async {
        // For V2.0 we don't pop a sheet to collect parameters - we just
        // pass the project name verbatim if there's a `project` parameter.
        // Voice triggers and the chat inject path can supply real values.
        var params: [String: JSONValue] = [:]
        for p in def.parameters {
            params[p.name] = .string(CommandV2Engine.unspecifiedParameter)
        }
        let result = await CommandV2Engine.shared.start(definitionId: def.id, params: params)
        switch result {
        case .success:
            runStartStatus = "Started \(CommandV2Engine.runName(def.displayName, params: params))."
        case .failure(let err):
            runStartStatus = "Couldn't start: \(err.localizedDescription)"
        }
    }

    private func durationText(from a: Date, to b: Date) -> String {
        let secs = max(0, b.timeIntervalSince(a))
        if secs < 1 { return String(format: "%.0fms", secs * 1000) }
        if secs < 60 { return String(format: "%.1fs", secs) }
        return String(format: "%.0fm %.0fs", secs / 60, secs.truncatingRemainder(dividingBy: 60))
    }

    private func stateValueDescription(_ v: JSONValue) -> String {
        switch v {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .string(let s): return "\"\(s)\""
        case .array(let a): return "[\(a.count) items]"
        case .object(let o): return "{\(o.count) keys}"
        }
    }
}
