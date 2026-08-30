import SwiftUI

// Blind model comparison arena. One prompt fans out to every selected backend
// concurrently; outputs render as anonymous columns ("Response A / B / C") in
// a seeded shuffle so neither the eye nor the layout leaks which model is
// which. Vote first, reveal after, synthesize when you want one merged best
// answer from the strongest backend. Tight scale throughout, GruxTheme
// tokens only.
struct CompareView: View {
    @ObservedObject private var service = ComparisonService.shared
    @ObservedObject private var store = ComparisonStore.shared

    @State private var prompt = ""
    @State private var blindMode = true
    @State private var selectedKeys: Set<String> = []
    @State private var contenders: [ComparisonContender] = []
    @State private var currentId: UUID?

    private var currentRecord: ComparisonRecord? {
        store.record(id: currentId) ?? store.ordered.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: GruxSpacing.l) {
                header
                promptBox
                contenderPicker
                runRow
                if let err = service.lastError {
                    Text(err)
                        .font(GruxType.caption)
                        .foregroundStyle(GruxTheme.warnAmber)
                }
                if let rec = currentRecord {
                    arena(for: rec)
                }
                winRateSummary
                historySection
            }
            .padding(GruxSpacing.l)
            // At a 2400pt window the two response cards stayed squeezed at about
            // 230pt on the left while REVEAL MODELS and SYNTHESIZE were stranded
            // roughly 1730pt away at the far edge, and every history row put its
            // date that far from its text. The cards not growing while the
            // header row did is the same missing bound seen from both sides.
            // Inert at the 840pt floor.
            .frame(maxWidth: GruxLayout.contentMax)
        }
        .background(GruxTheme.base)
        .onAppear { refreshContenders() }
    }

    // MARK: - Header + input

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Compare")
                .font(GruxType.display)
                .foregroundStyle(GruxTheme.textPrimary)
            Text("One prompt, every model, blind vote, merged best answer.")
                .font(GruxType.caption)
                .foregroundStyle(GruxTheme.textSecondary)
        }
    }

    private var promptBox: some View {
        TextEditor(text: $prompt)
            .font(.system(size: 14))
            .scrollContentBackground(.hidden)
            // Paper cut: an empty bordered box read as dead space. Ghost
            // placeholder until the first character lands.
            .overlay(alignment: .topLeading) {
                if prompt.isEmpty {
                    Text("Ask one question, every selected model answers...")
                        .font(.system(size: 14))
                        .foregroundStyle(GruxTheme.textTertiary)
                        .padding(.top, 10)
                        .padding(.leading, GruxSpacing.m)
                        .allowsHitTesting(false)
                }
            }
            .padding(.horizontal, GruxSpacing.m)
            .padding(.vertical, 10)
            .frame(minHeight: 64, maxHeight: 110)
            .background(Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: GruxTheme.Radius.chip, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: GruxTheme.Radius.chip, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
            )
            .foregroundStyle(GruxTheme.textPrimary)
    }

    private var contenderPicker: some View {
        VStack(alignment: .leading, spacing: GruxSpacing.xs + 2) {
            HStack(spacing: GruxSpacing.s) {
                GruxSectionLabel("MODELS")
                Button {
                    Task {
                        await ModelRegistry.shared.discoverLocal()
                        refreshContenders()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(GruxTheme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Re-scan local models")
            }
            if contenders.isEmpty {
                Text("No backends available. Add an Anthropic key in Settings or start a local model server.")
                    .font(GruxType.caption)
                    .foregroundStyle(GruxTheme.textSecondary)
            } else {
                FlowingChips(contenders: contenders, selectedKeys: $selectedKeys)
            }
        }
    }

    private var runRow: some View {
        HStack(spacing: GruxSpacing.s) {
            GruxChip(title: service.isRunning ? "RUNNING" : "RUN COMPARISON",
                     systemImage: "bolt.fill", style: .primary) {
                runComparison()
            }
            .disabled(service.isRunning)
            Toggle(isOn: $blindMode) {
                Text("Blind mode")
                    .font(GruxType.caption)
                    .foregroundStyle(GruxTheme.textSecondary)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            if service.isRunning {
                ProgressView().controlSize(.small)
            }
            Spacer()
        }
    }

    // MARK: - Arena (current record)

    private func arena(for rec: ComparisonRecord) -> some View {
        VStack(alignment: .leading, spacing: GruxSpacing.m) {
            HStack(spacing: GruxSpacing.s) {
                Text(rec.prompt)
                    .font(GruxType.caption)
                    .foregroundStyle(GruxTheme.textSecondary)
                    .lineLimit(2)
                Spacer()
                if rec.blind {
                    GruxChip(title: rec.revealed ? "HIDE MODELS" : "REVEAL MODELS",
                             systemImage: rec.revealed ? "eye.slash.fill" : "eye.fill",
                             style: .secondary) {
                        store.setRevealed(recordId: rec.id, revealed: !rec.revealed)
                    }
                }
                GruxChip(title: service.isSynthesizing ? "SYNTHESIZING" : "SYNTHESIZE",
                         systemImage: "sparkles", style: .success) {
                    Task { await service.synthesize(record: rec, contenders: contenders) }
                }
                .disabled(service.isSynthesizing)
            }
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(alignment: .top, spacing: GruxSpacing.m) {
                    ForEach(Array(rec.displayOrder.enumerated()), id: \.offset) { slot, outputIdx in
                        outputColumn(record: rec, slot: slot, output: rec.outputs[outputIdx])
                    }
                }
            }
            if let synthesis = rec.synthesis {
                synthesisCard(text: synthesis, by: rec.synthesizedBy)
            }
        }
    }

    private func outputColumn(record rec: ComparisonRecord, slot: Int,
                              output: ComparisonOutput) -> some View {
        let hidden = rec.blind && !rec.revealed
        let label = hidden ? "Response \(ComparisonShuffle.label(forSlot: slot))" : output.backendName
        let isWinner = rec.votedOutputId == output.id
        return VStack(alignment: .leading, spacing: GruxSpacing.s) {
            HStack(spacing: GruxSpacing.xs + 2) {
                Text(label)
                    .font(GruxType.caption)
                    .foregroundStyle(isWinner ? GruxTheme.successMint : GruxTheme.textPrimary)
                if isWinner {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(GruxTheme.successMint)
                }
                Spacer()
            }
            Text(String(format: "%.1fs", output.latencySeconds)
                 + (output.outputTokens > 0 ? "  \(output.inputTokens) in / \(output.outputTokens) out" : ""))
                .font(GruxType.microCaps)
                .foregroundStyle(GruxTheme.textTertiary)
            ScrollView {
                if let err = output.errorText {
                    Text(err)
                        .font(GruxType.caption)
                        .foregroundStyle(GruxTheme.warnAmber)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                } else {
                    Text(output.text)
                        .font(.system(size: 12))
                        .foregroundStyle(GruxTheme.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .frame(height: 220)
            if rec.votedOutputId == nil && !output.failed {
                GruxChip(title: "VOTE", systemImage: "hand.thumbsup.fill", style: .primary) {
                    store.recordVote(recordId: rec.id, outputId: output.id)
                }
            }
        }
        .padding(GruxSpacing.m)
        // Fixed on purpose, and one of the few places it is right inside the
        // main window. These columns are laid out in a horizontal ScrollView
        // (see the caller), so a fourth model scrolls instead of clipping, and
        // equal widths are the whole point: two answers stop being comparable
        // the moment their columns disagree about how much text fits a line.
        .frame(width: 290, alignment: .topLeading)
        .background(Color.white.opacity(isWinner ? 0.08 : 0.04))
        .clipShape(RoundedRectangle(cornerRadius: GruxTheme.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: GruxTheme.Radius.card, style: .continuous)
                .strokeBorder(isWinner ? GruxTheme.successMint.opacity(0.5) : Color.white.opacity(0.10),
                              lineWidth: 1)
        )
    }

    private func synthesisCard(text: String, by: String?) -> some View {
        VStack(alignment: .leading, spacing: GruxSpacing.xs + 2) {
            HStack(spacing: GruxSpacing.xs + 2) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(GruxTheme.accentCo)
                Text("MERGED BEST ANSWER" + (by.map { " (\($0))" } ?? ""))
                    .font(GruxType.microCaps)
                    .kerning(1.2)
                    .foregroundStyle(GruxTheme.accentCo)
            }
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(GruxTheme.textPrimary)
                .textSelection(.enabled)
        }
        .padding(GruxSpacing.m)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(GruxTheme.accentCo.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: GruxTheme.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: GruxTheme.Radius.card, style: .continuous)
                .strokeBorder(GruxTheme.accentCo.opacity(0.30), lineWidth: 1)
        )
    }

    // MARK: - Aggregates + history

    @ViewBuilder
    private var winRateSummary: some View {
        let counts = store.winCounts()
        if !counts.isEmpty {
            VStack(alignment: .leading, spacing: GruxSpacing.xs + 2) {
                GruxSectionLabel("WIN RATES (\(store.votedCount) voted)")
                ForEach(counts.sorted { $0.value > $1.value }, id: \.key) { name, wins in
                    HStack(spacing: GruxSpacing.s) {
                        Text(name)
                            .font(GruxType.caption)
                            .foregroundStyle(GruxTheme.textPrimary)
                        Spacer()
                        Text("\(wins) win\(wins == 1 ? "" : "s")")
                            .font(GruxType.caption)
                            .foregroundStyle(GruxTheme.successMint)
                    }
                }
            }
            .padding(GruxSpacing.m)
            .background(Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: GruxTheme.Radius.chip, style: .continuous))
        }
    }

    @ViewBuilder
    private var historySection: some View {
        if store.ordered.count > 1 {
            VStack(alignment: .leading, spacing: GruxSpacing.xs + 2) {
                GruxSectionLabel("HISTORY")
                ForEach(store.ordered.prefix(15)) { rec in
                    HStack(spacing: GruxSpacing.s) {
                        Button {
                            currentId = rec.id
                        } label: {
                            Text(rec.prompt)
                                .font(GruxType.caption)
                                .foregroundStyle(rec.id == currentRecord?.id
                                                 ? GruxTheme.accentPrimaryLight
                                                 : GruxTheme.textSecondary)
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        if let winner = rec.votedOutput {
                            Text(rec.blind && !rec.revealed ? "voted" : winner.backendName)
                                .font(GruxType.microCaps)
                                .foregroundStyle(GruxTheme.successMint)
                        }
                        Text(rec.createdAt, style: .date)
                            .font(GruxType.microCaps)
                            .foregroundStyle(GruxTheme.textTertiary)
                        Button {
                            if currentId == rec.id { currentId = nil }
                            store.delete(recordId: rec.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(GruxTheme.textTertiary)
                        }
                        .buttonStyle(.plain)
                        .help("Delete comparison")
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func refreshContenders() {
        contenders = service.availableContenders()
        // Default-select everything available the first time through; keep
        // the user's narrower pick on later refreshes when keys still exist.
        let keys = Set(contenders.map { $0.key })
        if selectedKeys.isEmpty {
            selectedKeys = keys
        } else {
            selectedKeys = selectedKeys.intersection(keys)
            if selectedKeys.isEmpty { selectedKeys = keys }
        }
    }

    private func runComparison() {
        let picked = contenders.filter { selectedKeys.contains($0.key) }
        Task {
            if let rec = await service.runComparison(prompt: prompt,
                                                     contenders: picked,
                                                     blind: blindMode) {
                currentId = rec.id
            }
        }
    }
}

// Selectable contender chips. Plain wrap-less HStack inside a horizontal
// scroller, model lists stay short enough that fancy flow layout is overkill.
private struct FlowingChips: View {
    let contenders: [ComparisonContender]
    @Binding var selectedKeys: Set<String>

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: GruxSpacing.xs + 2) {
                ForEach(contenders) { c in
                    let on = selectedKeys.contains(c.key)
                    Button {
                        if on { selectedKeys.remove(c.key) } else { selectedKeys.insert(c.key) }
                    } label: {
                        Text(c.name)
                            .font(GruxType.microCaps)
                            .kerning(1.0)
                            .foregroundStyle(on ? Color.white : GruxTheme.textSecondary)
                            .padding(.horizontal, GruxSpacing.s).padding(.vertical, GruxSpacing.xs + 1)
                            .background(
                                Capsule().fill(on ? AnyShapeStyle(GruxTheme.iridescent)
                                                  : AnyShapeStyle(Color.white.opacity(0.06)))
                            )
                            .overlay(
                                Capsule().stroke(Color.white.opacity(on ? 0.25 : 0.10), lineWidth: 0.8)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
