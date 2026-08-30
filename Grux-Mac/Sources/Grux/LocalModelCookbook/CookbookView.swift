import SwiftUI

// The Cookbook tab: what this Mac can run locally, one-click Ollama serve,
// and pull-with-progress for each recommended model. Styled with GruxTheme
// tokens and tight controls (small paddings, pill buttons, no chunk).
struct CookbookView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var ollama = OllamaManager.shared
    @ObservedObject private var store = CookbookStore.shared

    // OBSERVED, NOT READ ONCE, and that distinction is the whole finding.
    // `MachineLoad` publishes thermal state, low power mode and memory pressure,
    // so a headroom sampled into `@State` on appear would be a snapshot of the
    // moment the tab opened and would sit there stale while the user watched the
    // machine fill up. Observing it means the list re-scores and the badges move
    // the moment pressure changes, which is the only version of this a user can
    // actually trust. Nothing here starts it: `GruxApp` calls `startIfNeeded()`
    // at launch because `SessionConcurrency` needs it on paths that have no view,
    // and a second registration would double every callback.
    @ObservedObject private var load = MachineLoad.shared

    @State private var profile: HardwareProfile? = nil

    // "Check for newer models" state. A curated catalog goes stale silently, so
    // the product carries the thing that notices.
    @State private var registryCheck: ModelRegistryCheck.Result? = nil
    @State private var registryError: String? = nil
    @State private var checkingRegistry = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: GruxSpacing.l) {
                header
                // Directly under the header, because the answer to "is this list
                // current" belongs next to the list it is about, not at the bottom
                // where nobody scrolls to find out they were told last year's model.
                registryBanner
                if let profile {
                    // Scored ONCE per render and shared by the card, the two
                    // sections and every badge, so they cannot disagree about
                    // which budget they were talking about.
                    let live = Cookbook.listing(for: profile, headroom: load.headroom)
                    hardwareCard(profile, live)
                    serverCard
                    modelList(live)
                } else {
                    ProgressView().controlSize(.small)
                }
                if let err = ollama.lastError {
                    errorBanner(err)
                }
            }
            .padding(GruxSpacing.l)
            // At a 2400pt window every model card stretched the full width with
            // its TAG / DISK / MEMORY / CONTEXT figures clustered in the left
            // 220pt and the PULL button stranded roughly 1730pt away across an
            // empty middle. Inert at the 840pt floor.
            .frame(maxWidth: GruxLayout.contentMax)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            store.load()
            let detected = HardwareProfile.detect()
            profile = detected
            store.noteProfile(detected)
            Task {
                await ollama.refresh()
                if store.state.autoServeOnLaunch && !ollama.serverState.isRunning {
                    await ollama.serve()
                }
            }
        }
    }

    /// What the server card says when Ollama is not installed at all, which is
    /// the state every stranger's Mac starts in.
    ///
    /// Naming the install command is deliberate and it is the exception
    /// `NoTerminalInstructionsInUITests` writes down: Ollama is a separate
    /// program Grux cannot install for you, so the command is the most useful
    /// thing this row can say. The rule it does not break is Grux configuring
    /// itself from a shell.
    static let ollamaMissingCopy =
        "Ollama is not installed. Install it from ollama.com or run `brew install ollama`, then press Refresh."

    /// What stands under RECOMMENDED FOR THIS MAC when the live budget fits
    /// nothing in the catalog.
    ///
    /// Says which of the two numbers moved, because they are different problems:
    /// the device budget is fixed and the model budget is not, so a machine that
    /// fits nothing right now may fit plenty with a browser closed.
    static let nothingFitsCopy =
        "Nothing in the catalog fits the model budget on this Mac right now, so every entry is listed below as too big. Close what you are not using and press Refresh, or point Grux at a hosted model in Settings."

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: GruxSpacing.xs) {
                Text("Local Models")
                    .font(GruxType.title)
                    .foregroundStyle(GruxTheme.textPrimary)
                Text("Hardware-aware cookbook for running models on this Mac through Ollama")
                    .font(GruxType.caption)
                    .foregroundStyle(GruxTheme.textTertiary)
            }
            Spacer()
            Button {
                let detected = HardwareProfile.detect()
                profile = detected
                store.noteProfile(detected)
                Task { await ollama.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .font(GruxType.caption)
            }
            .controlSize(.small)

            // Sits next to Refresh on purpose. Refresh re-reads THIS Mac; this
            // re-reads the WORLD. They are the two ways this tab can be wrong and
            // they belong side by side.
            Button {
                checkRegistry()
            } label: {
                Label(checkingRegistry ? "Checking..." : "Check for newer models",
                      systemImage: "sparkle.magnifyingglass")
                    .font(GruxType.caption)
            }
            .controlSize(.small)
            .disabled(checkingRegistry)
        }
    }

    private func checkRegistry() {
        checkingRegistry = true
        registryError = nil
        registryCheck = nil
        Task {
            do {
                let r = try await ModelRegistryCheck.check()
                await MainActor.run {
                    registryCheck = r
                    checkingRegistry = false
                }
            } catch {
                await MainActor.run {
                    registryError = error.localizedDescription
                    checkingRegistry = false
                }
            }
        }
    }

    // MARK: - Registry result

    @ViewBuilder
    private var registryBanner: some View {
        if let err = registryError {
            noticeCard(title: "Could not check", body: err, tone: GruxTheme.textTertiary)
        } else if let r = registryCheck {
            if r.isStale {
                noticeCard(
                    title: r.upgrades.count == 1
                        ? "A newer version of one recommended model exists"
                        : "Newer versions of \(r.upgrades.count) recommended models exist",
                    body: r.upgrades
                        .map { "\($0.have) has \($0.newer.joined(separator: ", "))" }
                        .joined(separator: "\n")
                        + "\n\nChecked against the \(r.registryCount) families in Ollama's library. This compares version numbers by family, not by size, and makes no claim about quality: a later release is not automatically better for your work, and it may not exist at the size you run. Try one with `ollama pull`, or ask Chat which is worth the disk.",
                    tone: GruxTheme.accentPrimary)
            } else {
                noticeCard(
                    title: "Up to date",
                    body: "Nothing in Ollama's \(r.registryCount) families is a later version of anything recommended here.",
                    tone: GruxTheme.textTertiary)
            }
        }
    }

    private func noticeCard(title: String, body: String, tone: Color) -> some View {
        VStack(alignment: .leading, spacing: GruxSpacing.xs) {
            Text(title)
                .font(GruxType.caption)
                .foregroundStyle(tone)
            Text(body)
                .font(GruxType.caption)
                .foregroundStyle(GruxTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(GruxSpacing.m)
        .background(
            RoundedRectangle(cornerRadius: GruxTheme.Radius.chip, style: .continuous)
                .fill(Color.primary.opacity(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: GruxTheme.Radius.chip, style: .continuous)
                        .stroke(tone.opacity(0.30), lineWidth: 1)
                )
        )
    }

    // MARK: - Hardware card

    private func hardwareCard(_ p: HardwareProfile, _ live: Cookbook.Listing) -> some View {
        VStack(alignment: .leading, spacing: GruxSpacing.m) {
            HStack(spacing: GruxSpacing.s) {
                Image(systemName: "cpu.fill").foregroundStyle(GruxTheme.iridescent)
                Text(p.chipName).font(GruxType.title)
                Spacer()
                tierPill(p.memoryTier)
            }
            HStack(spacing: GruxSpacing.l) {
                statChip("RAM", String(format: "%.0f GB", p.physicalMemoryGB))
                statChip("GPU budget", p.gpuWorkingSetBytes > 0
                         ? String(format: "%.0f GB", p.gpuWorkingSetGB)
                         : "n/a")
                // THE NUMBER THE LABELS WERE COMPUTED FROM, not the number the
                // device could manage if nothing else were running. Those two
                // used to be the same string here, which is how a fit badge
                // could be right about the hardware and wrong about the machine
                // with nothing on screen able to show the difference.
                statChip("Model budget", String(format: "%.0f GB", live.budget.gigabytes))
                statChip("Cores", "\(p.cpuCoreCount)")
                statChip("Memory", p.hasUnifiedMemory ? "unified" : "discrete")
            }
            // Printed only when the live budget is not the device budget. At
            // full headroom the summary says the same thing the chip above
            // already says, and a line that is redundant every day is a line
            // nobody reads on the one day it matters.
            if live.budget.headroom != .full {
                Text(live.budget.summary)
                    .font(.caption)
                    .foregroundStyle(GruxTheme.warnAmber)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let pick = live.headline {
                Text("Recommended: \(pick.displayName) \(pick.parameterLabel) (\(pick.id))")
                    .font(.caption)
                    .foregroundStyle(GruxTheme.accentCo)
            }
        }
        .padding(GruxSpacing.l)
        .background(cardBackground)
    }

    private func tierPill(_ tier: MemoryTier) -> some View {
        Text(tier.label.uppercased())
            .font(GruxType.microCaps)
            .kerning(1.2)
            .foregroundStyle(.white)
            .padding(.horizontal, GruxSpacing.s).padding(.vertical, GruxSpacing.xs)
            .background(Capsule().fill(GruxTheme.iridescent))
    }

    // MARK: - Server card

    private var serverCard: some View {
        VStack(alignment: .leading, spacing: GruxSpacing.m) {
            HStack(spacing: GruxSpacing.s) {
                Circle()
                    .fill(ollama.serverState.isRunning ? GruxTheme.successMint :
                          (ollama.serverState == .starting ? GruxTheme.warnAmber : GruxTheme.textTertiary))
                    .frame(width: 8, height: 8)
                Text("Ollama server").font(GruxType.title)
                Text(ollama.serverState.label)
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                serveControls
            }
            HStack(spacing: GruxSpacing.s) {
                Image(systemName: ollama.binaryPath == nil ? "exclamationmark.triangle.fill" : "terminal.fill")
                    .font(.caption2)
                    .foregroundStyle(ollama.binaryPath == nil ? GruxTheme.warnAmber : GruxTheme.textTertiary)
                // TWO BRANCHES BECAUSE THEY ARE TWO KINDS OF TEXT, not one
                // string with two sources. The missing copy goes through an
                // EXPLICIT LocalizedStringKey, the same trap
                // CommandsView.emptyState documents: `Text` handed a plain
                // String selects the verbatim overload, so the backticks around
                // `brew install ollama` printed as literal backticks instead of
                // marking the command. The path branch stays verbatim ON
                // PURPOSE, because a path is not markdown and one holding an
                // underscore or a backtick must print exactly as it reads on
                // disk.
                if let path = ollama.binaryPath {
                    // ONE LINE FOR A PATH: truncated in the middle it is still
                    // legible as a path.
                    Text(path)
                        .font(GruxType.mono)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    // WHATEVER IT TAKES FOR THE SENTENCE. An instruction
                    // truncated in the middle is a shrug: this row shares its
                    // width with the auto-serve toggle, so at the 840pt window
                    // floor a single line ran out of room part way through, and
                    // this sentence is the ONLY thing a Mac with no Ollama on
                    // it has to read on this card.
                    Text(LocalizedStringKey(Self.ollamaMissingCopy))
                        .font(GruxType.mono)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("Auto-serve at launch", isOn: Binding(
                    get: { store.state.autoServeOnLaunch },
                    set: { store.setAutoServe($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.caption)
            }
            if !ollama.installedTags.isEmpty {
                Text("\(ollama.installedTags.count) model\(ollama.installedTags.count == 1 ? "" : "s") installed locally")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(GruxSpacing.l)
        .background(cardBackground)
    }

    @ViewBuilder private var serveControls: some View {
        switch ollama.serverState {
        case .stopped:
            GruxChip(title: "SERVE", systemImage: "play.fill", style: .primary) {
                Task { await ollama.serve() }
            }
            .disabled(ollama.binaryPath == nil)
        case .starting, .stopping:
            ProgressView().controlSize(.small)
        case .runningManaged:
            GruxChip(title: "STOP", systemImage: "stop.fill", style: .destructive) {
                Task { await ollama.stop() }
            }
        case .runningExternal:
            Text("managed elsewhere")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    // MARK: - Model list

    private func modelList(_ live: Cookbook.Listing) -> some View {
        VStack(alignment: .leading, spacing: GruxSpacing.s) {
            GruxSectionLabel("RECOMMENDED FOR THIS MAC")
            // A HEADING OVER A VOID READS AS A LIST THAT FAILED TO LOAD.
            //
            // `Cookbook.listing` scores the catalog against a budget that
            // shrinks with live memory pressure, so on a small Mac under load
            // `fitting` comes back empty and this label printed with nothing
            // beneath it, directly above a full list headed TOO BIG FOR THIS
            // MAC. Nothing was broken and nothing said so.
            if live.fitting.isEmpty {
                Text(Self.nothingFitsCopy)
                    .font(.caption)
                    .foregroundStyle(GruxTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(live.fitting) { model in
                modelRow(model, fit: live.fit(of: model))
            }
            if !live.tooBig.isEmpty {
                GruxSectionLabel("TOO BIG FOR THIS MAC")
                    .padding(.top, GruxSpacing.xs)
                ForEach(live.tooBig) { model in
                    modelRow(model, fit: live.fit(of: model))
                        .opacity(0.55)
                }
            }
        }
    }

    private func modelRow(_ model: CookbookModel, fit: ModelFit) -> some View {
        let installed = ollama.isInstalled(model.id)
        let selected = state.config.offlineLLMModel == model.id
        return VStack(alignment: .leading, spacing: GruxSpacing.xs + 2) {
            HStack(spacing: GruxSpacing.s) {
                Text(model.displayName).font(GruxType.title)
                Text(model.parameterLabel)
                    .font(GruxType.mono).foregroundStyle(.secondary)
                fitBadge(fit)
                if model.supportsTools {
                    Text("TOOLS")
                        .font(GruxType.microCaps).kerning(1.0)
                        .foregroundStyle(GruxTheme.accentCo)
                        .padding(.horizontal, GruxSpacing.xs + 2).padding(.vertical, 2)
                        .background(Capsule().stroke(GruxTheme.accentCo.opacity(0.5), lineWidth: 0.8))
                }
                Spacer()
                rowControls(model, fit: fit, installed: installed, selected: selected)
            }
            Text(model.strengths)
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: GruxSpacing.l) {
                statChip("Tag", model.id)
                statChip("Disk", String(format: "%.1f GB", model.diskGB))
                statChip("Memory", String(format: "~%.0f GB", model.estimatedMemoryGB))
                statChip("Context", contextLabel(model.contextTokens))
            }
            if let prog = ollama.pulls[model.id], !installed {
                pullProgressRow(model.id, prog)
            }
        }
        .padding(GruxSpacing.m)
        .background(
            RoundedRectangle(cornerRadius: GruxTheme.Radius.chip, style: .continuous)
                .fill(selected ? GruxTheme.accentPrimary.opacity(0.10) : Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: GruxTheme.Radius.chip, style: .continuous)
                .strokeBorder(selected ? GruxTheme.accentPrimary.opacity(0.55) : Color.primary.opacity(0.07), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func rowControls(_ model: CookbookModel, fit: ModelFit, installed: Bool, selected: Bool) -> some View {
        if selected {
            Label("Selected", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(GruxTheme.successMint)
        } else if installed {
            GruxChip(title: "USE", systemImage: "checkmark", style: .primary) {
                useModel(model)
            }
        } else if fit == .tooBig {
            EmptyView()
        } else if let prog = ollama.pulls[model.id], !prog.failed,
                  prog.status != "cancelled", prog.status != "installed" {
            // "installed" excluded because stop() clears installedTags but
            // deliberately LEAVES a completed pull's row standing, so after
            // Stop server a finished model fell through to this arm and drew
            // CANCEL. Pressing it wrote a failed "cancelled" row over a model
            // that is on disk: an offer to undo something already done.
            GruxChip(title: "CANCEL", style: .secondary) {
                ollama.cancelPull(model.id)
            }
        } else {
            GruxChip(title: "PULL", systemImage: "arrow.down.circle", style: .secondary) {
                Task { await ollama.pull(model.id) }
            }
        }
    }

    private func pullProgressRow(_ modelId: String, _ prog: OllamaManager.PullProgress) -> some View {
        HStack(spacing: GruxSpacing.s) {
            if prog.failed {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(GruxTheme.warnAmber)
            } else if let f = prog.fraction {
                ProgressView(value: f)
                    .progressViewStyle(.linear)
                    .tint(GruxTheme.accentPrimary)
                    .frame(maxWidth: 220)
            } else {
                ProgressView().controlSize(.mini)
            }
            Text(prog.status)
                .font(GruxType.mono)
                .foregroundStyle(prog.failed ? GruxTheme.warnAmber : .secondary)
                // ONE LINE FOR A LIVE STATUS, WHATEVER IT TAKES FOR A FAILURE.
                // The same trade the binary row above makes for its path: a
                // ticking status ("pulling manifest", a sha256 layer name)
                // gains nothing from a second line, but a failure is a full
                // sentence, and the disk refusal in particular carries the
                // numbers and the measured path that make it actionable. At
                // the 840pt window floor a single line cut that sentence off
                // before the part that says what to do about it.
                .lineLimit(pullStatusLineLimit(prog))
                .fixedSize(horizontal: false, vertical: prog.failed)
            if let f = prog.fraction, !prog.failed {
                Text("\(Int(f * 100))%")
                    .font(GruxType.mono).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    /// `nil` means unlimited, which is what a failed status needs. Spelled out
    /// as a typed function rather than inline, because a `nil` in a ternary
    /// inside `.lineLimit(_:)` is exactly the shape Swift's inference is worst
    /// at reading.
    private func pullStatusLineLimit(_ prog: OllamaManager.PullProgress) -> Int? {
        prog.failed ? nil : 1
    }

    // Selecting a model writes the durable offline preference (the same field
    // ModelRegistry.modelId() reads in offline mode) and re-runs discovery so
    // the registry picks the server up immediately.
    private func useModel(_ model: CookbookModel) {
        state.config.offlineLLMModel = model.id
        state.saveConfig()
        store.select(modelId: model.id)
        Task { await ModelRegistry.shared.discoverLocal() }
    }

    // MARK: - Small pieces

    private func fitBadge(_ fit: ModelFit) -> some View {
        let color: Color = {
            switch fit {
            case .great:  return GruxTheme.successMint
            case .good:   return GruxTheme.accentPrimary
            case .tight:  return GruxTheme.warnAmber
            case .tooBig: return GruxTheme.destructiveRose
            }
        }()
        return Text(fit.label.uppercased())
            .font(GruxType.microCaps)
            .kerning(1.0)
            .foregroundStyle(color)
            .padding(.horizontal, GruxSpacing.xs + 2).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
    }

    private func statChip(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            Text(value)
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: GruxTheme.Radius.card, style: .continuous)
            .fill(Color.primary.opacity(0.04))
            .overlay(
                RoundedRectangle(cornerRadius: GruxTheme.Radius.card, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: GruxSpacing.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(GruxTheme.warnAmber)
            Text(message).font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(GruxSpacing.m)
        .background(
            RoundedRectangle(cornerRadius: GruxTheme.Radius.chip, style: .continuous)
                .fill(GruxTheme.warnAmber.opacity(0.10))
        )
    }

    private func contextLabel(_ tokens: Int) -> String {
        tokens >= 1024 ? "\(tokens / 1024)K" : "\(tokens)"
    }
}
